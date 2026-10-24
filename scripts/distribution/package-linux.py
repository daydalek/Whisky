#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Wrap one verified Linux release payload in deb, rpm and AppImage containers."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent
DEPENDENCIES = json.loads((HERE / 'linux-dependencies.json').read_text())
ARCHITECTURES = {'x86_64': ('amd64', 'x86_64', 62), 'aarch64': ('arm64', 'aarch64', 183)}
PRODUCTS = ('whisky-gpui', 'whisky-bridge', 'whisky-file-picker', 'whisky-host-command')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(*args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, **kwargs)


def verify(bundle):
    manifest = json.loads((bundle / 'manifest.json').read_text())
    if manifest.get('formatVersion') != 1 or manifest.get('platform') != 'linux':
        raise ValueError('Expected Linux bundle manifest version 1')
    if manifest['architecture'] not in ARCHITECTURES:
        raise ValueError('Unsupported bundle architecture')
    actual = {str(p.relative_to(bundle)) for p in bundle.rglob('*') if p.is_file()}
    if actual != set(manifest['files']) | {'manifest.json'}:
        raise ValueError('Bundle inventory differs from manifest')
    for name, expected in manifest['files'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Unsafe manifest path')
        path = bundle / relative
        if path.is_symlink() or digest(path) != expected['sha256'] or path.stat().st_size != expected['bytes']:
            raise ValueError('Bundle hash mismatch: ' + name)
        if stat.S_IMODE(path.stat().st_mode) != expected['mode']:
            raise ValueError('Bundle mode mismatch: ' + name)
    for name in PRODUCTS:
        path = bundle / 'bin' / name
        with path.open('rb') as stream:
            header = stream.read(20)
        if header[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', header, 18)[0] != ARCHITECTURES[manifest['architecture']][2]:
            raise ValueError('Product architecture differs from manifest: ' + name)
        if not os.access(path, os.X_OK):
            raise ValueError('Product must be executable: ' + name)
    return manifest


def unpack(archive, output):
    with tarfile.open(archive, 'r:gz') as stream:
        members = stream.getmembers()
        if len(members) > 100_000 or sum(m.size for m in members) > 4_000_000_000:
            raise ValueError('Archive exceeds package limits')
        for member in members:
            parts = Path(member.name).parts
            if not parts or parts[0] != 'Whisky' or '..' in parts or not (member.isfile() or member.isdir()):
                raise ValueError('Unsafe release archive member: ' + member.name)
        stream.extractall(output, filter='data')
    return output / 'Whisky'


def install_assets(stage, bundle):
    shutil.copytree(bundle, stage / 'opt/whisky')
    launcher = stage / 'usr/bin/whisky'
    launcher.parent.mkdir(parents=True)
    launcher.write_text('#!/bin/sh\nexec /opt/whisky/Whisky "$@"\n')
    launcher.chmod(0o755)
    for source, destination in [
        ('com.franke.Whisky.desktop', 'usr/share/applications/com.franke.Whisky.desktop'),
        ('com.franke.Whisky.png', 'usr/share/icons/hicolor/512x512/apps/com.franke.Whisky.png'),
        ('com.franke.Whisky.metainfo.xml', 'usr/share/metainfo/com.franke.Whisky.metainfo.xml'),
    ]:
        path = stage / destination
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE / 'assets' / source, path)
        path.chmod(0o644)
        if path.suffix == '.desktop':
            run('desktop-file-validate', path)
    stage.chmod(0o755)
    for path in stage.rglob('*'):
        if path.is_dir():
            path.chmod(0o755)


def deb(bundle, manifest, version, output, workspace):
    stage = workspace / 'deb'
    install_assets(stage, bundle)
    control = stage / 'DEBIAN/control'
    control.parent.mkdir()
    control.parent.chmod(0o755)
    installed = sum(p.stat().st_size for p in stage.rglob('*') if p.is_file()) // 1024
    control.write_text(f'Package: whisky\nVersion: {version}\nArchitecture: {ARCHITECTURES[manifest["architecture"]][0]}\n'
        'Maintainer: Whisky contributors <noreply@github.com>\nSection: games\nPriority: optional\n'
        f'Installed-Size: {installed}\nDepends: ' + ', '.join(DEPENDENCIES['deb']) + '\n'
        'Recommends: fonts-noto-cjk, mesa-vulkan-drivers\nHomepage: https://github.com/daydalek/Whisky\n'
        'Description: Wine container and Windows game library manager\n'
        ' Wine runtimes download separately into the user data directory.\n')
    control.chmod(0o644)
    path = output / f'whisky_{version}_{ARCHITECTURES[manifest["architecture"]][0]}.deb'
    run('dpkg-deb', '--root-owner-group', '-Zxz', '-z3', '--build', stage, path)
    run('dpkg-deb', '--info', path)
    return path


def rpm(bundle, manifest, version, output, workspace):
    stage = workspace / 'rpm-stage'
    install_assets(stage, bundle)
    portable = stage / 'opt/whisky'
    (portable / 'manifest.json').rename(portable / 'input-manifest.json')
    portable_libraries(portable)
    portable_manifest(portable, manifest)
    launcher = stage / 'usr/bin/whisky'
    launcher.write_text('#!/bin/sh\nset -eu\nroot=/opt/whisky\nbundle="$root"\n' + PORTABLE_RUN)
    launcher.chmod(0o755)
    top = workspace / 'rpmbuild'
    (top / 'SPECS').mkdir(parents=True)
    requires = DEPENDENCIES['rpm'] + [name + '()(64bit)' for name in manifest['systemLibraries']
        if any(name.startswith(prefix) for prefix in DEPENDENCIES['hostLibraries'])]
    spec = top / 'SPECS/whisky.spec'
    spec.write_text(f'''Name: whisky
Version: {version}
Release: 1
Summary: Wine container and Windows game library manager
License: GPL-3.0-or-later
URL: https://github.com/daydalek/Whisky
BuildArch: {ARCHITECTURES[manifest['architecture']][1]}
AutoReqProv: no
Requires: {', '.join(sorted(set(requires)))}
Recommends: google-noto-sans-cjk-fonts
%global debug_package %{{nil}}
%global __os_install_post %{{nil}}
%description
Manage Wine containers and a Windows game library. Wine downloads separately.
%install
mkdir -p "%{{buildroot}}"
cp -a "$WHISKY_RPM_STAGE"/. "%{{buildroot}}"/
%files
%defattr(-,root,root,-)
/opt/whisky
/usr/bin/whisky
/usr/share/applications/com.franke.Whisky.desktop
/usr/share/icons/hicolor/512x512/apps/com.franke.Whisky.png
/usr/share/metainfo/com.franke.Whisky.metainfo.xml
''')
    run('rpmbuild', '--define', '_topdir ' + str(top), '--define', '_build_id_links none',
        '--target', ARCHITECTURES[manifest['architecture']][1], '-bb', spec,
        env=dict(os.environ, WHISKY_RPM_STAGE=str(stage)))
    files = list((top / 'RPMS').rglob('*.rpm'))
    if len(files) != 1:
        raise ValueError('Expected one RPM')
    target = output / files[0].name
    shutil.copyfile(files[0], target)
    run('rpm', '-qp', '--requires', target)
    return target


def download(item, cache):
    target = cache / item['sha256']
    cache.mkdir(parents=True, exist_ok=True)
    if target.exists() and digest(target) == item['sha256']:
        return target
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            request = urllib.request.Request(item['url'], headers={'User-Agent': 'Whisky-build/1'})
            with urllib.request.urlopen(request, timeout=120) as response:
                shutil.copyfileobj(response, stream)
            stream.flush()
            if digest(temporary) != item['sha256']:
                raise ValueError('Packaging tool checksum mismatch: ' + item['url'])
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    return target


def linked_libraries(path):
    result = run('ldd', path)
    if 'not found' in result:
        raise ValueError('Unresolved AppImage dependency: ' + result)
    return {name: Path(location) for name, location in re.findall(
        r'^\s*(\S+)\s+=>\s+(/.*?)\s+\(0x[0-9a-f]+\)', result, re.M)}


def portable_libraries(bundle):
    destination = bundle / 'lib/portable'
    destination.mkdir()
    queue = []
    for path in bundle.rglob('*'):
        if path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) == b'\x7fELF':
                    queue.append(path)
    provenance = {}
    # Image decoders are loaded with dlopen and need their own dependency closure.
    multiarch = run('dpkg-architecture', '-qDEB_HOST_MULTIARCH').strip()
    gdk = Path('/usr/lib') / multiarch / 'gdk-pixbuf-2.0'
    loaders = list(gdk.glob('*/loaders/*.so'))
    loader_dir = bundle / 'lib/pixbuf-loaders'
    loader_dir.mkdir()
    query = list(gdk.glob('gdk-pixbuf-query-loaders'))
    if not loaders or len(query) != 1:
        raise ValueError('Install GdkPixbuf image loaders and query tool before packaging')
    tools = bundle / 'tools'
    tools.mkdir()
    for source in loaders + query:
        target = (loader_dir if source in loaders else tools) / source.name
        shutil.copyfile(source, target)
        target.chmod(0o755)
        queue.append(target)
        provenance[str(source)] = digest(source)
    gio = bundle / 'lib/gio/modules'
    gio.mkdir(parents=True)
    for name in ('libgiognutls.so', 'libdconfsettings.so'):
        source = Path('/usr/lib') / multiarch / 'gio/modules' / name
        if source.is_file():
            target = gio / name
            shutil.copyfile(source, target)
            target.chmod(0o644)
            queue.append(target)
            provenance[str(source)] = digest(source)
    run('gio-querymodules', gio)
    visited = set()
    bundled_swift = {p.name for p in (bundle / 'lib/swift').iterdir()}
    while queue:
        path = queue.pop()
        if path in visited:
            continue
        visited.add(path)
        for name, source in linked_libraries(path).items():
            if name in bundled_swift or any(name.startswith(prefix) for prefix in DEPENDENCIES['hostLibraries']):
                continue
            target = destination / name
            if target.exists():
                if digest(target) != digest(source):
                    raise ValueError('Conflicting portable library: ' + name)
                continue
            shutil.copyfile(source, target)
            target.chmod(0o644)
            provenance[str(source)] = digest(source)
            queue.append(target)
    for path in visited:
        relative = os.path.relpath(destination, path.parent)
        swift = os.path.relpath(bundle / 'lib/swift', path.parent)
        run('patchelf', '--set-rpath', '$ORIGIN:$ORIGIN/' + relative + ':$ORIGIN/' + swift, path)
    schemas = bundle / 'share/glib-2.0/schemas'
    schemas.mkdir(parents=True)
    for source in Path('/usr/share/glib-2.0/schemas').glob('org.gtk.*.xml'):
        shutil.copyfile(source, schemas / source.name)
        provenance[str(source)] = digest(source)
    run('glib-compile-schemas', schemas)
    # Preserve distribution copyright records and exact source-package coordinates.
    packages = {}
    notices = bundle / 'share/licenses/portable'
    notices.mkdir(parents=True)
    for source in provenance:
        candidates = [source, str(Path(source).resolve())]
        if source.startswith('/usr/'):
            candidates.append(source[4:])
        else:
            candidates.append('/usr' + source)
        owner = None
        for candidate in candidates:
            try:
                owner = run('dpkg-query', '-S', candidate, stderr=subprocess.DEVNULL).split(': /', 1)[0].splitlines()[0]
                break
            except subprocess.CalledProcessError:
                continue
        if owner is None:
            raise ValueError('Portable dependency has no distro source record: ' + source)
        if owner in packages:
            continue
        fields = run('dpkg-query', '-W', '-f=${source:Package}\t${source:Version}\t${Version}', owner).split('\t')
        package = owner.split(':')[0]
        copyright_file = Path('/usr/share/doc') / package / 'copyright'
        if copyright_file.is_file():
            shutil.copyfile(copyright_file, notices / (package + '.copyright'))
        packages[owner] = dict(source=fields[0], sourceVersion=fields[1], binaryVersion=fields[2],
            sourceIndex='https://archive.ubuntu.com/ubuntu/pool/')
    report = dict(files=provenance, packages=packages, hostLibraries=DEPENDENCIES['hostLibraries'],
                  baseline=DEPENDENCIES['baseline'])
    (bundle / 'share/portable-dependencies.json').write_text(json.dumps(report, indent=2) + '\n')
    for directory in (destination, loader_dir, gio, schemas, notices):
        directory.chmod(0o755)
        for path in directory.rglob('*'):
            path.chmod(0o755 if path.is_dir() else 0o644)
    tools.chmod(0o755)
    (bundle / 'share/portable-dependencies.json').chmod(0o644)
    return report


