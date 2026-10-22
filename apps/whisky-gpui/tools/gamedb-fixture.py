"""Isolated executable identity for the canonical GameDB reference flow."""
from pathlib import Path
import plistlib
import runpy


def fixture_at(root):
    generate = runpy.run_path(str(Path(__file__).with_name('check-programs.py')))['fixture_at']
    bottle, previous, registry, unused = generate(root)
    executable = previous.with_name('AoE2DE_s.exe')
    previous.rename(executable)
    marker = bottle / 'Metadata.plist'
    metadata = plistlib.loads(marker.read_bytes())
    metadata['info']['pins'][0].update(name='AoE2 Reference', url={'relative': executable.as_uri()})
    marker.write_bytes(plistlib.dumps(metadata))
    return bottle, executable, registry
