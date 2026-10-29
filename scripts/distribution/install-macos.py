#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Install a signed GPUI build, preserving the previous app until verification."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.digest()


def verify(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.franke.Whisky' or info.get('CFBundleExecutable') != 'whisky-gpui':
        raise ValueError('应用标识或可执行文件与 Whisky GPUI 不符')
    for path in ('Contents/MacOS/whisky-gpui', 'Contents/Resources/whisky-bridge',
                 'Contents/Resources/winetricks', 'Contents/Resources/verbs.txt',
                 'Contents/Resources/cabextract'):
        if not (app / path).is_file():
            raise ValueError('应用缺少资源：' + path)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def install(source, destination, remove_source=False):
    source, destination = Path(source), Path(destination)
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise ValueError('目标必须是普通应用目录')
    if remove_source:
        source_path, destination_path = source.resolve(), destination.resolve()
        if (source.is_symlink() or source_path == destination_path
                or source_path in destination_path.parents or destination_path in source_path.parents):
            raise ValueError('构建副本与安装目标必须是独立的普通应用目录')
    verify(source)
    scratch = Path(tempfile.mkdtemp(prefix='.whisky-install-', dir=destination.parent))
    staged, previous = scratch / 'new.app', scratch / 'previous.app'
    try:
        subprocess.run(['ditto', str(source), str(staged)], check=True)
        verify(staged)
        for path in ('Contents/MacOS/whisky-gpui', 'Contents/Resources/whisky-bridge'):
            if digest(source / path) != digest(staged / path):
                raise ValueError('部署副本校验失败：' + path)
        had_previous = destination.exists()
        if had_previous:
            os.replace(destination, previous)
        try:
            os.replace(staged, destination)
            verify(destination)
        except BaseException:
            if destination.exists():
                shutil.rmtree(destination)
            if had_previous:
                os.replace(previous, destination)
            raise
        if had_previous:
            shutil.rmtree(previous)
    finally:
        # Keep the old app recoverable if a rollback or removal fails.
        if not previous.exists():
            shutil.rmtree(scratch)
        else:
            print('保留原应用：' + str(previous), flush=True)
    print('已安装：' + str(destination), flush=True)
    if remove_source:
        shutil.rmtree(source)
        print('已清理构建副本：' + str(source), flush=True)
    print('已运行的 Whisky 需重新启动后使用新版本。', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remove-source', action='store_true', help='部署并校验成功后删除构建副本')
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    install(args.app, Path('/Applications/Whisky.app'), remove_source=args.remove_source)


if __name__ == '__main__':
    main()
