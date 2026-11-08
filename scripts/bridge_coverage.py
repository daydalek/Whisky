"""Export coverage from the SwiftPM test products actually built on macOS."""

from pathlib import Path
import os
import subprocess
import tempfile


def export_bridge_coverage(products: Path, output: Path, env: dict) -> dict:
    binaries = []
    for bundle in sorted(products.glob('*.xctest')):
        binary = bundle / 'Contents/MacOS' / bundle.stem
        if not binary.is_file():
            raise RuntimeError(f'Missing Swift test executable: {binary}')
        binaries.append(binary)
    profdata = products / 'codecov/default.profdata'
    if not binaries or not profdata.is_file():
        raise RuntimeError(f'Missing Swift test bundles or profile data in {products}')

    # Native SwiftPM emits one bundle per test target, while other backends
    # emit an aggregate PackageTests bundle. Include every built test object.
    command = ['xcrun', 'llvm-cov', 'export', str(binaries[0])]
    command += ['--object=' + str(binary) for binary in binaries[1:]]
    command += ['--instr-profile=' + str(profdata), '--format=lcov']
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=output.parent,
                                         prefix='.bridge-coverage-', delete=False) as stream:
            temporary = Path(stream.name)
            subprocess.run(command, env=env, stdout=stream, check=True)
        with temporary.open() as stream:
            has_bridge_sources = any(
                line.startswith('SF:') and '/WhiskyBridge/Sources/' in line
                for line in stream
            )
        if not has_bridge_sources:
            raise RuntimeError('Swift coverage contains no WhiskyBridge source records')
        os.replace(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return {
        'coverage': str(output),
        'coverageInputs': {
            'binaries': [str(binary) for binary in binaries],
            'profdata': str(profdata),
        },
    }
