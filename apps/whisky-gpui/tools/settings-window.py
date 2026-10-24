"""Exercise optional settings services across real helper reconnects."""
import json
import os
import plistlib
import signal
import subprocess
import time


def exercise(window, app, fixture, snapshot, report):
    def click(x, y):
        subprocess.run(['xdotool', 'mousemove', '--window', window, str(x), str(y), 'click', '1'], check=True)

    def requests():
        return [json.loads(line) for line in (fixture / 'requests.jsonl').read_text().splitlines()]

    def wait_for(predicate, message):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            assert app.poll() is None, 'Application exited during settings reconnect'
            if predicate():
                return
            time.sleep(0.1)
        snapshot('settings-check-failed')
        raise AssertionError(message)

    def preferences():
        path = fixture / 'config/whisky/preferences.plist'
        return plistlib.loads(path.read_bytes()) if path.exists() else {}

    excluded = ['system.terminals', 'system.desktop.status', 'system.desktop.install']
    subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+comma'], check=True)
    time.sleep(1)
    snapshot('settings-restricted')
    click(1215, 145)  # Runtime-only exit policy.
    click(1215, 490)  # Runtime-only post-exit refresh policy.
    click(1200, 210)  # Terminal refresh.
    click(1200, 295)  # Desktop integration.
    time.sleep(0.7)
    assert not {'killOnTerminate', 'libraryRefreshAfterExit'} & preferences().keys(), preferences()
    assert all(item['method'] not in excluded for item in requests()), requests()
    assert 'setup.status' not in {item['method'] for item in requests()}
    # A supported library preference remains writable in the same session.
    click(1215, 553)
    wait_for(lambda: preferences().get('libraryMixedCoverLayout') is False,
             'Supported library toggle did not persist')
    snapshot('settings-supported-preference')

    def reconnect(methods, count):
        previous = int((fixture / 'child.pid').read_text())
        (fixture / 'excluded.json').write_text(json.dumps(methods))
        os.kill(previous, signal.SIGTERM)
        subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+r'], check=True)
        wait_for(lambda: int((fixture / 'child.pid').read_text()) != previous
                 and sum(item['method'] == 'preferences.read' for item in requests()) >= count,
                 'Helper did not reconnect and reload the active settings session')
        time.sleep(1)

    reconnect([], 2)
    wait_for(lambda: {'system.terminals', 'system.desktop.status'}.issubset(
        {item['method'] for item in requests()}), 'Restored host services were not discovered')
    snapshot('settings-services-restored')
    click(1200, 295)
    entry = fixture / 'data/applications/com.franke.Whisky.desktop'
    wait_for(entry.exists, 'Restored desktop installation did not publish the entry')
    assert 'system.desktop.install' in {item['method'] for item in requests()}
    snapshot('settings-restored-desktop-installed')

    reconnect(excluded, 3)
    offset = len(requests())
    snapshot('settings-services-restricted-again')
    click(1200, 210)
    click(1200, 295)
    click(1215, 145)
    time.sleep(0.7)
    assert all(item['method'] not in excluded for item in requests()[offset:]), requests()[offset:]
    values = preferences()
    assert values['libraryMixedCoverLayout'] is False and 'killOnTerminate' not in values, values
    assert all(not item['method'].startswith(('setup.', 'runtime.')) for item in requests())
    subprocess.run(['xdotool', 'mousemove', '--window', window, '1000', '700', 'click', '--repeat', '15', '--delay', '20', '5'], check=True)
    time.sleep(0.5)
    snapshot('settings-runtime-and-network')
    click(1215, 747)  # Runtime-only update preference.
    click(1215, 684)  # Supported offline preference.
    wait_for(lambda: preferences().get('offlineMode') is True, 'Supported offline preference did not persist')
    assert 'checkWhiskyWineUpdates' not in preferences(), preferences()
    report['steps'].append('optional-settings-disable-restore-and-disable-across-real-helper-reconnects')
    report['steps'].append('supported-library-preference-persists-while-runtime-policy-stays-intact')
    report['recordedMethods'] = sorted({item['method'] for item in requests()})
    subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+comma'], check=True)
    time.sleep(0.3)
