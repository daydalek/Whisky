#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record ELF imports and reject glibc requirements above a release's ABI baseline."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


def version(value):
    return tuple(int(part) for part in value.split('.'))


def audit(root, maximum, readelf):
    root = root.resolve(strict=True)
    records = []
    for path in sorted(root.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        dynamic = subprocess.check_output([readelf, '-W', '-d', str(path)], text=True)
        symbols = subprocess.check_output([readelf, '-W', '--dyn-syms', str(path)], text=True)
        imported = '\n'.join(line for line in symbols.splitlines() if re.search(r'\bUND\b', line))
        glibc = sorted(set(re.findall(r'@GLIBC_(\d+(?:\.\d+)+)', imported)), key=version)
        glibcxx = sorted(set(re.findall(r'@GLIBCXX_(\d+(?:\.\d+)+)', imported)), key=version)
        records.append(dict(path=str(path.relative_to(root)),
            needed=sorted(set(re.findall(r'\(NEEDED\).*?\[(.*?)\]', dynamic))),
            runpath=re.findall(r'\((?:RUNPATH|RPATH)\).*?\[(.*?)\]', dynamic),
            glibc=glibc, glibcxx=glibcxx, privateGlibc='@GLIBC_PRIVATE' in imported))
    required = max((x for r in records for x in r['glibc']), key=version, default=None)
    failed = [r['path'] for r in records if r['privateGlibc'] or
              any(version(x) > version(maximum) for x in r['glibc'])]
    return dict(formatVersion=1, passed=bool(records) and not failed, glibcBaseline=maximum,
                requiredGlibc=required, elfFiles=len(records), failures=failed, files=records,
                scope='ELF symbol and direct SONAME requirements; target-distro library and GPU acceptance is separate')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--glibc-max', default='2.39')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'\d+(?:\.\d+)+', args.glibc_max):
        parser.error('--glibc-max must be a dotted numeric version')
    readelf = shutil.which('readelf') or shutil.which('llvm-readelf')
    if not readelf:
        parser.error('Install binutils (readelf) in the Linux build environment')
    report = audit(args.root, args.glibc_max, readelf)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'files'}, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
