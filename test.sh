#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unified test and manual-verification entrypoint for Maltoria.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"

# Colors (disabled when stdout is not a TTY)
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

PASSED_STEPS=()
FAILED_STEPS=()
SKIPPED_STEPS=()
LINUX_BRIDGE_TMP=""

cleanup_tmp() {
    if [[ -n "${LINUX_BRIDGE_TMP:-}" && -d "${LINUX_BRIDGE_TMP:-}" ]]; then
        rm -rf "$LINUX_BRIDGE_TMP"
    fi
}
trap cleanup_tmp EXIT

log_info()  { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()    { printf '%s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%s[SKIP]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
log_err()   { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_head()  { printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; }

die() {
    log_err "$*"
    exit 1
}

require_cmd() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        if [[ -n "$hint" ]]; then
            die "缺少命令 '$cmd'（$hint）"
        fi
        die "缺少命令 '$cmd'"
    fi
}

# Detect Python >= 3.12 for WHISKY_TEST_PYTHON (needed by macOS LinuxWineSetupFixture tarfile tests).
detect_python312() {
    if [[ -n "${WHISKY_TEST_PYTHON:-}" && -x "${WHISKY_TEST_PYTHON:-}" ]]; then
        return 0
    fi
    local candidate
    for candidate in \
        "$(command -v python3 2>/dev/null || true)" \
        "$(command -v python3.13 2>/dev/null || true)" \
        "$(command -v python3.12 2>/dev/null || true)" \
        "/opt/homebrew/bin/python3" \
        "/usr/local/bin/python3"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1; then
            export WHISKY_TEST_PYTHON="$candidate"
            return 0
        fi
    done
    return 0
}

# Record a named step's outcome without aborting multi-step suites immediately unless FAIL_FAST=1.
FAIL_FAST="${WHISKY_TEST_FAIL_FAST:-0}"
run_step() {
    local label="$1"
    shift
    log_head "$label"
    local started ended elapsed
    started="$(date +%s)"
    if "$@"; then
        ended="$(date +%s)"
        elapsed=$((ended - started))
        PASSED_STEPS+=("$label (${elapsed}s)")
        log_ok "$label (${elapsed}s)"
        return 0
    else
        local rc=$?
        ended="$(date +%s)"
        elapsed=$((ended - started))
        FAILED_STEPS+=("$label (exit $rc, ${elapsed}s)")
        log_err "$label failed (exit $rc, ${elapsed}s)"
        if [[ "$FAIL_FAST" == "1" ]]; then
            print_summary
            exit "$rc"
        fi
        return 0
    fi
}

skip_step() {
    local label="$1"
    local reason="$2"
    SKIPPED_STEPS+=("$label ($reason)")
    log_warn "$label — $reason"
}

print_summary() {
    printf '\n%s======================================================================%s\n' "$C_BOLD" "$C_RESET"
    printf '%s测试结果汇总%s (%s / %s)\n' "$C_BOLD" "$C_RESET" "$OS_NAME" "$ARCH_NAME"
    printf '======================================================================\n'
    local item
    for item in ${PASSED_STEPS[@]+"${PASSED_STEPS[@]}"}; do
        printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$item"
    done
    for item in ${SKIPPED_STEPS[@]+"${SKIPPED_STEPS[@]}"}; do
        printf '  %s-%s %s\n' "$C_YELLOW" "$C_RESET" "$item"
    done
    for item in ${FAILED_STEPS[@]+"${FAILED_STEPS[@]}"}; do
        printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$item"
    done
    printf '通过: %d | 跳过: %d | 失败: %d\n' \
        "${#PASSED_STEPS[@]}" "${#SKIPPED_STEPS[@]}" "${#FAILED_STEPS[@]}"
}

finish_steps() {
    print_summary
    if [[ "${#FAILED_STEPS[@]}" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Resolve Linux clang defaults when needed (mirrors check-gpui-foundation.py).
setup_linux_cc_env() {
    if [[ "$OS_NAME" == "Linux" ]]; then
        if [[ -z "${CC:-}" ]]; then
            CC="$(command -v clang-21 || command -v clang || true)"
            [[ -n "$CC" ]] && export CC
        fi
        if [[ -z "${CXX:-}" ]]; then
            CXX="$(command -v clang++-21 || command -v clang-21 || command -v clang++ || true)"
            [[ -n "$CXX" ]] && export CXX
        fi
    fi
}

# Prepare WhiskyBridge package path (isolated copy on Linux to avoid macOS Package.resolved lock conflicts).
prepare_bridge_package_dir() {
    if [[ "$OS_NAME" == "Linux" ]]; then
        if [[ -z "$LINUX_BRIDGE_TMP" || ! -d "$LINUX_BRIDGE_TMP/WhiskyBridge" ]]; then
            require_cmd python3
            LINUX_BRIDGE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/whisky-bridge-linux-XXXXXX")"
            python3 - "$ROOT" "$LINUX_BRIDGE_TMP" <<'PY'
import shutil, sys
from pathlib import Path
root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
shutil.copytree(root / 'WhiskyBridge', tmp / 'WhiskyBridge',
                ignore=shutil.ignore_patterns('.build', '.swiftpm', 'Package.resolved'))
(tmp / 'WhiskyCore').symlink_to(root / 'WhiskyCore', target_is_directory=True)
(tmp / 'WhiskyMetadata').symlink_to(root / 'WhiskyMetadata', target_is_directory=True)
PY
        fi
        printf '%s\n' "$LINUX_BRIDGE_TMP/WhiskyBridge"
    else
        printf '%s\n' "$ROOT/WhiskyBridge"
    fi
}

# Locate an already-built whisky-bridge helper without triggering a full build.
find_built_bridge_helper() {
    local configuration="${1:-debug}"
    local cap="Debug"
    [[ "$configuration" == "release" ]] && cap="Release"
    local candidate
    for candidate in \
        "$ROOT/WhiskyBridge/.build/out/Products/$cap/whisky-bridge" \
        "$ROOT/WhiskyBridge/.build/$configuration/whisky-bridge" \
        "$ROOT/build/test-bridge-linux/$configuration/whisky-bridge" \
        "$ROOT/build/portability/gpui-foundation/bridge-build/$configuration/whisky-bridge"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Build whisky-bridge helper and print its absolute path.
build_bridge_helper() {
    local configuration="${1:-debug}"
    local pkg_dir scratch_args=() build_args=(-c "$configuration" --product whisky-bridge)
    require_cmd swift
    setup_linux_cc_env
    pkg_dir="$(prepare_bridge_package_dir)"
    if [[ "$OS_NAME" == "Linux" ]]; then
        build_args+=(--build-system native)
        scratch_args=(--scratch-path "$ROOT/build/test-bridge-linux")
    fi
    swift build --package-path "$pkg_dir" ${scratch_args[@]+"${scratch_args[@]}"} "${build_args[@]}" >&2
    local bin_dir
    bin_dir="$(swift build --package-path "$pkg_dir" ${scratch_args[@]+"${scratch_args[@]}"} "${build_args[@]}" --show-bin-path)"
    local helper="$bin_dir/whisky-bridge"
    [[ -x "$helper" ]] || die "未找到构建产物: $helper"
    printf '%s\n' "$helper"
}

# Swift package test runner
run_swift_pkg() {
    local pkg="$1"
    shift || true
    require_cmd swift
    detect_python312
    setup_linux_cc_env

    local pkg_path="$ROOT/$pkg"
    local extra_args=()
    if [[ "$pkg" == "WhiskyBridge" ]]; then
        pkg_path="$(prepare_bridge_package_dir)"
        if [[ "$OS_NAME" == "Linux" ]]; then
            extra_args+=(--build-system native --scratch-path "$ROOT/build/test-bridge-linux")
        fi
    elif [[ "$pkg" == "WhiskyMetadata" && "$OS_NAME" == "Linux" ]]; then
        extra_args+=(--build-system native)
    fi

    if [[ "$pkg" == "WhiskyKit" && "$OS_NAME" != "Darwin" ]]; then
        skip_step "Swift: $pkg" "仅支持 macOS"
        return 0
    fi

    (cd "$ROOT" && swift test --package-path "$pkg_path" ${extra_args[@]+"${extra_args[@]}"} "$@")
}

# Rust crate test runners
run_rust_bridge_sdk() {
    local with_helper="$1"
    shift || true
    require_cmd cargo
    detect_python312

    local extra_env=("RUSTC_WRAPPER=")
    local test_args=(--locked --manifest-path "$ROOT/crates/whisky-bridge/Cargo.toml")
    local passthrough=()
    local offline=0
    local filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) offline=1; shift ;;
            --filter) filter="$2"; shift 2 ;;
            *) passthrough+=("$1"); shift ;;
        esac
    done
    [[ "$offline" == "1" ]] && test_args+=(--offline)
    [[ -n "$filter" ]] && passthrough+=("$filter")

    if [[ "$with_helper" == "1" ]]; then
        local helper
        helper="$(build_bridge_helper debug)"
        log_info "WHISKY_BRIDGE_HELPER=$helper"
        extra_env+=("WHISKY_BRIDGE_HELPER=$helper")
        passthrough+=(--include-ignored)
    fi

    if [[ "${#passthrough[@]}" -gt 0 ]]; then
        env "${extra_env[@]}" cargo test "${test_args[@]}" -- "${passthrough[@]}"
    else
        env "${extra_env[@]}" cargo test "${test_args[@]}"
    fi
}

run_rust_gpui() {
    require_cmd cargo
    local test_args=(--locked --manifest-path "$ROOT/apps/whisky-gpui/Cargo.toml")
    local passthrough=()
    local offline=0
    local filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) offline=1; shift ;;
            --filter) filter="$2"; shift 2 ;;
            *) passthrough+=("$1"); shift ;;
        esac
    done
    [[ "$offline" == "1" ]] && test_args+=(--offline)
    [[ -n "$filter" ]] && passthrough+=("$filter")

    local prefix=()
    if [[ "$OS_NAME" == "Linux" ]]; then
        export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
        if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
            if command -v xvfb-run >/dev/null 2>&1; then
                prefix=(xvfb-run -a)
            else
                log_warn "无 DISPLAY/WAYLAND_DISPLAY 且未安装 xvfb-run，尝试直接运行"
            fi
        fi
    fi

    if [[ "${#passthrough[@]}" -gt 0 ]]; then
        RUSTC_WRAPPER="" ${prefix[@]+"${prefix[@]}"} cargo test "${test_args[@]}" -- "${passthrough[@]}"
    else
        RUSTC_WRAPPER="" ${prefix[@]+"${prefix[@]}"} cargo test "${test_args[@]}"
    fi
}

