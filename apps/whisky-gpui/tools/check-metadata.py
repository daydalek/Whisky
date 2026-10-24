#!/usr/bin/env python3
"""Verify portable metadata and artwork through the production NDJSON helper."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import runpy
import select
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--live', action='store_true', help='Also search the public Bangumi API')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    generator = runpy.run_path(str(Path(__file__).with_name('check-programs.py')))['fixture_at']
    bottle, executable, registry, _ = generator(root)
    original = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in bottle.rglob('*') if path.is_file()}
    env = dict(os.environ, WHISKY_REGISTRY=str(registry), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_STATE_HOME=str(root / 'state'), XDG_DATA_HOME=str(root / 'data'))
    report = {'steps': [], 'passed': False}
    log = (output / 'helper.log').open('w')
    process = subprocess.Popen([str(args.helper.resolve())], env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=log, text=True)
    sequence = 0

    def call(method, params=None, expect_error=False):
        nonlocal sequence
        sequence += 1
        request = dict(version=1, id=str(sequence), method=method, params=params or {})
        process.stdin.write(json.dumps(request) + '\n')
        process.stdin.flush()
        assert select.select([process.stdout], [], [], 25)[0], f'Timed out: {method}'
        response = json.loads(process.stdout.readline())
        assert response['id'] == str(sequence), response
        assert bool(response.get('error')) == expect_error, response
        return response.get('result')

    def job_result(started):
        deadline = time.monotonic() + 70
        while time.monotonic() < deadline:
            job = call('jobs.get', dict(jobID=started['jobID']))
            assert job['status'] not in ('failed', 'cancelled'), job
            if job['status'] == 'completed':
                return job['result']
            time.sleep(0.1)
        raise AssertionError('Metadata job timed out')

    try:
        description = call('bridge.describe')
        assert all(method in description['methods'] for method in (
            'metadata.search', 'metadata.sync', 'metadata.apply', 'metadata.clear',
            'metadata.cover.import', 'metadata.cover.reset')), description
        entries = call('library.entries', dict(container=str(bottle)))
        entry = next(item for item in entries if item['name'] == 'Portable Game')
        params = dict(container=str(bottle), entryID=entry['id'])
        metadata = dict(source='bangumi', sourceID='42', title='Linux Metadata Fixture',
                        originalTitle='Original', summary='Portable snapshot', developer='Fixture',
                        releaseDate='2026-01-01', fetchedAt=1000)
        call('metadata.apply', dict(params, metadata=metadata))
        refreshed = call('library.entries', dict(container=str(bottle)))
        assert refreshed[0]['metadata']['title'] == metadata['title'], refreshed
        report['steps'].append('advertised-methods-and-real-metadata-attachment')
        cover = root / 'cover.png'
        pixels = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP43+HyHxkzoAsAAHyRFlERVA2OAAAAAElFTkSuQmCC')
        cover.write_bytes(pixels)
        imported = call('metadata.cover.import', dict(params, path=str(cover)))
        assert Path(imported['cover']).read_bytes() == pixels, imported
        refreshed = call('library.entries', dict(container=str(bottle)))
        assert refreshed[0]['cover'] == imported['cover'] and refreshed[0]['coverAspectRatio'] == 2, refreshed
        cover.write_text('invalid image')
        call('metadata.cover.import', dict(params, path=str(cover)), expect_error=True)
        assert Path(imported['cover']).read_bytes() == pixels
        report['steps'].append('native-pixel-decode-import-and-invalid-image-preservation')
        call('metadata.clear', params)
        refreshed = call('library.entries', dict(container=str(bottle)))
        assert refreshed[0].get('metadata') is None and refreshed[0]['cover'] == imported['cover'], refreshed
        call('metadata.cover.reset', params)
        refreshed = call('library.entries', dict(container=str(bottle)))
        assert refreshed[0].get('cover') is None, refreshed
        report['steps'].append('metadata-detach-retains-custom-artwork-and-cover-reset')
        call('preferences.set', dict(key='offlineMode', value=True))
        search = job_result(call('metadata.search', dict(params, query='CLANNAD', sources=['bangumi'])))
        assert search['results'][0]['games'] == [] and search['results'][0]['error'], search
        report['steps'].append('production-offline-policy-returns-source-error')
        if args.live:
            call('preferences.set', dict(key='offlineMode', value=False))
            search = job_result(call('metadata.search', dict(params, query='CLANNAD', sources=['bangumi'])))
            assert search['results'][0]['games'], search
            game = search['results'][0]['games'][0]
            report['live'] = {'source': game['source'], 'sourceID': game['sourceID'], 'title': game['title'],
                              'thumbnailCached': bool(game.get('thumbnail'))}
            report['steps'].append('live-bangumi-search')
        for path, digest in original.items():
            assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest, path
        report['steps'].append('original-prefix-and-program-settings-preserved')
        call('bridge.shutdown')
        assert process.wait(timeout=10) == 0
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        log.close()
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