PORTABLE_RUN = '''
export GSETTINGS_SCHEMA_DIR="$bundle/share/glib-2.0/schemas"
export GIO_MODULE_DIR="$bundle/lib/gio/modules"
unset GIO_EXTRA_MODULES
export GDK_PIXBUF_MODULEDIR="$bundle/lib/pixbuf-loaders"
if [ -z "${SSL_CERT_FILE:-}" ]; then
    for ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
        if [ -f "$ca" ]; then export SSL_CERT_FILE="$ca"; break; fi
    done
fi
if [ -z "${CURL_CA_BUNDLE:-}" ] && [ -n "${SSL_CERT_FILE:-}" ]; then
    export CURL_CA_BUNDLE="$SSL_CERT_FILE"
fi
cache="${XDG_CACHE_HOME:-$HOME/.cache}/whisky/appimage/$(printf '%s' "$root" | sha256sum | cut -c1-20)"
mkdir -p "$cache"
cache_tmp=$(mktemp "$cache/loaders.XXXXXX")
"$bundle/tools/gdk-pixbuf-query-loaders" "$GDK_PIXBUF_MODULEDIR"/*.so > "$cache_tmp"
mv -f "$cache_tmp" "$cache/loaders.cache"
export GDK_PIXBUF_MODULE_FILE="$cache/loaders.cache"
exec "$bundle/bin/whisky-gpui" "$@"
'''


