#!/usr/bin/env bash
# Build Whisky on Ubuntu 26.04 (x86_64 or aarch64) and wrap it with an
# already-built Linux Wine runtime for manual testing. Wine is not rebuilt.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../../.." && pwd)"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '\n==> %s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage: build-ubuntu2604-wine-test.sh [options]

Run this inside Ubuntu 26.04 on x86_64 or aarch64 (native, VM, or container).
The script builds the existing Linux release, then wraps it with a Wine
runtime that you already built. The Whisky/ directory inside the result is
kept unmodified, including its manifest.json.

The Wine runtime may be x86_64 on either host. On an aarch64 host, executing
that Wine requires an x86_64 binfmt handler such as FEX-Emu or Box64; the
script only assembles the bundle and does not set that up for you.

Options:
  --wine PATH             Wine runtime directory containing bin/wine, a
                          .tar.gz containing it, or the Wine repository root.
                          Default: search $WHISKY_WINE_REPO and
                          ../ge-proton-macos-wine-poc.
  --output DIR            Output root. Default:
                          <repo>/build/portability/ubuntu-26.04-wine-test
  --smoke                 After assembly, run Wine --version, wine cmd /c ver,
                          and verify that the bridge advertises runtime.launch.
  --allow-other-ubuntu    Allow a non-26.04 Ubuntu build host.
  -h, --help              Show this help.

Examples:
  bash apps/whisky-gpui/tools/build-ubuntu2604-wine-test.sh \
    --wine /path/to/wine-linux-x86_64.tar.gz

  WHISKY_WINE_REPO=/path/to/ge-proton-macos-wine-poc \
    bash apps/whisky-gpui/tools/build-ubuntu2604-wine-test.sh --smoke
EOF
}

wine_input=""
output_root=""
run_smoke=0
allow_other_ubuntu=0
while (($#)); do
    case "$1" in
        --wine)
            (($# >= 2)) || die "--wine requires a path"
            wine_input=$2
            shift 2
            ;;
        --wine=*)
            wine_input=${1#*=}
            shift
            ;;
        --output)
            (($# >= 2)) || die "--output requires a path"
            output_root=$2
            shift 2
            ;;
        --output=*)
            output_root=${1#*=}
            shift
            ;;
        --smoke)
            run_smoke=1
            shift
            ;;
        --allow-other-ubuntu)
            allow_other_ubuntu=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1 (try --help)"
            ;;
    esac
done

work=""
cleanup() {
    local status=$?
    if ((status != 0)) && [[ -n $work ]]; then
        printf '\nFailed; work directory kept for inspection: %s\n' "$work" >&2
    fi
}
trap cleanup EXIT

check_host() {
    [[ "$(uname -s)" == Linux ]] || die "This script must run on Linux, not $(uname -s)."
    host_arch=$(uname -m)
    case "$host_arch" in
        x86_64) ;;
        aarch64|arm64) host_arch=aarch64 ;;
        *) die "Unsupported host architecture: $host_arch. Use x86_64 or aarch64." ;;
    esac

    [[ -r /etc/os-release ]] || die "Missing /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == ubuntu ]] || die "Expected Ubuntu, found ${ID:-unknown}."
    if [[ ${VERSION_ID:-} != 26.04 ]]; then
        if ((allow_other_ubuntu)); then
            warn "Building on Ubuntu ${VERSION_ID:-unknown}; the test bundle will record that host."
        else
            cat >&2 <<'EOF'
Run this inside Ubuntu 26.04. For example, on Apple Silicon with OrbStack:

  orb create ubuntu:26.04 whisky-2604                 # aarch64
  orb create --arch amd64 ubuntu:26.04 whisky-2604-x64 # x86_64
  orb -m whisky-2604                                  # or whisky-2604-x64

Then install Swift 6.4+, Rust 1.99.1, and:

  sudo bash apps/whisky-gpui/tools/install-linux-deps.sh