run_python_tests() {
    detect_python312
    local py="${WHISKY_TEST_PYTHON:-python3}"
    require_cmd "$py"
    (cd "$ROOT" && "$py" -m unittest discover -s scripts/distribution -p 'test_*.py' -v)
    (cd "$ROOT" && "$py" -m unittest discover -s scripts -p 'test_bridge_coverage.py' -v)
}

run_foundation() {
    require_cmd python3
    require_cmd swift
    require_cmd cargo
    (cd "$ROOT" && python3 "$ROOT/scripts/check-gpui-foundation.py" "$@")
}

# Action handlers
cmd_doctor() {
    log_head "测试环境检查 ($OS_NAME / $ARCH_NAME)"
    detect_python312

    local tools=(git python3 swift cargo rustc)
    local optional=(swiftlint swiftformat xcodebuild xvfb-run docker)
    local t
    for t in "${tools[@]}"; do
        if command -v "$t" >/dev/null 2>&1; then
            printf '  %s✓%s %-14s %s\n' "$C_GREEN" "$C_RESET" "$t" "$(command -v "$t")"
        else
            printf '  %s✗%s %-14s %s\n' "$C_RED" "$C_RESET" "$t" "未找到"
        fi
    done
    for t in "${optional[@]}"; do
        if command -v "$t" >/dev/null 2>&1; then
            printf '  %s✓%s %-14s %s (可选)\n' "$C_GREEN" "$C_RESET" "$t" "$(command -v "$t")"
        else
            printf '  %s-%s %-14s %s\n' "$C_DIM" "$C_RESET" "$t" "未安装 (可选)"
        fi
    done

    printf '\n版本信息:\n'
    swift --version 2>/dev/null | sed 's/^/  /' || true
    rustc --version 2>/dev/null | sed 's/^/  /' || true
    python3 --version 2>/dev/null | sed 's/^/  /' || true
    if [[ -n "${WHISKY_TEST_PYTHON:-}" ]]; then
        printf '  WHISKY_TEST_PYTHON=%s\n' "$WHISKY_TEST_PYTHON"
    else
        printf '  WHISKY_TEST_PYTHON=未设置 (Python < 3.12 时 macOS 跳过 tarfile 归档测试)\n'
    fi

    printf '\n当前分支状态:\n'
    printf '  Branch : %s\n' "$(git -C "$ROOT" branch --show-current 2>/dev/null || echo 'unknown')"
    if [[ "$OS_NAME" == "Darwin" ]]; then
        printf '  Scope  : macOS 全量可用 (WhiskyCore, WhiskyMetadata, WhiskyBridge, WhiskyKit, Rust, Python, WhiskyCmd)\n'
    else
        printf '  Scope  : Linux 可用 (WhiskyCore, WhiskyMetadata, WhiskyBridge, Rust, Python; 跳过 WhiskyKit/WhiskyCmd)\n'
    fi
}