APPRUN = '''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
bundle="$root/usr/lib/whisky"
''' + PORTABLE_RUN


def portable_manifest(staged, manifest):
    inventory = {str(p.relative_to(staged)): dict(sha256=digest(p), bytes=p.stat().st_size,
                 mode=stat.S_IMODE(p.stat().st_mode)) for p in sorted(staged.rglob('*')) if p.is_file()}
    (staged / 'portable-manifest.json').write_text(json.dumps(dict(inputCommit=manifest['sourceCommit'],
                architecture=manifest['architecture'], files=inventory), indent=2) + '\n')
    (staged / 'portable-manifest.json').chmod(0o644)


def appimage(bundle, manifest, version, output, workspace, cache):
    appdir = workspace / 'Whisky.AppDir'
    staged = appdir / 'usr/lib/whisky'
    shutil.copytree(bundle, staged)
    original_manifest = staged / 'manifest.json'
    original_manifest.rename(staged / 'input-manifest.json')
    closure = portable_libraries(staged)
    # Relocation modifies ELF bytes; keep the original signed inventory separate.
    portable_manifest(staged, manifest)
    (appdir / 'AppRun').write_text(APPRUN)
    (appdir / 'AppRun').chmod(0o755)
    desktop = (HERE / 'assets/com.franke.Whisky.desktop').read_text().replace('Exec=whisky', 'Exec=AppRun').replace('TryExec=whisky\n', '')
    (appdir / 'com.franke.Whisky.desktop').write_text(desktop)
    shutil.copyfile(HERE / 'assets/com.franke.Whisky.png', appdir / 'com.franke.Whisky.png')
    (appdir / '.DirIcon').symlink_to('com.franke.Whisky.png')
    metadata = appdir / 'usr/share/metainfo'
    metadata.mkdir(parents=True)
    shutil.copyfile(HERE / 'assets/com.franke.Whisky.metainfo.xml', metadata / 'com.franke.Whisky.metainfo.xml')
    lock = json.loads((HERE / 'appimage-tools.json').read_text())['architectures'][manifest['architecture']]
    tool, runtime = (download(lock[key], cache) for key in ('tool', 'runtime'))
    executable = workspace / 'appimagetool.AppImage'
    shutil.copyfile(tool, executable)
    executable.chmod(0o755)
    path = output / f'Whisky-{version}-{manifest["architecture"]}.AppImage'
    run(executable, '--appimage-extract-and-run', '--runtime-file', runtime, '--no-appstream',
        appdir, path, env=dict(os.environ, ARCH=manifest['architecture'], VERSION=version))
    path.chmod(0o755)
    return path, closure


