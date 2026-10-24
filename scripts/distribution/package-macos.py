#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Package a verified macOS GPUI Whisky.app into release ZIP, source archive and checksums."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(65536):
            h.update(chunk)
    return h.hexdigest()


def verify_app(app: Path, version: str) -> None:
    if not app.is_dir():
        raise FileNotFoundError(f"App bundle not found: {app}")

    info_path = app / 'Contents/Info.plist'
    if not info_path.is_file():
        raise FileNotFoundError(f"Info.plist not found in {app}")

    info = plistlib.loads(info_path.read_bytes())
    app_version = info.get('CFBundleShortVersionString')
    if app_version != version:
        raise ValueError(f"Version mismatch in Info.plist: expected {version}, got {app_version}")

    executable = app / 'Contents/MacOS/whisky-gpui'
    if not executable.is_file():
        raise FileNotFoundError(f"Main executable not found: {executable}")

    archs = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).strip()
    if 'arm64' not in archs:
        raise ValueError(f"Expected arm64 architecture, got: {archs}")

    required_resources = (
        'whisky-bridge',
        'cabextract',
        'winetricks',
        'verbs.txt',
        'AppIcon.icns',
        'WhiskyKit_WhiskyKit.bundle',
        'WhiskyCore_WhiskyCore.bundle',
    )
    for res in required_resources:
        res_path = app / 'Contents/Resources' / res
        if not res_path.exists():
            raise FileNotFoundError(f"Missing required resource in app bundle: {res}")

    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def package(app: Path, version: str, output: Path, build_number: int = 1) -> None:
    verify_app(app, version)
    output.mkdir(parents=True, exist_ok=True)

    archive_name = f"Whisky-{version}-arm64.zip"
    archive_path = output / archive_name
    if archive_path.exists():
        archive_path.unlink()

    print(f"Creating release archive: {archive_path}")
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive_path)], check=True)

    with tempfile.TemporaryDirectory(prefix="whisky-zip-check-") as tmpdir:
        subprocess.run(['ditto', '-x', '-k', str(archive_path), tmpdir], check=True)
        extracted_app = Path(tmpdir) / 'Whisky.app'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(extracted_app)], check=True)

    sources_name = f"Whisky-{version}-sources.tar.gz"
    sources_path = output / sources_name
    print(f"Archiving release sources: {sources_path}")
    subprocess.run([
        'git', '-C', str(ROOT), 'archive',
        f'--prefix=Whisky-{version}/',
        '--format=tar.gz',
        '-o', str(sources_path),
        'HEAD',
    ], check=True)

    commit = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    checkout_dirty = bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain'], text=True).strip())

    build_info = {
        'app_version': version,
        'build_number': build_number,
        'architecture': 'arm64',
        'ui': 'gpui',
        'commit': commit,
        'checkout_dirty': checkout_dirty,
        'signing': 'ad-hoc',
        'notarized': False,
        'runtime': 'downloaded separately from the Wine runtime channel',
    }
    (output / 'build-info.json').write_text(json.dumps(build_info, indent=2) + '\n')

    release_notes = f"""Whisky {version} for Apple Silicon (GPUI).

Download {archive_name}, extract Whisky.app and drag it into Applications.
The app downloads CrossOver-based GE Wine Libraries separately on first setup.
The current Wine runtime requires macOS 27+ and Rosetta 2.
Source code is included in {sources_name}.
Third-party licenses, source attribution, and cabextract source are included in
Whisky.app/Contents/Resources/ThirdParty/ and THIRD-PARTY-NOTICES.md.

This build uses an ad-hoc signature. Apple notarization is pending; macOS Gatekeeper may require additional approval on first launch.
"""
    (output / 'RELEASE-NOTES.md').write_text(release_notes)

    items_to_hash = [archive_name, sources_name, 'build-info.json', 'RELEASE-NOTES.md']
    lines = []
    for item in items_to_hash:
        item_path = output / item
        lines.append(f"{digest(item_path)}  {item}\n")
    (output / 'SHA256SUMS').write_text(''.join(lines))
    print(f"Release assets ready in {output}:")
    for item in items_to_hash + ['SHA256SUMS']:
        print(f"  - {item}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='Path to Whisky.app')
    parser.add_argument('--version', type=str, required=True, help='Release version X.Y.Z')
    parser.add_argument('--output', type=Path, required=True, help='Output directory for release assets')
    parser.add_argument('--build-number', type=int, default=1, help='Build number')
    args = parser.parse_args()
    package(args.app.resolve(), args.version, args.output.resolve(), args.build_number)


if __name__ == '__main__':
    main()