cmd_all() {
    local foundation_args=() cargo_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) foundation_args+=(--offline); cargo_args+=(--offline); shift ;;
            --coverage) foundation_args+=(--coverage); shift ;;
            *) die "未知参数: $1" ;;
        esac
    done

    run_step "GPUI Foundation 门禁 (Core/Metadata/Bridge + 真实 helper Rust SDK)" \
        run_foundation ${foundation_args[@]+"${foundation_args[@]}"}

    if [[ "$OS_NAME" == "Darwin" ]]; then
        local kit_args=()
        [[ "${#cargo_args[@]}" -gt 0 ]] && kit_args+=(--disable-automatic-resolution --skip-update)
        run_step "WhiskyKit 测试套件 (含 WineEngine / Lease / Integration)" \
            run_swift_pkg WhiskyKit ${kit_args[@]+"${kit_args[@]}"}
    else
        skip_step "WhiskyKit 测试套件" "仅支持 macOS"
    fi

    run_step "apps/whisky-gpui 测试套件 (单元测试 + 无头状态机)" \
        run_rust_gpui ${cargo_args[@]+"${cargo_args[@]}"}

    run_step "Python 构建与覆盖率脚本测试" \
        run_python_tests

    finish_steps
}

cmd_engines() {
    local offline=0
    local swift_extra=()
    local rust_extra=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) offline=1; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done
    if [[ "$offline" == "1" ]]; then
        swift_extra+=(--disable-automatic-resolution --skip-update)
        rust_extra+=(--offline)
    fi

    run_step "WhiskyCore 跨平台测试" \
        run_swift_pkg WhiskyCore ${swift_extra[@]+"${swift_extra[@]}"}

    if [[ "$OS_NAME" == "Darwin" ]]; then
        run_step "WhiskyKit 引擎与租约测试 (WineEngine / Lease / Integration)" \
            run_swift_pkg WhiskyKit --filter "WineEngine|ScopedManagedInstall|Engine|Lease|winetricksEnvironment" ${swift_extra[@]+"${swift_extra[@]}"}
    else
        skip_step "WhiskyKit 引擎与租约测试" "仅支持 macOS"
    fi

    run_step "WhiskyBridge 引擎测试 (Native + LinuxWineEngineTests)" \
        run_swift_pkg WhiskyBridge --filter "Engine" ${swift_extra[@]+"${swift_extra[@]}"}

    run_step "crates/whisky-bridge 协议与真实 helper 测试" \
        run_rust_bridge_sdk 1 ${rust_extra[@]+"${rust_extra[@]}"}

    run_step "apps/whisky-gpui 引擎 DTO/状态机/UI 测试" \
        run_rust_gpui --filter "engine" ${rust_extra[@]+"${rust_extra[@]}"}

    finish_steps
}

