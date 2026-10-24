#!/usr/bin/env python3
"""Copy a built macOS Swift bridge and its resources into a GPUI app's Resources directory."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--products', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
products = args.products.resolve()
output = args.output.resolve()
inputs = [(products / 'whisky-bridge', 'whisky-bridge'),
          (products / 'WhiskyKit_WhiskyKit.bundle', 'WhiskyKit_WhiskyKit.bundle'),
          (products / 'WhiskyCore_WhiskyCore.bundle', 'WhiskyCore_WhiskyCore.bundle')]
inputs += [(root / 'Libraries' / name, name) for name in ('cabextract', 'winetricks', 'verbs.txt')]
inputs.append((root / 'Whisky' / 'Resources' / 'WhiskyAudioTest.exe', 'WhiskyAudioTest.exe'))
for source, _ in inputs:
    if not source.exists():
        raise SystemExit(f'Missing build resource: {source}')
if output.exists() and any(output.iterdir()):
    raise SystemExit(f'Use a new empty output directory: {output}')
output.mkdir(parents=True, exist_ok=True)
for source, name in inputs:
    target = output / name
    if source.is_dir():
        shutil.copytree(source, target)
    else:
        shutil.copy2(source, target)
# Development signing. Release signing and notarization belong to the final app packager.
subprocess.run(['codesign', '--force', '--sign', '-', str(output / 'whisky-bridge')], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(output / 'whisky-bridge')], check=True)
files = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in sorted(output.rglob('*')) if p.is_file()}
(output / 'bridge-manifest.json').write_text(json.dumps({
    'protocolVersion': 1, 'dataIdentity': 'com.franke.Whisky', 'files': files,
}, ensure_ascii=False, indent=2) + '\n')
print(output)
