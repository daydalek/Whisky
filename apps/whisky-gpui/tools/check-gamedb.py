#!/usr/bin/env python3
"""Verify GameDB reference matching, resource relocation and file preservation using real helpers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    helper = args.helper.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    generate = runpy.run_path(str(Path(__file__).with_name('gamedb-fixture.py')))['fixture_at']
    bottle, executable, registry = generate(root)
    bridge_type = runpy.run_path(str(Path(__file__).with_name('check-diagnostics.py')))['Bridge']
    env = dict(os.environ, WHISKY_REGISTRY=str(registry), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_DATA_HOME=str(root / 'data'), XDG_STATE_HOME=str(root / 'state'), WHISKY_BRIDGE_NO_WINE='1')
    params = dict(container=str(bottle), entryID='pinned:' + str(executable))
    snapshot = lambda: {str(p.relative_to(bottle)): hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in bottle.rglob('*') if p.is_file()}
    before, registry_bytes = snapshot(), registry.read_bytes()
    report = dict(passed=False, steps=[], fixture=str(root))
    with (output / 'helper.log').open('w') as log:
        def use(binary, operation):
            bridge = bridge_type(binary, env, log)
            try:
                return operation(bridge)
            finally:
                bridge.close()

        def match(bridge):
            reply = bridge.call('gameConfig.match', params)
            assert 'error' not in reply, reply
            value = reply['result']['matches'][0]
            assert value['entry']['id'] == 'aoe2-de' and value['confidence'] >= 0.85, value
            assert value['referencePlatform'] == 'macos' and value['canApply'] is False, value
            assert 'macOS 14.0.0+' in value['availabilityReason'] and value['changes'], value
            return value

        try:
            def initial(bridge):
                describe = bridge.call('bridge.describe', {})['result']
                assert 'gameConfig.match' in describe['methods'] and 'gameConfig.read' in describe['capabilities']
                assert 'gameConfig.apply' not in describe['methods'] and 'runtime.launch' not in describe['methods']
                value = match(bridge)
                failure = bridge.call('gameConfig.apply', dict(params, gameID='aoe2-de', variantID=value['variantID']))
                assert failure['error']['code'] == 'method_unavailable', failure
            use(helper, initial)
            use(helper, match)
            assert snapshot() == before and registry.read_bytes() == registry_bytes
            report['steps'].append('canonical-offline-reference-and-rejected-application-preserve-all-files-across-restart')
            relocated = root / 'Relocated helper 包 %f'
            relocated.mkdir()
            copied = relocated / helper.name
            shutil.copy2(helper, copied)
            def missing_then_present(bridge):
                failure = bridge.call('gameConfig.match', params)
                assert failure['error']['code'] == 'database_unavailable', failure
                assert bridge.call('system.info', {}).get('result'), 'Missing resource terminated the helper'
                resources = relocated / 'WhiskyCore_WhiskyCore.resources'
                shutil.copytree(helper.parent / resources.name, resources)
                path = resources / 'GameDB.json'
                original = path.read_bytes()
                match(bridge)
                path.write_text('{"version":3,"entries":[]}')
                failure = bridge.call('gameConfig.match', params)
                assert failure['error']['code'] == 'database_unavailable', failure
                path.write_bytes(original)
                match(bridge)
            use(copied, missing_then_present)
            assert snapshot() == before and registry.read_bytes() == registry_bytes
            report['steps'].append('relocated-resource-missing-corrupt-and-restored-requests-keep-helper-usable')
            report['passed'] = True
        finally:
            (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
