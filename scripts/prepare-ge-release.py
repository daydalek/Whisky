#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare and audit a privacy-clean copy of an assembled GE Wine runtime."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile

PRIVATE_PREFIX = re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/|/(?:private/)?var/folders/[A-Za-z0-9_/.-]+/')
CREDENTIAL = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bAKIA[A-Z0-9]{16}\b|\b(?:ghp_|github_pat_)[A-Za-z0-9_]{30,}\b|\bsk-(?:proj-)?[A-Za-z0-9_-]{30,}\b')
MACHO = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def public_prefix(match):
    # Fixed-size substitution preserves offsets in compiled diagnostic strings.
    count = len(match.group())
    return b'/build/' + b'_' * (count - 8) + b'/'


def safe_header(member):
    member.uid = member.gid = 0
    member.uname = member.gname = ''
    member.mtime = 0
    member.pax_headers = {}
    return member


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True, help='Assembled Libraries directory')
    parser.add_argument('--output', type=Path, required=True, help='Fresh release directory')
    parser.add_argument('--objcopy', type=Path, required=True, help='LLVM objcopy executable')
    parser.add_argument('--private-name', required=True, help='Local account name to detect; stays in local audit only')
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists():
        parser.error('output already exists')
    out.mkdir(parents=True)
    root = out / 'Libraries'
    shutil.copytree(args.input, root, symlinks=True)
    # Headers, import archives and pkg-config files are development-only payloads.
    for directory in (root / 'Wine/include', root / 'Wine/lib/pkgconfig'):
        if directory.exists():
            shutil.rmtree(directory)
    for file in root.rglob('*.a'):
        file.unlink()
    stripped = rewritten = checked = 0
    forbidden = {'system.reg', 'user.reg', 'userdef.reg', 'BottleVM.plist', 'Metadata.plist', '.DS_Store', '.git'}
    for file in sorted(root.rglob('*')):
        if file.name == '.DS_Store':
            file.unlink()
            continue
        if file.name in forbidden:
            raise RuntimeError(f'Unexpected private-state file: {file.relative_to(root)}')
        if file.is_symlink():
            target = file.resolve()
            if root not in target.parents or not target.exists():
                raise RuntimeError(f'Nonportable symlink: {file.relative_to(root)}')
            continue
        if not file.is_file():
            continue
        data = file.read_bytes()
        macho = data[:4] in MACHO
        pe = data[:2] == b'MZ' and file.suffix.lower() in {'.dll', '.exe', '.sys', '.cpl', '.drv', '.ocx', '.acm'}
        if pe:
            marker = data[64:80]
            subprocess.run([str(args.objcopy), '--strip-debug', str(file)], check=True, capture_output=True)
            data = file.read_bytes()
            if marker == b'Wine builtin DLL' and data[64:80] != marker:
                raise RuntimeError(f'Builtin marker changed: {file.relative_to(root)}')
            stripped += 1
        elif macho:
            subprocess.run(['/usr/bin/strip', '-S', str(file)], check=True, capture_output=True)
            data = file.read_bytes()
            stripped += 1
        cleaned = PRIVATE_PREFIX.sub(public_prefix, data)
        # PE diagnostic strings can also carry UTF-16LE source paths.
        if b'/\x00U\x00s\x00e\x00r\x00s\x00/' in cleaned or b'/\x00h\x00o\x00m\x00e\x00/' in cleaned:
            wide = re.compile(rb'(?:[^\x00]\x00){1,2048}')
            cleaned = wide.sub(lambda m: PRIVATE_PREFIX.sub(public_prefix, m.group()[::2])
                               .decode('latin1').encode('utf-16le'), cleaned)
        if cleaned != data:
            file.write_bytes(cleaned)
            rewritten += 1
        if macho:
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(file)], check=True, capture_output=True)
            subprocess.run(['/usr/bin/codesign', '--verify', str(file)], check=True, capture_output=True)
        # Audit the final bytes, including newly produced signatures.
        data = file.read_bytes()
        flattened = data.replace(b'\x00', b'')
        for view in (data, flattened):
            if PRIVATE_PREFIX.search(view) or args.private_name.encode() in view:
                raise RuntimeError(f'Private identifier remains: {file.relative_to(root)}')
            if CREDENTIAL.search(view):
                raise RuntimeError(f'Credential pattern requires review: {file.relative_to(root)}')
        checked += 1
    print(f'Audited {checked} files; stripped {stripped}; remapped {rewritten}', flush=True)
    archive = out / 'Libraries.tar.gz'
    with tarfile.open(archive, 'w:gz', compresslevel=6) as tf:
        tf.add(root, arcname='Libraries', filter=safe_header)
    hasher = hashlib.sha256()
    with archive.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            hasher.update(block)
    info = plistlib.loads((root / 'WhiskyWineVersion.plist').read_bytes())
    info['sha256'] = hasher.hexdigest()
    metadata = out / 'WhiskyWineVersion.plist'
    metadata.write_bytes(plistlib.dumps(info))
    for view in (metadata.read_bytes(), metadata.read_bytes().replace(b'\x00', b'')):
        assert not PRIVATE_PREFIX.search(view) and not CREDENTIAL.search(view)
    with tarfile.open(archive) as tf:
        headers = list(tf)
        assert all(m.uid == m.gid == 0 and m.uname == m.gname == '' and not m.pax_headers for m in headers)
        assert all(m.name == 'Libraries' or m.name.startswith('Libraries/') for m in headers)
    report = {'result': 'passed', 'files_checked': checked, 'debug_stripped': stripped,
              'files_with_build_path_remapping': rewritten, 'archive_entries': len(headers),
              'archive_owner_fields': 'anonymous', 'private_paths': 0, 'local_account_names': 0,
              'credential_pattern_findings': 0, 'user_prefix_or_bottle_state': 0,
              'sha256': info['sha256'],
              'scope': 'Entire payload and tar headers; ASCII/UTF-16 private paths, local account name and common credential patterns'}
    (out / 'privacy-audit.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2), flush=True)


if __name__ == '__main__':
    main()
