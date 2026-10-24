"""Exercise the production GameDB reference sheet and preserve its source prefix."""
import hashlib
import json
from pathlib import Path
import subprocess
import time


def exercise(window, app, fixture, bottle, registry, snapshot, report, env):
    def click(x, y, button=1):
        subprocess.run(['xdotool', 'mousemove', '--window', window, str(x), str(y), 'click', str(button)], check=True)
    def state():
        return {str(p.relative_to(bottle)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in bottle.rglob('*') if p.is_file()}
    before, original_registry = state(), registry.read_bytes()
    click(300, 150, 3)
    time.sleep(0.4)
    click(375, 260)
    deadline = time.monotonic() + 15
    matched = None
    while time.monotonic() < deadline:
        assert app.poll() is None
        log = fixture / 'responses.jsonl'
        for line in log.read_text().splitlines(keepends=True) if log.exists() else []:
            if not line.endswith('\n'):
                continue
            value = json.loads(line).get('result', {})
            if isinstance(value, dict) and value.get('matches'):
                matched = value['matches'][0]
        if matched:
            break
        time.sleep(0.1)
    assert matched and matched['entry']['id'] == 'aoe2-de', matched
    assert matched['referencePlatform'] == 'macos' and matched['canApply'] is False, matched
    time.sleep(0.6)
    snapshot('gamedb-reference-sheet')
    click(916, 627)  # Read-only reference action for the canonical first match.
    time.sleep(0.4)
    requests = [json.loads(line) for line in (fixture / 'requests.jsonl').read_text().splitlines()]
    assert all(item['method'] != 'gameConfig.apply' for item in requests), requests
    report['steps'].append('read-only-reference-action-preserves-application-capability-boundary')
    subprocess.run(['xdotool', 'mousemove', '--window', window, '850', '650', 'click', '--repeat', '12', '--delay', '20', '5'], check=True)
    time.sleep(0.6)
    snapshot('gamedb-reference-details')
    assert state() == before and registry.read_bytes() == original_registry
    report['steps'].append('canonical-game-identity-and-macos-reference-reach-the-production-sheet-with-source-files-intact')
    click(974, 89)
    time.sleep(0.3)
    resources = Path(env['WHISKY_GAMEDB_RESOURCE'])
    retained = resources.with_name('Retained-GameDB-resources')
    resources.rename(retained)
    try:
        click(300, 150, 3)
        time.sleep(0.3)
        click(375, 260)
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            lines = (fixture / 'responses.jsonl').read_text().splitlines(keepends=True)
            if any(json.loads(line).get('error', {}).get('code') == 'database_unavailable'
                   for line in lines if line.endswith('\n')):
                break
            time.sleep(0.1)
        else:
            raise AssertionError('Missing resource did not produce a recoverable GameDB error')
        time.sleep(0.5)
        snapshot('gamedb-resource-error')
    finally:
        retained.rename(resources)
    click(921, 607)
    time.sleep(1)
    snapshot('gamedb-resource-retried')
    requests = [json.loads(line) for line in (fixture / 'requests.jsonl').read_text().splitlines()]
    assert sum(item['method'] == 'gameConfig.match' for item in requests) >= 3, requests
    replies = [json.loads(line) for line in (fixture / 'responses.jsonl').read_text().splitlines()]
    successful = [item['result']['matches'] for item in replies
                  if isinstance(item.get('result'), dict) and item['result'].get('matches')]
    assert len(successful) >= 2 and successful[-1][0]['entry']['id'] == 'aoe2-de', successful
    assert state() == before and registry.read_bytes() == original_registry
    report['steps'].append('missing-database-shows-completed-error-and-restored-resource-retries-through-ui')
    click(974, 89)
    time.sleep(0.3)