cmd_swift() {
    local target="all"
    if [[ $# -gt 0 && "$1" != -* ]]; then
        target="$1"
        shift
    fi

    local filter="" coverage=0 offline=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --filter) filter="${2:?--filter 需要匹配模式}"; shift 2 ;;
            --coverage) coverage=1; shift ;;
            --offline) offline=1; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done

    local swift_args=()
    [[ -n "$filter" ]] && swift_args+=(--filter "$filter")
    [[ "$coverage" == "1" ]] && swift_args+=(--enable-code-coverage)
    [[ "$offline" == "1" ]] && swift_args+=(--disable-automatic-resolution --skip-update)

    case "$target" in
        core)
            run_step "Swift: WhiskyCore" run_swift_pkg WhiskyCore ${swift_args[@]+"${swift_args[@]}"}
            ;;
        metadata)
            run_step "Swift: WhiskyMetadata" run_swift_pkg WhiskyMetadata ${swift_args[@]+"${swift_args[@]}"}
            ;;
        bridge)
            run_step "Swift: WhiskyBridge" run_swift_pkg WhiskyBridge ${swift_args[@]+"${swift_args[@]}"}
            ;;
        kit)
            run_step "Swift: WhiskyKit" run_swift_pkg WhiskyKit ${swift_args[@]+"${swift_args[@]}"}
            ;;
        all)
            run_step "Swift: WhiskyCore" run_swift_pkg WhiskyCore ${swift_args[@]+"${swift_args[@]}"}
            run_step "Swift: WhiskyMetadata" run_swift_pkg WhiskyMetadata ${swift_args[@]+"${swift_args[@]}"}
            run_step "Swift: WhiskyBridge" run_swift_pkg WhiskyBridge ${swift_args[@]+"${swift_args[@]}"}
            run_step "Swift: WhiskyKit" run_swift_pkg WhiskyKit ${swift_args[@]+"${swift_args[@]}"}
            ;;
        *)
            die "未知 Swift 目标: $target（可选: core, metadata, bridge, kit, all）"
            ;;
    esac
    finish_steps
}

cmd_rust() {
    local target="all"
    if [[ $# -gt 0 && "$1" != -* ]]; then
        target="$1"
        shift
    fi

    local with_helper=1
    local pass_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-helper) with_helper=0; shift ;;
            --with-helper) with_helper=1; shift ;;
            --filter) pass_args+=(--filter "${2:?--filter 需要匹配模式}"); shift 2 ;;
            --offline) pass_args+=(--offline); shift ;;
            *) die "未知参数: $1" ;;
        esac
    done

    case "$target" in
        bridge-sdk|sdk)
            run_step "Rust: crates/whisky-bridge" \
                run_rust_bridge_sdk "$with_helper" ${pass_args[@]+"${pass_args[@]}"}
            ;;
        gpui)
            run_step "Rust: apps/whisky-gpui" \
                run_rust_gpui ${pass_args[@]+"${pass_args[@]}"}
            ;;
        all)
            run_step "Rust: crates/whisky-bridge" \
                run_rust_bridge_sdk "$with_helper" ${pass_args[@]+"${pass_args[@]}"}
            run_step "Rust: apps/whisky-gpui" \
                run_rust_gpui ${pass_args[@]+"${pass_args[@]}"}
            ;;
        *)
            die "未知 Rust 目标: $target（可选: bridge-sdk, gpui, all）"
            ;;
    esac
    finish_steps
}

cmd_python() {
    run_step "Python: scripts/distribution & test_bridge_coverage" run_python_tests
    finish_steps
}

cmd_lint() {
    require_cmd python3
    if command -v swiftformat >/dev/null 2>&1; then
        run_step "SwiftFormat lint" bash -c "cd '$ROOT' && swiftformat --lint ."
    else
        skip_step "SwiftFormat lint" "未安装 swiftformat"
    fi

    if command -v swiftlint >/dev/null 2>&1; then
        run_step "SwiftLint strict" bash -c "cd '$ROOT' && swiftlint --strict"
    else
        skip_step "SwiftLint strict" "未安装 swiftlint"
    fi

    run_step "Third-party 清单校验 (scripts/check-third-party.py)" \
        bash -c "cd '$ROOT' && python3 scripts/check-third-party.py"

    finish_steps
}

cmd_e2e() {
    require_cmd python3
    log_head "WoW64 E2E 测试套件 (tests/e2e_runner.sh)"
    exec bash "$ROOT/tests/e2e_runner.sh" "$@"
}

