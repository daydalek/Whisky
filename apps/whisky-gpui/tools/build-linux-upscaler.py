#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build and atomically publish Whisky's pinned Linux Real-CUGAN payload."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import subprocess
import tempfile
import time
import urllib.request
import zipfile
import tarfile

ROOT = Path(__file__).resolve().parents[3]
TOOLS = Path(__file__).resolve().parent
LOCK = json.loads((TOOLS / 'upscaler-sources.json').read_text())
MODEL_NOTICE = ROOT / 'ThirdParty'
INFERENCE = dict(schemaVersion=2, noise=0, scale=2, format='png', tileSize=128,
                 jobs='1:1:1', syncgap=2)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def safe_member(name):
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or '..' in path.parts or '\\' in name:
        raise ValueError('Unsafe source archive path: ' + name)
    return path


def extract_tar(archive, destination):
    with tarfile.open(archive, 'r:gz') as source:
        members = source.getmembers()
        if len(members) > 250_000 or sum(member.size for member in members) > 2_000_000_000:
            raise ValueError('Real-CUGAN source archive exceeds extraction limits')
        for member in members:
            safe_member(member.name)
            if not (member.isdir() or member.isfile()):
                raise ValueError('Unsafe source archive member: ' + member.name)
        for member in members:
            target = destination.joinpath(*safe_member(member.name).parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                source_file = source.extractfile(member)
                if source_file is None:
                    raise ValueError('Unreadable source member: ' + member.name)
                with source_file, target.open('xb') as output:
                    shutil.copyfileobj(source_file, output)


def extract_zip(archive, destination):
    with zipfile.ZipFile(archive) as source:
        members = source.infolist()
        if len(members) > 250_000 or sum(member.file_size for member in members) > 2_000_000_000:
            raise ValueError('ncnn source archive exceeds extraction limits')
        for member in members:
            safe_member(member.filename)
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode) or (not member.is_dir() and mode and not stat.S_ISREG(mode)):
                raise ValueError('Unsafe source archive member: ' + member.filename)
        for member in members:
            target = destination.joinpath(*safe_member(member.filename).parts)
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.open(member) as source_file, target.open('xb') as output:
                    shutil.copyfileobj(source_file, output)


def source_archive(item, cache):
    sources = cache / 'sources'
    sources.mkdir(parents=True, exist_ok=True)
    extension = '.tar.gz' if item is LOCK['realcugan'] else '.zip'
    target = sources / (item['version'] + extension)
    if target.exists():
        if digest(target) != item['sha256']:
            raise ValueError('Corrupt cached source archive: ' + str(target))
        return target
    supplied = sources / ('realcugan.tar.gz' if item is LOCK['realcugan'] else 'ncnn.zip')
    if supplied.exists():
        if digest(supplied) != item['sha256']:
            raise ValueError('Corrupt cached source archive: ' + str(supplied))
        shutil.copyfile(supplied, target)
        return target
    for attempt in range(3):
        if attempt:
            time.sleep(10 * attempt)
        with tempfile.NamedTemporaryFile(dir=sources, delete=False) as output:
            temporary = Path(output.name)
            try:
                request = urllib.request.Request(item['url'], headers={'User-Agent': 'Whisky-source-build/1'})
                with urllib.request.urlopen(request, timeout=120) as response:
                    shutil.copyfileobj(response, output)
                output.flush()
                if digest(temporary) != item['sha256']:
                    raise ValueError('Source checksum mismatch: ' + item['url'])
                temporary.replace(target)
                return target
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                if attempt == 2:
                    raise
            finally:
                temporary.unlink(missing_ok=True)
    return target


def copy_licenses(source_root, ncnn_root, output):
    output.mkdir(parents=True)
    shutil.copyfile(source_root / 'LICENSE', output / 'realcugan-LICENSE')
    shutil.copyfile(ncnn_root / 'LICENSE.txt', output / 'ncnn-LICENSE.txt')
    shutil.copyfile(ncnn_root / 'glslang/LICENSE.txt', output / 'glslang-LICENSE.txt')
    for header in ('stb_image.h', 'stb_image_write.h'):
        shutil.copyfile(source_root / 'src' / header, output / ('STB-' + header))
    shutil.copyfile(MODEL_NOTICE / 'licenses/RealCUGAN-bilibili-MIT.txt',
                    output / 'models-bilibili-MIT.txt')
    shutil.copyfile(MODEL_NOTICE / 'licenses/RealCUGAN-ncnn-MIT.txt',
                    output / 'models-realcugan-ncnn-MIT.txt')