Use --allow-other-ubuntu only if you intentionally want a different host.
EOF
            exit 1
        fi
    fi

    local missing=()
    local tool
    for tool in swift cargo rustc clang clang++ pkg-config python3 git tar tee \
                sha256sum patchelf ldd readelf file dpkg-query apt-cache \
                find sort xargs awk sed cut head; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    ((${#missing[@]} == 0)) || die "Missing required tools: ${missing[*]}"

    local triple expected
    triple=$(swift -print-target-info | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["target"]["triple"])')
    expected="${host_arch}-unknown-linux-gnu"
    [[ $triple == "$expected" ]] || die \
        "Swift target is '$triple'; expected '$expected' for this host."

    log "Host: Ubuntu ${VERSION_ID:-unknown} $host_arch, kernel $(uname -r)"
    log "Swift: $(swift --version | head -n 1)"
    log "Rust: $(rustc --version)"
}

check_wine_wiring() {
    local driver="WhiskyBridge/Sources/WhiskyApplication/LinuxWineRuntimeDriver.swift"
    [[ -f "$repo_root/$driver" ]] || die \
        "Missing $driver. The Linux Wine runtime wiring is currently uncommitted; " \
        "use a checkout that contains it."
    grep -q -- '--wine-runtime' \
        "$repo_root/WhiskyBridge/Sources/WhiskyBridgeHost/main.swift" || die \
        "WhiskyBridgeHost/main.swift does not accept --wine-runtime."
    grep -q 'WHISKY_WINE_RUNTIME' \
        "$repo_root/apps/whisky-gpui/src/bridge/supervisor.rs" || die \
        "The GPUI supervisor does not forward WHISKY_WINE_RUNTIME."
}

runtime_dir_from_candidate() {
    local candidate=$1
    [[ -n $candidate && -d $candidate ]] || return 1
    if [[ -x $candidate/bin/wine && -d $candidate/lib/wine ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    local hit runtime
    while IFS= read -r hit; do
        runtime=$(dirname -- "$(dirname -- "$hit")")
        if [[ -d $runtime/lib/wine ]]; then
            printf '%s\n' "$runtime"
            return 0
        fi
    done < <(find "$candidate" -maxdepth 4 -type f -path '*/bin/wine' -print 2>/dev/null)
    return 1
}

discover_in_wine_repo() {
    local repo=$1
    [[ -n $repo && -d $repo ]] || return 1
    if [[ -x $repo/bin/wine && -d $repo/lib/wine ]]; then
        printf '%s\n' "$repo"
        return 0
    fi
    [[ -d $repo/outputs ]] || return 1

    local artifact
    artifact=$(find "$repo/outputs" -maxdepth 4 -type f \
            \( -name 'wine-linux-amd64.tar.gz' -o -name 'wine-linux-x86_64.tar.gz' \) \
            -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | sed -n '1p' | cut -d' ' -f2- || true)
    if [[ -n $artifact ]]; then
        printf '%s\n' "$artifact"
        return 0
    fi

    local hit
    hit=$(find "$repo/outputs" -maxdepth 4 -type f \
            \( -path '*/wine-linux-amd64/bin/wine' -o -path '*/wine-linux-x86_64/bin/wine' \) \
            -printf '%T@ %h\n' 2>/dev/null |
        sort -nr | sed -n '1p' | cut -d' ' -f2- || true)
    if [[ -n $hit ]]; then
        printf '%s\n' "$(dirname -- "$hit")"
        return 0
    fi
    return 1
}

resolve_wine() {
    local input=$1
    if [[ -n $input ]]; then
        if [[ -d $input ]]; then
            if [[ -x $input/bin/wine && -d $input/lib/wine ]]; then
                printf '%s\n' "$input"
                return 0
            fi
            if discover_in_wine_repo "$input"; then
                return 0
            fi
            die "--wine directory has no bin/wine or packaged output: $input"
        fi
        if [[ -f $input ]]; then
            printf '%s\n' "$input"
            return 0
        fi
        die "--wine path does not exist: $input"
    fi

    local candidates=()
    if [[ -n ${WHISKY_WINE_REPO:-} ]]; then
        candidates+=("$WHISKY_WINE_REPO")
    fi
    candidates+=(
        "$repo_root/../ge-proton-macos-wine-poc"
        "$repo_root/../wine-macos-ge-proton-poc"
        "$repo_root/../codes/wine-macos-ge-proton-poc"
        "$HOME/codes/ge-proton-macos-wine-poc"
        "$HOME/codes/wine-macos-ge-proton-poc"
    )

    local candidate resolved
    for candidate in "${candidates[@]}"; do
        [[ -n $candidate && -d $candidate ]] || continue
        if resolved=$(discover_in_wine_repo "$candidate"); then
            printf '%s\n' "$resolved"
            return 0
        fi
    done
    die "No Wine Linux artifact found. Pass --wine <runtime-dir-or-tar.gz>. " \
        "The local Wine repository is expected at $repo_root/../ge-proton-macos-wine-poc."
}

elf_arch() {
    local elf=$1 machine
    machine=$(LC_ALL=C readelf -h "$elf" 2>/dev/null |
        sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
    case "$machine" in
        *X86-64*) printf 'x86_64\n' ;;
        *AArch64*) printf 'aarch64\n' ;;
        *) return 1 ;;
    esac
}

prepare_wine() {
    local resolved=$1
    wine_source=$resolved
    if [[ -d $resolved ]]; then
        wine_source_kind=directory
        wine_dir=$(runtime_dir_from_candidate "$resolved") ||
            die "Wine directory does not contain a packaged runtime: $resolved"
    else
        wine_source_kind=archive
        mkdir -p "$work/wine-extract"
        tar -xzf "$resolved" -C "$work/wine-extract" ||
            die "Could not extract Wine archive: $resolved"
        wine_dir=$(runtime_dir_from_candidate "$work/wine-extract") ||
            die "Wine archive does not contain bin/wine: $resolved"
    fi

    [[ -x $wine_dir/bin/wine ]] || die "Wine loader is missing or not executable: $wine_dir/bin/wine"
    [[ -x $wine_dir/bin/wineserver ]] || die "wineserver is missing or not executable: $wine_dir/bin/wineserver"
    [[ -x $wine_dir/run ]] || die "Wine launcher is missing: $wine_dir/run"
    [[ -d $wine_dir/lib/wine ]] || die "Wine module directory is missing: $wine_dir/lib/wine"

    wine_arch=$(elf_arch "$wine_dir/bin/wine") || die \
        "Could not identify the Wine loader ELF architecture: $wine_dir/bin/wine"
    local server_arch
    server_arch=$(elf_arch "$wine_dir/bin/wineserver") || die \
        "Could not identify the wineserver ELF architecture: $wine_dir/bin/wineserver"
    [[ $wine_arch == "$server_arch" ]] || die \
        "Wine loader ($wine_arch) and wineserver ($server_arch) architectures differ."
    if [[ $wine_arch == x86_64 ]]; then
        [[ -d $wine_dir/lib/wine/x86_64-windows ]] || die \
            "Wine runtime has no x86_64-windows modules; it is not the expected build."
    fi
    if [[ $wine_arch == "$host_arch" ]]; then
        foreign_wine=0
    else
        foreign_wine=1
        warn "Wine is $wine_arch but the host is $host_arch."
        warn "The bundle can be assembled, but running Wine needs an $wine_arch"
        warn "binfmt handler (FEX-Emu, Box64, or QEMU) and its library rootfs."
    fi

    log "Wine runtime: $wine_dir ($wine_arch)"
}

build_whisky() {
    log "Building Whisky Linux release (this can take a while)"
    WHISKY_LINUX_RELEASE_OUTPUT="$work/whisky-release" \
        bash "$repo_root/apps/whisky-gpui/tools/build-linux-release.sh" \
        2>&1 | tee "$work/whisky-build.log"

    whisky_archive=$(find "$work/whisky-release" -maxdepth 1 -type f \
        -name 'whisky-linux-*.tar.gz' -print -quit || true)
    [[ -n $whisky_archive ]] || die "Build finished but no Whisky archive was produced."
    log "Whisky archive: $whisky_archive"
}

assemble_bundle() {
    bundle_name="whisky-ubuntu${VERSION_ID:-unknown}-${host_arch}-wine-${wine_arch}-test"
    bundle="$work/$bundle_name"
    mkdir -p "$bundle"
    tar -xzf "$whisky_archive" -C "$bundle" || die "Could not extract Whisky archive."
    [[ -x $bundle/Whisky/Whisky ]] || die "Unexpected Whisky archive layout."
    [[ -f $bundle/Whisky/manifest.json ]] || die "Whisky manifest is missing."

    local wine_manifest=""
    local wine_sums=""
    if [[ $wine_source_kind == archive ]]; then
        local source_dir
        source_dir=$(dirname -- "$wine_source")
        if [[ -f $source_dir/linux-release-manifest.json ]]; then
            wine_manifest=$source_dir/linux-release-manifest.json
        fi
        if [[ -f $source_dir/SHA256SUMS ]]; then
            wine_sums=$source_dir/SHA256SUMS
        fi
    fi

    if [[ $wine_source_kind == archive ]]; then
        mv "$wine_dir" "$bundle/wine"
    else
        cp -a "$wine_dir" "$bundle/wine"
    fi
    [[ -x $bundle/wine/bin/wine ]] || die "Wine was not copied into the bundle."

    if [[ -n $wine_manifest ]]; then
        cp "$wine_manifest" "$bundle/wine-release-manifest.json"
    fi
    if [[ -n $wine_sums ]]; then
        cp "$wine_sums" "$bundle/wine-SHA256SUMS.txt"
    fi

    cat > "$bundle/run-whisky.sh" <<'EOF'
#!/bin/sh
set -eu
self=$(readlink -f -- "$0")
root=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd -P)
export WHISKY_WINE_RUNTIME="$root/wine"
exec "$root/Whisky/Whisky" "$@"
EOF
    chmod 0755 "$bundle/run-whisky.sh"

    cat > "$bundle/run-wine.sh" <<'EOF'
#!/bin/sh
set -eu
self=$(readlink -f -- "$0")
root=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd -P)
prefix=${WINEPREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/whisky-wine-test/prefix}
mkdir -p "$prefix"
export WINEPREFIX="$prefix"
exec "$root/wine/run" "$@"
EOF
    chmod 0755 "$bundle/run-wine.sh"

    cat > "$bundle/README-test-bundle.txt" <<'EOF'
Whisky Linux + Wine test bundle

This is a manual test bundle, not a release artifact. The Ubuntu release,
host architecture, and Wine architecture are recorded in
wine-test-manifest.json.

Layout:
  Whisky/          Unmodified output of build-linux-release.sh
  wine/            The supplied Linux Wine runtime (usually x86_64)
  run-whisky.sh    Launches Whisky with WHISKY_WINE_RUNTIME=<bundle>/wine
  run-wine.sh      Runs Wine directly with a private test prefix
  host-packages-apt.txt
                   Packages observed on the build host for Whisky and Wine
  wine-test-manifest.json
                   Build host, source revisions, and component hashes
  SHA256SUMS       Hashes of this outer test bundle

Install host packages (review the list first):
  sudo apt-get update
  sudo xargs -r -a host-packages-apt.txt apt-get install -y

Run:
  ./run-wine.sh cmd /c ver
  ./run-whisky.sh --print-bridge-status
  ./run-whisky.sh

The bridge status should contain "runtime.launch" when the Wine runtime was
injected. Use run-whisky.sh rather than Whisky/Whisky directly: the outer
launcher is what exports WHISKY_WINE_RUNTIME.

Wine prefix:
  The direct Wine helper uses:
    ${XDG_DATA_HOME:-$HOME/.local/share}/whisky-wine-test/prefix
  Override it with WINEPREFIX=/path/to/prefix ./run-wine.sh ...

Notes and limits:
  - Whisky was built on the Ubuntu release recorded in wine-test-manifest.json.
  - The inner Whisky/manifest.json still records the upstream packaging
    baseline (normally ubuntu-24.04). The actual build host is recorded in
    wine-test-manifest.json; host-packages-apt.txt is generated for that host.
  - The Wine runtime was built separately (usually on Ubuntu 24.04). Its own
    manifest is preserved as wine-release-manifest.json. Rebuild Wine on
    Ubuntu 26.04 if a host ABI incompatibility appears.
  - If wine-test-manifest.json says host=aarch64 and Wine=x86_64, Wine only
    runs through an x86_64 binfmt handler such as FEX-Emu or Box64. Without
    one, run-wine.sh fails with "Exec format error". The x86_64 Wine host
    libraries must come from that emulation rootfs; host-packages-apt.txt
    only maps native Whisky/Wine dependencies.
  - 32-bit Windows programs use new WoW64 and need the Linux i386 syscall
    entry on the host kernel. If 64-bit wine cmd /c ver works but 32-bit
    programs fail, check that compatibility entry.
  - Steam launch orchestration is not implemented by the Linux runtime driver;
    import/configure a bottle and launch a program directly.
  - Keep the directory layout together when moving the bundle.
  - Only run trusted Windows executables.
EOF

    generate_host_packages "$bundle"
}