cmd_live_wine() {
    [[ "$OS_NAME" == "Darwin" ]] || die "live-wine 测试仅支持 macOS"
    require_cmd swift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wine-bin) export WHISKY_LIVE_WINE_BINARY="${2:?--wine-bin 需要路径}"; shift 2 ;;
            --prefix) export WHISKY_LIVE_WINE_PREFIX="${2:?--prefix 需要路径}"; shift 2 ;;
            --exe) export WHISKY_LIVE_WINE_EXE="${2:?--exe 需要路径}"; shift 2 ;;
            *) die "未知参数: $1" ;;
        esac
    done

    if [[ -z "${WHISKY_LIVE_WINE_BINARY:-}" ]]; then
        die "请设置 WHISKY_LIVE_WINE_BINARY 或传入 --wine-bin <wine64路径>"
    fi

    log_info "WHISKY_LIVE_WINE_BINARY=${WHISKY_LIVE_WINE_BINARY}"
    [[ -n "${WHISKY_LIVE_WINE_PREFIX:-}" ]] && log_info "WHISKY_LIVE_WINE_PREFIX=${WHISKY_LIVE_WINE_PREFIX}"
    [[ -n "${WHISKY_LIVE_WINE_EXE:-}" ]] && log_info "WHISKY_LIVE_WINE_EXE=${WHISKY_LIVE_WINE_EXE}"

    run_step "WhiskyKit LiveWineSessionTests" \
        run_swift_pkg WhiskyKit --filter LiveWineSessionTests
    finish_steps
}

cmd_linux_full() {
    [[ "$OS_NAME" == "Linux" ]] || die "linux-full 仅支持 Linux 环境"
    exec bash "$ROOT/apps/whisky-gpui/tools/check-linux.sh" "$@"
}

apply_sandbox_env() {
    local sandbox_dir="$1"
    mkdir -p "$sandbox_dir/config" "$sandbox_dir/data" "$sandbox_dir/state"
    export XDG_CONFIG_HOME="$sandbox_dir/config"
    export XDG_DATA_HOME="$sandbox_dir/data"
    export WHISKY_GPUI_STATE="$sandbox_dir/state/gpui-state.json"
    export WHISKY_GPUI_APPEARANCE_STATE="$sandbox_dir/state/appearance.json"
    export WHISKY_REGISTRY="$sandbox_dir/BottleVM.plist"
    export WHISKY_WINE_ENGINES_REGISTRY="$sandbox_dir/Wine Engines.json"
    log_info "已启用隔离沙箱目录: $sandbox_dir"
    log_info "  WHISKY_REGISTRY=$WHISKY_REGISTRY"
    log_info "  WHISKY_WINE_ENGINES_REGISTRY=$WHISKY_WINE_ENGINES_REGISTRY"
}

build_gpui_binary() {
    local profile="${1:-debug}"
    local skip_build="${2:-0}"
    local cargo_flags=(--locked --manifest-path "$ROOT/apps/whisky-gpui/Cargo.toml")
    local bin="$ROOT/apps/whisky-gpui/target/$profile/whisky-gpui"
    if [[ "$profile" == "release" ]]; then
        cargo_flags+=(--release)
    fi
    if [[ "$skip_build" != "1" ]]; then
        require_cmd cargo
        log_info "构建 whisky-gpui ($profile)..." >&2
        RUSTC_WRAPPER="" cargo build "${cargo_flags[@]}" >&2
    fi
    [[ -x "$bin" ]] || die "未找到 whisky-gpui 可执行文件: $bin"
    printf '%s\n' "$bin"
}

cmd_gui() {
    local demo=0 sandbox=0 clean_sandbox=0 no_wine=0 release=0 skip_build=0
    local sandbox_dir="${WHISKY_TEST_SANDBOX:-$ROOT/build/manual-test-sandbox}"
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --demo) demo=1; shift ;;
            --sandbox) sandbox=1; shift ;;
            --clean-sandbox) clean_sandbox=1; sandbox=1; shift ;;
            --sandbox-dir) sandbox=1; sandbox_dir="${2:?--sandbox-dir 需要路径}"; shift 2 ;;
            --no-wine) no_wine=1; shift ;;
            --release) release=1; shift ;;
            --skip-build) skip_build=1; shift ;;
            --) shift; extra_args=("$@"); break ;;
            *) extra_args+=("$1"); shift ;;
        esac
    done

    if [[ "$clean_sandbox" == "1" && -d "$sandbox_dir" ]]; then
        log_info "清理旧沙箱目录: $sandbox_dir"
        rm -rf "$sandbox_dir"
    fi
    [[ "$sandbox" == "1" ]] && apply_sandbox_env "$sandbox_dir"
    [[ "$demo" == "1" ]] && export WHISKY_GPUI_DEMO_DATA=1
    [[ "$no_wine" == "1" ]] && export WHISKY_BRIDGE_NO_WINE=1

    local profile="debug"
    [[ "$release" == "1" ]] && profile="release"

    local helper=""
    if [[ "$skip_build" != "1" ]]; then
        log_info "构建 whisky-bridge ($profile)..."
        helper="$(build_bridge_helper "$profile")"
    else
        helper="$(find_built_bridge_helper "$profile" || true)"
        [[ -x "$helper" ]] || die "未找到已构建的 whisky-bridge（去掉 --skip-build 以自动构建）"
    fi
    export WHISKY_BRIDGE_HELPER="$helper"
    log_info "WHISKY_BRIDGE_HELPER=$WHISKY_BRIDGE_HELPER"

    local bin
    bin="$(build_gpui_binary "$profile" "$skip_build")"
    log_head "启动 Maltoria GPUI ($profile)"
    exec "$bin" ${extra_args[@]+"${extra_args[@]}"}
}