def main():
    os.umask(0o022)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--formats', nargs='+', choices=('deb', 'rpm', 'appimage'), default=['deb', 'rpm', 'appimage'])
    parser.add_argument('--tool-cache', type=Path, default=Path(os.environ.get('WHISKY_PACKAGING_TOOL_CACHE',
                        str(Path.home() / '.cache/whisky-packaging-tools'))))
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('--version must be X.Y.Z')
    output = args.output.resolve()
    if output.exists():
        parser.error('Choose a fresh output directory; previous packages are preserved')
    output.mkdir(parents=True)
    report = dict(passed=False, version=args.version, inputSha256=digest(args.archive), assets=[])
    try:
        with tempfile.TemporaryDirectory(prefix='whisky-formats-') as temporary:
            workspace = Path(temporary)
            bundle = unpack(args.archive, workspace)
            manifest = verify(bundle)
            if manifest.get('applicationVersion', args.version) != args.version:
                raise ValueError('Package version must match the input release manifest')
            report.update(architecture=manifest['architecture'], sourceCommit=manifest['sourceCommit'],
                          sourceTreeDirty=manifest.get('sourceTreeDirty'))
            spec = importlib.util.spec_from_file_location('elf_audit', HERE / 'audit-elf.py')
            audit = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(audit)
            abi = audit.audit(bundle, '2.39', shutil.which('readelf'))
            (output / 'elf-abi.json').write_text(json.dumps(abi, indent=2) + '\n')
            if not abi['passed']:
                raise ValueError('Input payload exceeds GLIBC 2.39 baseline')
            for format in dict.fromkeys(args.formats):
                if format == 'appimage':
                    path, closure = appimage(bundle, manifest, args.version, output, workspace, args.tool_cache)
                    report['portableDependencies'] = closure
                else:
                    path = globals()[format](bundle, manifest, args.version, output, workspace)
                report['assets'].append(dict(format=format, name=path.name, sha256=digest(path), bytes=path.stat().st_size))
            report['passed'] = True
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        (output / 'packages.json').write_text(json.dumps(report, indent=2) + '\n')
        files = sorted(p for p in output.iterdir() if p.is_file() and p.name != 'SHA256SUMS')
        (output / 'SHA256SUMS').write_text(''.join(digest(p) + '  ' + p.name + '\n' for p in files))
    print(json.dumps({k: v for k, v in report.items() if k != 'portableDependencies'}, indent=2))


if __name__ == '__main__':
    main()