generate_host_packages() {
    local target_bundle=$1
    local -A packages=()
    local pkg owner lib line elf elf_machine

    add_package() {
        local name=${1%%:*}
        name=${name//$'\r'/}
        if [[ -n $name && $name != *' '* ]]; then
            packages["$name"]=1
        fi
    }

    for pkg in desktop-file-utils xdg-utils dbus-user-session fonts-noto-cjk \
               fonts-liberation webp-pixbuf-loader mesa-vulkan-drivers; do
        add_package "$pkg"
    done

    if [[ -f $target_bundle/Whisky/share/whisky-runtime-packages.txt ]]; then
        while IFS= read -r pkg; do
            pkg=${pkg%%#*}
            pkg=${pkg//[[:space:]]/}
            if [[ -n $pkg ]]; then
                add_package "$pkg"
            fi
        done < "$target_bundle/Whisky/share/whisky-runtime-packages.txt"
    fi

    local -a missing=()
    if ((foreign_wine)); then
        warn "Skipping ldd-based package discovery for $wine_arch Wine on $host_arch."
        warn "Provide the $wine_arch host libraries through your emulation rootfs."
    else
        while IFS= read -r -d '' elf; do
            elf_machine=$(elf_arch "$elf" 2>/dev/null || true)
            [[ $elf_machine == "$wine_arch" ]] || continue
            while IFS= read -r line; do
                if [[ $line == *'not found'* ]]; then
                    missing+=("$elf: $line")
                    continue
                fi
                lib=$(awk '{ if ($2 == "=>") print $3; else if ($1 ~ /^\//) print $1 }' <<<"$line")
                [[ -n $lib && $lib == /* && $lib != "$target_bundle"/* ]] || continue
                owner=$(dpkg-query -S "$lib" 2>/dev/null | sed -n '1s/:.*//p' || true)
                if [[ -n $owner ]]; then
                    add_package "$owner"
                fi
            done < <(ldd "$elf" 2>/dev/null || true)
        done < <(find "$target_bundle/wine" -type f \
            \( -name 'wine' -o -name 'wineserver' -o -name '*.so' -o -name '*.so.*' \) \
            ! -type l -print0)

        if ((${#missing[@]})); then
            warn "These Wine ELF dependencies were not resolved on the build host:"
            printf '  %s\n' "${missing[@]:0:20}" >&2
            warn "The bundle is still created; install the matching host libraries before testing."
        fi
    fi

    local -a selected=()
    for pkg in "${!packages[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            selected+=("$pkg")
        else
            warn "Skipping package not available in this host's apt metadata: $pkg"
        fi
    done
    if ((${#selected[@]})); then
        printf '%s\n' "${selected[@]}" | sort -u > "$target_bundle/host-packages-apt.txt"
    else
        : > "$target_bundle/host-packages-apt.txt"
    fi
}

run_smoke_checks() {
    local bundle=$1
    if ((foreign_wine)); then
        warn "Smoke checks will execute $wine_arch Wine on $host_arch."
        warn "They require a working binfmt handler and its library rootfs."
    fi
    log "Smoke: Wine version"
    WINEPREFIX="$work/smoke-prefix" WINEDEBUG=-all \
        "$bundle/wine/run" --version

    log "Smoke: 64-bit Wine command"
    mkdir -p "$work/smoke-prefix"
    WINEPREFIX="$work/smoke-prefix" WINEDEBUG=-all \
        "$bundle/wine/run" cmd /c ver

    log "Smoke: bridge advertises the runtime service"
    WHISKY_WINE_RUNTIME="$bundle/wine" \
        "$bundle/Whisky/Whisky" --print-bridge-status \
        > "$work/bridge-status.json"
    python3 - "$work/bridge-status.json" "$bundle" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

data = json.load(open(sys.argv[1]))
methods = set(data.get("methods", []))
capabilities = set(data.get("capabilities", []))
required_methods = {
    "runtime.launch",
    "setup.status",
    "bottle.create",
    "bottle.tools",
    "programs.run",
    "winetricks.catalog",
    "winetricks.installed",
    "processes.list",
    "processes.kill",
    "processes.killAll",
}
missing_methods = sorted(required_methods - methods)
if missing_methods:
    raise SystemExit(f"missing bridge methods: {missing_methods}; got {sorted(methods)}")
required_caps = {
    "wine.runtime",
    "wine.prefix.create",
    "wine.configuration",
    "bottle.tools",
    "winetricks.verbs",
    "processes.snapshot",
    "processes.terminate",
}
missing_caps = sorted(required_caps - capabilities)
if missing_caps:
    raise SystemExit(f"missing bridge capabilities: {missing_caps}; got {sorted(capabilities)}")

bundle = Path(sys.argv[2])
helper = bundle / "Whisky/libexec/whisky-bridge"
frames = [
    {"version": 1, "id": "1", "method": "setup.status", "params": {}},
    {"version": 1, "id": "2", "method": "winetricks.catalog", "params": {}},
    {"version": 1, "id": "3", "method": "bridge.shutdown", "params": {}},
]
proc = subprocess.run(
    [str(helper), "--wine-runtime", str(bundle / "wine")],
    input="".join(json.dumps(f) + "\n" for f in frames),
    text=True,
    capture_output=True,
    check=True,
    timeout=30,
)
replies = {r["id"]: r for r in (json.loads(line) for line in proc.stdout.splitlines() if line.strip())}
setup = replies["1"].get("result") or {}
if not setup.get("installed") or not setup.get("rosettaInstalled"):
    raise SystemExit(f"setup.status reported unavailable runtime: {replies['1']}")
catalog = (replies["2"].get("result") or {}).get("categories") or []
if not catalog:
    raise SystemExit(f"winetricks.catalog returned empty catalog: {replies['2']}")
print("bridge methods, capabilities, setup.status, and winetricks.catalog verified:", setup.get("version"))
PY
}

write_manifest() {
    local bundle=$1
    BUNDLE=$bundle \
    REPO_ROOT=$repo_root \
    WHISKY_ARCHIVE=$whisky_archive \
    WINE_SOURCE=$wine_source \
    WINE_SOURCE_KIND=$wine_source_kind \
    WINE_DIR_ORIGIN=$wine_dir \
    HOST_ARCH=$host_arch \
    WINE_ARCH=$wine_arch \
    FOREIGN_WINE=$foreign_wine \
    SWIFT_VERSION="$(swift --version | head -n 1)" \
    RUST_VERSION="$(rustc --version)" \
        python3 - <<'PY'
import datetime
import hashlib
import json
import os
import platform
import subprocess
from pathlib import Path

bundle = Path(os.environ["BUNDLE"])
repo = Path(os.environ["REPO_ROOT"])

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

def os_release():
    data = {}
    path = Path("/etc/os-release")
    if path.is_file():
        for line in path.read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                data[key] = value.strip().strip('"')
    return data

def git(*args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()

whisky_manifest = json.loads((bundle / "Whisky/manifest.json").read_text())
wine_manifest = None
wine_manifest_path = bundle / "wine-release-manifest.json"
if wine_manifest_path.is_file():
    wine_manifest = json.loads(wine_manifest_path.read_text())

source = Path(os.environ["WINE_SOURCE"])
source_kind = os.environ["WINE_SOURCE_KIND"]
archive_sha = digest(source) if source_kind == "archive" else None

data = {
    "formatVersion": 1,
    "purpose": "Manual Whisky + Wine test bundle; not a release artifact",
    "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "host": {
        "osRelease": os_release(),
        "kernel": platform.release(),
        "machine": platform.machine(),
        "architecture": os.environ["HOST_ARCH"],
        "swift": os.environ["SWIFT_VERSION"],
        "rust": os.environ["RUST_VERSION"],
    },
    "whisky": {
        "archive": Path(os.environ["WHISKY_ARCHIVE"]).name,
        "archiveSha256": digest(Path(os.environ["WHISKY_ARCHIVE"])),
        "sourceCommit": whisky_manifest.get("sourceCommit"),
        "sourceTreeDirty": whisky_manifest.get("sourceTreeDirty"),
        "innerDistribution": whisky_manifest.get("distribution"),
        "architecture": whisky_manifest.get("architecture"),
    },
    "wine": {
        "source": str(source),
        "sourceKind": source_kind,
        "archiveSha256": archive_sha,
        "architecture": os.environ["WINE_ARCH"],
        "foreignToHost": os.environ["FOREIGN_WINE"] == "1",
        "runtimeOrigin": os.environ["WINE_DIR_ORIGIN"],
        "entrypoints": {
            "launcher": "wine/run",
            "loader": "wine/bin/wine",
            "wineserver": "wine/bin/wineserver",
        },
        "manifest": wine_manifest,
    },
    "repo": {
        "sourceCommit": git("rev-parse", "HEAD"),
        "sourceTreeDirty": bool(git("status", "--porcelain")),
    },
    "launchers": {
        "whisky": "run-whisky.sh",
        "wine": "run-wine.sh",
    },
    "environment": {
        "WHISKY_WINE_RUNTIME": "<bundle>/wine",
    },
    "notes": [
        "Whisky/ is the unmodified Linux release bundle.",
        "Wine is a sibling runtime and is injected through WHISKY_WINE_RUNTIME.",
        "The inner Whisky manifest still describes its own packaging baseline.",
        "The Wine runtime was built separately and may target a different Ubuntu release.",
    ],
}
(bundle / "wine-test-manifest.json").write_text(json.dumps(data, indent=2) + "\n")
PY
}

write_checksums_and_archive() {
    local bundle=$1
    (cd "$bundle" && find . -type f ! -name SHA256SUMS -print0 |
        sort -z | xargs -0 -r sha256sum) > "$bundle/SHA256SUMS"

    archive="$work/${bundle_name}-$run_id.tar.gz"
    tar -C "$work" -czf "$archive" "$(basename -- "$bundle")"
    sha256sum "$archive" > "$archive.sha256"
}

main() {
    check_host
    check_wine_wiring

    output_root=${output_root:-"$repo_root/build/portability/ubuntu-26.04-wine-test"}
    mkdir -p "$output_root"
    output_root=$(cd -- "$output_root" && pwd -P)
    run_id=$(date -u +%Y%m%d-%H%M%S)
    work=$(mktemp -d "$output_root/run-$run_id-XXXXXX")
    log "Work directory: $work"

    local resolved_wine
    resolved_wine=$(resolve_wine "$wine_input")
    log "Resolved Wine artifact: $resolved_wine"
    prepare_wine "$resolved_wine"
    build_whisky
    assemble_bundle

    if ((run_smoke)); then
        run_smoke_checks "$bundle"
    fi

    write_manifest "$bundle"
    write_checksums_and_archive "$bundle"

    log "Done"
    printf 'Host:        %s\n' "$host_arch"
    if ((foreign_wine)); then
        printf 'Wine:        %s (foreign; binfmt required)\n' "$wine_arch"
    else
        printf 'Wine:        %s\n' "$wine_arch"
    fi
    printf 'Test bundle: %s\n' "$bundle"
    printf 'Archive:     %s\n' "$archive"
    printf 'SHA-256:     %s\n' "$(cut -d' ' -f1 "$archive.sha256")"
    printf '\nExtract and run:\n'
    printf '  tar -xzf %q\n' "$archive"
    printf '  cd %q\n' "$(basename -- "$bundle")"
    printf '  ./run-wine.sh cmd /c ver\n'
    printf '  ./run-whisky.sh\n'
}

main "$@"