def build(args):
    arch = platform.machine().lower()
    if arch not in ('x86_64', 'aarch64'):
        raise ValueError('Unsupported Linux architecture: ' + arch)
    for tool in ('cmake', 'ninja', 'cc', 'c++', 'pkg-config'):
        if not shutil.which(tool):
            raise ValueError('Required build tool is missing: ' + tool)
    args.cache.mkdir(parents=True, exist_ok=True)
    output = args.output.absolute()
    output.parent.mkdir(parents=True, exist_ok=True)
    real_archive = source_archive(LOCK['realcugan'], args.cache)
    ncnn_archive = source_archive(LOCK['ncnn'], args.cache)

    with tempfile.TemporaryDirectory(prefix='whisky-upscaler-build-', dir=args.cache) as work_name:
        work = Path(work_name)
        extracted = work / 'sources'
        extracted.mkdir()
        extract_tar(real_archive, extracted)
        source_root = extracted / LOCK['realcugan']['root']
        ncnn_root = source_root / 'src/ncnn'
        ncnn_root.mkdir(parents=True, exist_ok=True)
        extract_zip(ncnn_archive, ncnn_root)
        model_source = source_root / 'models/models-se'
        for name, metadata in LOCK['models']['files'].items():
            path = model_source / name
            if digest(path) != metadata['sha256']:
                raise ValueError('Pinned model checksum mismatch: ' + name)

        build_dir = work / 'build'
        cmake_args = [
            'cmake', '-S', source_root / 'src', '-B', build_dir, '-G', 'Ninja',
            '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_C_FLAGS=-O3',
            '-DCMAKE_CXX_FLAGS=-O3', '-DUSE_SYSTEM_WEBP=ON', '-DNCNN_VULKAN=ON',
            '-DNCNN_VULKAN_ONLINE_SPIRV=ON', '-DNCNN_SHARED_LIB=OFF',
            '-DNCNN_BUILD_TESTS=OFF', '-DNCNN_BUILD_TOOLS=OFF',
            '-DNCNN_BUILD_EXAMPLES=OFF', '-DNCNN_BUILD_BENCHMARK=OFF',
            '-DNCNN_AVX512=OFF', '-DNCNN_SYSTEM_GLSLANG=OFF',
            '-DWITH_LAYER_gemm=ON',
        ]
        subprocess.run(cmake_args, check=True)
        subprocess.run(['cmake', '--build', build_dir, '--parallel', str(args.jobs),
                        '--target', 'realcugan-ncnn-vulkan'], check=True)
        candidates = list(build_dir.rglob('realcugan-ncnn-vulkan'))
        if len(candidates) != 1 or not candidates[0].is_file():
            raise ValueError('Expected one realcugan-ncnn-vulkan build output')

        with tempfile.TemporaryDirectory(prefix='.upscaler-publish-', dir=output.parent) as stage_name:
            stage = Path(stage_name) / 'payload'
            helper = stage / 'bin/realcugan-ncnn-vulkan'
            helper.parent.mkdir(parents=True)
            shutil.copyfile(candidates[0], helper)
            helper.chmod(0o755)
            models = stage / 'share/realcugan-ncnn-vulkan/models-se'
            models.mkdir(parents=True)
            for name in LOCK['models']['files']:
                shutil.copyfile(model_source / name, models / name)
            licenses = stage / 'share/licenses/whisky/upscalers'
            copy_licenses(source_root, ncnn_root, licenses)
            source_copy = stage / 'share/whisky/sources/upscalers'
            source_copy.mkdir(parents=True)
            shutil.copyfile(real_archive, source_copy / 'realcugan-ncnn-vulkan-20220728.tar.gz')
            shutil.copyfile(ncnn_archive, source_copy / 'ncnn-20240410-full-source.zip')
            files = {
                'bin/realcugan-ncnn-vulkan': dict(sha256=digest(helper), size=helper.stat().st_size)
            }
            for name in LOCK['models']['files']:
                path = models / name
                files[f'share/realcugan-ncnn-vulkan/models-se/{name}'] = dict(
                    sha256=digest(path), size=path.stat().st_size)
            recipe = ['CMAKE_BUILD_TYPE=Release', 'USE_SYSTEM_WEBP=ON', 'NCNN_VULKAN=ON',
                      'NCNN_BUILD_TESTS/TOOLS/EXAMPLES=OFF', 'NCNN_AVX512=OFF',
                      'WITH_LAYER_gemm=ON']
            manifest = dict(
                schemaVersion=1, helperVersion=LOCK['realcugan']['version'],
                ncnnVersion=LOCK['ncnn']['version'], architecture=arch,
                modelFamily='models-se', inference=INFERENCE, files=files,
                sources={
                    'realcugan': dict(url=LOCK['realcugan']['url'], sha256=LOCK['realcugan']['sha256']),
                    'ncnn': dict(url=LOCK['ncnn']['url'], sha256=LOCK['ncnn']['sha256']),
                },
                systemDependencies=['libwebp-dev at build time', 'libwebp at runtime', 'libvulkan'],
                recipe=recipe,
                licenseFiles=sorted(path.name for path in licenses.iterdir()),
            )
            manifest_path = stage / 'share/whisky/upscalers/manifest.json'
            manifest_path.parent.mkdir(parents=True)
            manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
            if output.exists():
                backup = output.with_name(output.name + '.previous')
                if backup.exists():
                    raise ValueError('Refusing to replace output while a previous backup exists')
                output.rename(backup)
                try:
                    stage.rename(output)
                except BaseException:
                    backup.rename(output)
                    raise
                shutil.rmtree(backup)
            else:
                stage.rename(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--jobs', type=int, required=True)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    try:
        build(args)
    except (OSError, ValueError, subprocess.SubprocessError, zipfile.BadZipFile,
            tarfile.TarError) as error:
        parser.exit(1, f'build-linux-upscaler.py: {error}\n')


if __name__ == '__main__':
    main()