cmd_diag() {
    local mode="${1:-status}"
    if [[ $# -gt 0 && "$1" != -* ]]; then
        shift
    fi

    local sandbox=0 no_wine=0 skip_build=0 bottle="" entry="" seconds=""
    local sandbox_dir="${WHISKY_TEST_SANDBOX:-$ROOT/build/manual-test-sandbox}"
    local raw_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sandbox) sandbox=1; shift ;;
            --sandbox-dir) sandbox=1; sandbox_dir="${2:?--sandbox-dir 需要路径}"; shift 2 ;;
            --no-wine) no_wine=1; shift ;;
            --skip-build) skip_build=1; shift ;;
            --bottle) bottle="${2:?--bottle 需要名称或路径}"; shift 2 ;;
            --entry) entry="${2:?--entry 需要关键字}"; shift 2 ;;
            --seconds) seconds="${2:?--seconds 需要秒数}"; shift 2 ;;
            --) shift; raw_args+=("$@"); break ;;
            *) raw_args+=("$1"); shift ;;
        esac
    done

    [[ "$sandbox" == "1" ]] && apply_sandbox_env "$sandbox_dir"
    [[ "$no_wine" == "1" ]] && export WHISKY_BRIDGE_NO_WINE=1

    local helper=""
    if [[ "$skip_build" != "1" ]]; then
        helper="$(build_bridge_helper debug)"
    else
        helper="$(find_built_bridge_helper debug || true)"
        [[ -x "$helper" ]] || die "未找到已构建的 whisky-bridge（去掉 --skip-build 以自动构建）"
    fi
    export WHISKY_BRIDGE_HELPER="$helper"

    local bin
    bin="$(build_gpui_binary debug "$skip_build")"

    local args=()
    case "$mode" in
        status)     args=(--print-bridge-status) ;;
        runtime)    args=(--print-runtime) ;;
        library)    args=(--print-library); [[ -z "$bottle" ]] && args+=(--all) ;;
        config)     args=(--print-config) ;;
        folders)    args=(--print-folders) ;;
        winetricks) args=(--print-winetricks) ;;
        programs)   args=(--print-programs) ;;
        processes)  args=(--print-processes) ;;
        watch)      args=(--runtime-watch) ;;
        launch)     args=(--diagnose-launch) ;;
        raw)        args=() ;;
        *) die "未知诊断模式: $mode（可选: status, runtime, library, config, folders, winetricks, programs, processes, watch, launch, raw）" ;;
    esac

    [[ -n "$bottle" ]] && args+=(--bottle "$bottle")
    [[ -n "$entry" ]] && args+=(--entry "$entry")
    [[ -n "$seconds" ]] && args+=(--seconds "$seconds")
    args+=(${raw_args[@]+"${raw_args[@]}"})

    log_head "whisky-gpui 诊断 ($mode)"
    exec "$bin" "${args[@]}"
}

cmd_cmd() {
    [[ "$OS_NAME" == "Darwin" ]] || die "WhiskyCmd 仅支持 macOS"
    local skip_build=0
    local pass_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-build) skip_build=1; shift ;;
            --) shift; pass_args=("$@"); break ;;
            *) pass_args+=("$1"); shift ;;
        esac
    done

    local derived="$ROOT/build/whisky-cmd"
    local bin="$derived/Build/Products/Debug/WhiskyCmd"
    if [[ "$skip_build" != "1" ]]; then
        require_cmd xcodebuild
        log_head "构建 WhiskyCmd (Debug)"
        xcodebuild -project "$ROOT/Whisky.xcodeproj" \
            -scheme WhiskyCmd \
            -configuration Debug \
            -derivedDataPath "$derived" \
            build
    fi
    [[ -x "$bin" ]] || die "未找到 WhiskyCmd: $bin"
    if [[ "${#pass_args[@]}" -eq 0 ]]; then
        pass_args=(--help)
    fi
    exec "$bin" "${pass_args[@]}"
}

