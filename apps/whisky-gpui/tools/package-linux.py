#!/usr/bin/env python3
"""Package trusted Linux release products with relative Swift runtime paths and source evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[3]
TOOLS = Path(__file__).resolve().parent
PRODUCTS = ('whisky-gpui', 'whisky-bridge', 'whisky-file-picker', 'whisky-host-command')


def command(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def elf_machine(path):
    with path.open('rb') as stream:
        header = stream.read(20)
    if len(header) < 20 or header[:6] != b'\x7fELF\x02\x01':
        raise ValueError(f'Expected a little-endian ELF64 product: {path}')
    machine = struct.unpack_from('<H', header, 18)[0]
    if machine not in (62, 183):
        raise ValueError(f'Unsupported Linux ELF machine {machine}: {path}')
    return machine


def dependencies(path):
    result = command('ldd', path)
    if 'not found' in result:
        raise ValueError(f'Unresolved build dependency for {path}:\n{result}')
    return {name: Path(location) for name, location in re.findall(
        r'^\s*(\S+)\s+=>\s+(/.*?)\s+\(0x[0-9a-f]+\)', result, re.MULTILINE)}


def copy_sources(output, target):
    destination = output / 'share/whisky/sources'
    destination.mkdir(parents=True)
    paths = command('git', '-C', ROOT, 'ls-files', '--cached', '--others', '--exclude-standard', '--',
                    'LICENSE', 'WhiskyCore', 'WhiskyMetadata', 'WhiskyBridge', 'crates', 'apps/whisky-gpui',
                    'scripts/check-gpui-foundation.py').splitlines()
    with tarfile.open(destination / 'application.tar.gz', 'w:gz') as archive:
        for relative in sorted(set(paths)):
            path = ROOT / relative
            if path.is_file() or path.is_symlink():
                archive.add(path, arcname=relative, recursive=False)
    lock = tomllib.loads((ROOT / 'apps/whisky-gpui/Cargo.lock').read_text())
    checksums = {(p['name'], p['version']): p['checksum'] for p in lock['package'] if 'checksum' in p}
    metadata = json.loads(command('cargo', 'metadata', '--locked', '--offline', '--format-version', '1',
                                  '--filter-platform', target, '--manifest-path', ROOT / 'apps/whisky-gpui/Cargo.toml'))
    resolved = {node['id'] for node in metadata['resolve']['nodes']}
    crates = destination / 'crates'
    licenses = output / 'share/licenses/whisky/crates'
    crates.mkdir()
    licenses.mkdir(parents=True)
    inventory = []
    for package in metadata['packages']:
        if package['id'] not in resolved or package['source'] is None:
            continue
        source = Path(package['manifest_path']).parent
        name = f"{package['name']}-{package['version']}"
        cached = source.parents[2] / 'cache' / source.parent.name / (name + '.crate')
        checksum = checksums[(package['name'], package['version'])]
        if digest(cached) != checksum:
            raise ValueError(f'Cargo.lock source checksum mismatch: {name}')
        shutil.copyfile(cached, crates / cached.name)
        texts = [p for p in source.iterdir() if p.is_file()
                 and p.name.lower().startswith(('license', 'licence', 'notice', 'copying'))]
        if package['license_file']:
            texts.append(source / package['license_file'])
        copied = []
        for text in sorted(set(texts)):
            folder = licenses / name
            folder.mkdir(exist_ok=True)
            shutil.copyfile(text, folder / text.name)
            copied.append(text.name)
        inventory.append(dict(name=package['name'], version=package['version'],
                              license=package['license'], licenseFiles=copied,
                              source=package['source'], repository=package['repository'], sha256=checksum))
    (output / 'share/whisky/dependencies.json').write_text(json.dumps(inventory, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--frontend', required=True, type=Path)
    parser.add_argument('--products', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--archive', required=True, type=Path)
    args = parser.parse_args()
    if platform.system() != 'Linux':
        parser.error('Run packaging in the Linux build environment')
    for tool in ('ldd', 'patchelf', 'cargo', 'swift', 'git'):
        if not shutil.which(tool):
            parser.error(f'Required build tool: {tool}')
    output = args.output.absolute()
    archive_path = args.archive.absolute()
    if output.exists() or output.is_symlink() or archive_path.exists() or archive_path.is_symlink():
        parser.error('Choose new bundle and archive paths; existing artifacts are preserved')
    if archive_path.is_relative_to(output):
        parser.error('Place the archive outside the bundle directory')
    sources = {name: (args.frontend if name == 'whisky-gpui' else args.products / name).resolve(strict=True)
               for name in PRODUCTS}
    database_resources = (args.products / 'WhiskyCore_WhiskyCore.resources').resolve(strict=True)
    if not (database_resources / 'GameDB.json').is_file():
        parser.error('The shared GameDB resource bundle is required')
    machines = {elf_machine(path) for path in sources.values()}
    if len(machines) != 1 or any(not os.access(path, os.X_OK) for path in sources.values()):
        parser.error('Products must be executable ELF files for one architecture')
    architecture = 'aarch64' if machines == {183} else 'x86_64'
    target = f'{architecture}-unknown-linux-gnu'
    swift = json.loads(command('swift', '-print-target-info'))
    if swift['target']['triple'] != target:
        parser.error('Swift runtime and products must share the target architecture')
    runtime_roots = [Path(p).resolve(strict=True) for p in swift['paths']['runtimeLibraryPaths']]
    runtime = {}
    system = set()
    for source in sources.values():
        for name, location in dependencies(source).items():
            if any(location.resolve().is_relative_to(root) for root in runtime_roots):
                if name in runtime and digest(location) != digest(runtime[name]):
                    raise ValueError(f'Conflicting runtime libraries: {name}')
                runtime[name] = location
            else:
                system.add(name)
    if 'libswiftCore.so' not in runtime:
        parser.error('The bridge must resolve a Swift runtime before packaging')
    # Resolve every input before creating a new artifact directory.
    swift_license = Path(shutil.which('swift')).resolve().parents[1] / 'share/swift/LICENSE.txt'
    if not swift_license.is_file():
        parser.error(f'Swift toolchain license is required: {swift_license}')
    icu_header = runtime_roots[0].parent / '_foundation_unicode/uvernum.h'
    header = icu_header.read_text()
    icu_version = '.'.join(re.search(r'#define U_ICU_VERSION_' + key + r'_NUM\s+(\d+)', header)[1]
                           for key in ('MAJOR', 'MINOR'))
    icu_license = ROOT / f'apps/whisky-gpui/licenses/icu-{icu_version}-LICENSE.txt'
    if not icu_license.is_file():
        parser.error(f'Preserve the license for Foundation ICU {icu_version} before packaging')
    output.mkdir(parents=True)
    (output / 'bin').mkdir()
    (output / 'lib/swift').mkdir(parents=True)
    for name, source in sources.items():
        binary = output / 'bin' / name
        shutil.copyfile(source, binary)
        binary.chmod(0o755)
        subprocess.run(['patchelf', '--set-rpath', '$ORIGIN/../lib/swift', str(binary)], check=True)
    shutil.copytree(database_resources, output / 'bin/WhiskyCore_WhiskyCore.resources')
    shutil.copytree(args.products / 'WhiskyBridge_WhiskyApplication.resources',
                    output / 'bin/WhiskyBridge_WhiskyApplication.resources')
    for name, source in runtime.items():
        library = output / 'lib/swift' / name
        shutil.copyfile(source, library)
        library.chmod(0o644)
        subprocess.run(['patchelf', '--set-rpath', '$ORIGIN', str(library)], check=True)
    launcher = output / 'Whisky'
    launcher.write_text('#!/bin/sh\nset -eu\nbundle=$(dirname -- "$(readlink -f -- "$0")")\nexec "$bundle/bin/whisky-gpui" "$@"\n')
    launcher.chmod(0o755)
    notices = output / 'share/licenses/whisky'
    notices.mkdir(parents=True)
    shutil.copyfile(ROOT / 'LICENSE', notices / 'LICENSE')
    shutil.copyfile(swift_license, notices / 'Swift-LICENSE.txt')
    shutil.copyfile(icu_license, notices / 'Foundation-ICU-LICENSE.txt')
    shutil.copyfile(TOOLS / 'linux-runtime-packages.txt', output / 'share/whisky-runtime-packages.txt')
    copy_sources(output, target)
    (output / 'README.txt').write_text(
        'Whisky Linux file and host services\n\n'
        'Target: Ubuntu 24.04 or compatible systems, ' + architecture + '.\n'
        'Install the packages in share/whisky-runtime-packages.txt using your system package manager.\n'
        'Launch ./Whisky or bin/whisky-gpui. The entire directory can be moved together.\n'
        'Settings can install or refresh the desktop entry at its current location.\n'
        'Swift libraries are bundled; GTK, graphics drivers, fonts and host tools use system packages.\n'
        'Application sources and locked Rust source archives are in share/whisky/sources.\n'
        'Dependency declarations and supplied license texts are in share/whisky/dependencies.json and share/licenses.\n'
        'Copied ELF programs and Swift libraries have modified RUNPATH values using $ORIGIN-relative directories.\n'
        'Original binary/runtime hashes and modified file hashes are recorded in manifest.json.\n'
        'Settings can download and update the separately published Linux Wine runtime.\n'
        'Wine execution requires an x86_64 runtime and compatible host libraries and kernel.\n')
    executables = {output / 'Whisky'} | {output / 'bin' / name for name in PRODUCTS}
    output.chmod(0o755)
    for path in output.rglob('*'):
        path.chmod(0o755 if path.is_dir() or path in executables else 0o644)
    files = {str(p.relative_to(output)): dict(sha256=digest(p), bytes=p.stat().st_size,
             mode=stat.S_IMODE(p.stat().st_mode)) for p in sorted(output.rglob('*')) if p.is_file()}
    manifest = dict(formatVersion=1, architecture=architecture, platform='linux', distribution='ubuntu-24.04',
                    sourceCommit=command('git', '-C', ROOT, 'rev-parse', 'HEAD'),
                    sourceTreeDirty=bool(command('git', '-C', ROOT, 'status', '--porcelain')),
                    sourceSnapshotSha256=digest(output / 'share/whisky/sources/application.tar.gz'),
                    swiftCompiler=swift['compilerVersion'], rustCompiler=command('rustc', '--version'),
                    swiftLibraries=sorted(runtime), systemLibraries=sorted(system), foundationICUVersion=icu_version,
                    swiftRuntimeInputs={name: digest(path) for name, path in runtime.items()},
                    inputs={name: digest(path) for name, path in sources.items()}, files=files)
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (output / 'manifest.json').chmod(0o644)
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.whisky-package-', dir=archive_path.parent) as temporary:
        staged = Path(temporary) / 'bundle.tar.gz'
        with tarfile.open(staged, 'w:gz') as archive:
            archive.add(output, arcname='Whisky')
        staged.chmod(0o644)
        os.link(staged, archive_path)
    print(json.dumps(dict(bundle=str(output), archive=str(archive_path), sha256=digest(archive_path),
                          architecture=architecture, swiftLibraries=len(runtime), files=len(files)), indent=2))


if __name__ == '__main__':
    main()