cmd_list() {
    cat <<'EOF'
可用测试与手动验证命令 (./test.sh <command> [options]):

  自动化测试:
    all         运行当前平台完整测试套件 (foundation + WhiskyKit[macOS] + gpui + python)
    engines     快速聚焦本分支 (feat/custom-wine-engines) 自定义 Wine 引擎相关测试
    foundation  运行 GPUI Foundation 门禁 (scripts/check-gpui-foundation.py)
    swift       运行 Swift 包测试: [core|metadata|bridge|kit|all] [--filter <pat>] [--coverage] [--offline]
    rust        运行 Rust 测试: [bridge-sdk|gpui|all] [--filter <pat>] [--no-helper] [--offline]
    python      运行 Python unittest (scripts/distribution + test_bridge_coverage.py)
    lint        运行 swiftformat --lint、swiftlint --strict 与 check-third-party.py
    doctor      检查本机工具链、Python 版本与平台测试范围

  快捷别名:
    core | metadata | bridge | kit    等同于 ./test.sh swift <pkg>
    bridge-sdk | gpui                 等同于 ./test.sh rust <target>

  专项/平台测试:
    e2e         运行 WoW64 E2E 测试 (tests/e2e_runner.sh, 可传 --tier 1..4 / --verbose)
    live-wine   运行 macOS 真实 Wine 会话测试 (--wine-bin <path> [--prefix <p>] [--exe <e>])
    linux-full  运行 Linux 完整验收脚本 (apps/whisky-gpui/tools/check-linux.sh)

  手动交互测试:
    gui         构建并启动 Maltoria GPUI (支持 --demo, --sandbox, --clean-sandbox, --no-wine, --release)
    diag        运行 whisky-gpui 无头诊断 (status|runtime|library|config|folders|winetricks|programs|processes|launch|watch|raw)
    cmd         构建并运行 macOS WhiskyCmd CLI (如: ./test.sh cmd list)
EOF
}

cmd_help() {
    cat <<'EOF'
Maltoria 统一测试与手动验证入口 (test.sh)

用法:
  ./test.sh                        在终端中打开交互式测试菜单
  ./test.sh <command> [options]    直接执行指定测试或手动工具

EOF
    cmd_list
    cat <<'EOF'

常用示例:
  ./test.sh engines                   # 仅跑本分支自定义 Wine 引擎测试（最快）
  ./test.sh all                       # 跑当前平台全量测试
  ./test.sh swift kit --filter WineEngine
  ./test.sh rust bridge-sdk           # 自动构建 whisky-bridge 并运行 --include-ignored 真实集成测试
  ./test.sh gui --sandbox --no-wine   # 隔离配置/容器启动 GPUI 手动测自定义引擎 UI
  ./test.sh gui --demo                # 用内置 32 款演示数据启动 GPUI
  ./test.sh diag status               # 打印 bridge 状态 JSON
  ./test.sh diag library              # 扫描并打印全部容器库 JSON
  ./test.sh cmd list                  # 使用当前分支代码构建并运行 WhiskyCmd list

环境变量:
  WHISKY_TEST_FAIL_FAST=1             # 多步测试中任一步失败立即停止
  WHISKY_TEST_PYTHON=<path>           # 指定 Python (>=3.12) 用于 Swift 归档测试
  WHISKY_TEST_SANDBOX=<dir>           # 自定义 gui/diag --sandbox 隔离目录
EOF
}

cmd_menu() {
    if [[ ! -t 0 ]]; then
        cmd_help
        return 0
    fi

    while true; do
        printf '\n%s%sMaltoria 测试与手动验证中心%s (%s / %s)\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$OS_NAME" "$ARCH_NAME"
        printf '────────────────────────────────────────────────────────\n'
        printf '  %s1.%s 本分支引擎专项回归 (engines)       [推荐·最快]\n' "$C_BOLD" "$C_RESET"
        printf '  %s2.%s 当前平台全量测试     (all)\n' "$C_BOLD" "$C_RESET"
        printf '  %s3.%s GPUI Foundation 门禁 (foundation)\n' "$C_BOLD" "$C_RESET"
        printf '  %s4.%s Swift 测试           (core/metadata/bridge/kit)\n' "$C_BOLD" "$C_RESET"
        printf '  %s5.%s Rust 测试            (bridge-sdk + gpui)\n' "$C_BOLD" "$C_RESET"
        printf '  %s6.%s Python 单元测试      (python)\n' "$C_BOLD" "$C_RESET"
        printf '  %s7.%s 代码规范与清单校验   (lint)\n' "$C_BOLD" "$C_RESET"
        printf '  %s8.%s 环境依赖自检         (doctor)\n' "$C_BOLD" "$C_RESET"
        printf '  %s9.%s WoW64 E2E 测试       (e2e)\n' "$C_BOLD" "$C_RESET"
        printf ' %s10.%s 真实 Wine 会话测试   (live-wine, macOS)\n' "$C_BOLD" "$C_RESET"
        printf ' %s11.%s Linux 完整验收       (linux-full, Linux)\n' "$C_BOLD" "$C_RESET"
        printf ' ── 手动交互入口 ───────────────────────────────────────\n'
        printf ' %s12.%s 启动 GPUI 应用       (gui, 可选沙箱/Demo)\n' "$C_BOLD" "$C_RESET"
        printf ' %s13.%s 无头桥接/库诊断      (diag)\n' "$C_BOLD" "$C_RESET"
        printf ' %s14.%s 运行 WhiskyCmd CLI   (cmd, macOS)\n' "$C_BOLD" "$C_RESET"
        printf '  %s0.%s 退出\n' "$C_BOLD" "$C_RESET"

        local choice=""
        read -r -p $'\n请选择编号 [1]: ' choice || return 0
        choice="${choice:-1}"

        # Reset per-run counters when looping in menu
        PASSED_STEPS=()
        FAILED_STEPS=()
        SKIPPED_STEPS=()

        case "$choice" in
            0) return 0 ;;
            1) cmd_engines || true ;;
            2) cmd_all || true ;;
            3) run_step "GPUI Foundation 门禁" run_foundation; finish_steps || true ;;
            4)
                local pkg="" flt=""
                read -r -p "选择包 (all/core/metadata/bridge/kit) [all]: " pkg
                pkg="${pkg:-all}"
                read -r -p "过滤条件 (--filter，留空不过滤): " flt
                if [[ -n "$flt" ]]; then
                    cmd_swift "$pkg" --filter "$flt" || true
                else
                    cmd_swift "$pkg" || true
                fi
                ;;
            5)
                local rtarget=""
                read -r -p "选择 Rust 目标 (all/bridge-sdk/gpui) [all]: " rtarget
                rtarget="${rtarget:-all}"
                cmd_rust "$rtarget" || true
                ;;
            6) cmd_python || true ;;
            7) cmd_lint || true ;;
            8) cmd_doctor ;;
            9)
                local tier=""
                read -r -p "选择 Tier (1/2/3/4 或 all) [all]: " tier
                tier="${tier:-all}"
                if [[ "$tier" == "all" ]]; then
                    (cmd_e2e --all) || true
                else
                    (cmd_e2e --tier "$tier") || true
                fi
                ;;
            10)
                local wb="${WHISKY_LIVE_WINE_BINARY:-}" wp="${WHISKY_LIVE_WINE_PREFIX:-}" we="${WHISKY_LIVE_WINE_EXE:-}"
                read -r -p "wine64 路径 [$wb]: " input_wb
                wb="${input_wb:-$wb}"
                read -r -p "bottle prefix 路径 (可选) [$wp]: " input_wp
                wp="${input_wp:-$wp}"
                read -r -p "Windows exe 路径 (可选) [$we]: " input_we
                we="${input_we:-$we}"
                local lw_args=(--wine-bin "$wb")
                [[ -n "$wp" ]] && lw_args+=(--prefix "$wp")
                [[ -n "$we" ]] && lw_args+=(--exe "$we")
                (cmd_live_wine "${lw_args[@]}") || true
                ;;
            11) (cmd_linux_full) || true ;;
            12)
                local gmode=""
                printf '启动模式: 1. 隔离沙箱 (--sandbox --no-wine)  2. 真实环境  3. Demo 数据 (--demo)\n'
                read -r -p "选择 [1]: " gmode
                gmode="${gmode:-1}"
                case "$gmode" in
                    1) (cmd_gui --sandbox --no-wine) || true ;;
                    2) (cmd_gui) || true ;;
                    3) (cmd_gui --demo --no-wine) || true ;;
                    *) log_err "无效选择: $gmode" ;;
                esac
                ;;
            13)
                local dmode=""
                read -r -p "诊断模式 (status/runtime/library/config/folders/programs/processes/launch) [status]: " dmode
                dmode="${dmode:-status}"
                if [[ "$dmode" == "launch" || "$dmode" == "config" || "$dmode" == "folders" || "$dmode" == "programs" || "$dmode" == "processes" ]]; then
                    local dbottle=""
                    read -r -p "容器名称或路径 (可留空): " dbottle
                    if [[ -n "$dbottle" ]]; then
                        (cmd_diag "$dmode" --bottle "$dbottle") || true
                    else
                        (cmd_diag "$dmode") || true
                    fi
                else
                    (cmd_diag "$dmode") || true
                fi
                ;;
            14)
                local cargs=""
                read -r -p "WhiskyCmd 参数 (如 list / shellenv <bottle>) [list]: " cargs
                cargs="${cargs:-list}"
                # shellcheck disable=SC2086
                (cmd_cmd $cargs) || true
                ;;
            *)
                log_err "无效编号: $choice"
                ;;
        esac
    done
}

main() {
    if [[ $# -eq 0 ]]; then
        cmd_menu
        return $?
    fi

    local subcmd="$1"
    shift
    case "$subcmd" in
        menu) cmd_menu "$@" ;;
        list) cmd_list ;;
        help|-h|--help) cmd_help ;;
        doctor) cmd_doctor ;;
        all) cmd_all "$@" ;;
        engines) cmd_engines "$@" ;;
        foundation)
            run_step "GPUI Foundation 门禁" run_foundation "$@"
            finish_steps
            ;;
        swift) cmd_swift "$@" ;;
        core|metadata|bridge|kit) cmd_swift "$subcmd" "$@" ;;
        rust) cmd_rust "$@" ;;
        bridge-sdk|gpui) cmd_rust "$subcmd" "$@" ;;
        python) cmd_python "$@" ;;
        lint) cmd_lint "$@" ;;
        e2e) cmd_e2e "$@" ;;
        live-wine) cmd_live_wine "$@" ;;
        linux-full) cmd_linux_full "$@" ;;
        gui) cmd_gui "$@" ;;
        diag) cmd_diag "$@" ;;
        cmd) cmd_cmd "$@" ;;
        *)
            log_err "未知命令: $subcmd"
            printf '运行 ./test.sh --help 查看全部可用命令。\n' >&2
            return 2
            ;;
    esac
}

main "$@"
