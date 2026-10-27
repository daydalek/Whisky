#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise public build planning, literal paths, failure evidence and shared work locks."""
import contextlib
import csv
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name('build.py')
spec = importlib.util.spec_from_file_location('distribution_build', SCRIPT)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='whisky-build-test-')
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.repo = self.root / 'Wine repo 包 $HOME ;'
        for path in ('scripts/linux/build.py', 'scripts/linux/install-deps.sh',
                     'scripts/ci/build-release.sh', 'configs/crossover-source-lock.json'):
            file = self.repo / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('fixture\n')

    def args(self, *args):
        return build.parser().parse_args(['plan', *args, '--wine-repo', str(self.repo),
                                         '--output', str(self.root / 'output 包 $HOME ;')])

    def test_plans_have_no_side_effects_and_invalid_flags_fail(self):
        args = self.args('wine-linux-amd64', '--compile-only')
        value = build.plan(args)
        self.assertFalse(Path(value['output']).exists())
        self.assertIn('compile-only', value['steps'][2]['command'])
        self.assertFalse(any('verify.py' in str(s['command']) for s in value['steps']))
        with self.assertRaises(ValueError):
            build.plan(self.args('whisky-linux-amd64', '--compile-only'))
        with self.assertRaises(ValueError):
            build.plan(self.args('whisky-macos-gpui-arm64', '--version', '1.2;touch /tmp/x'))

    def test_runtime_validation_follows_packaging_and_recipe_cache_changes(self):
        before = build.plan(self.args('wine-linux-amd64'))
        commands = [s['command'] for s in before['steps']]
        self.assertIn('runtime', commands[3])
        self.assertIn('--runtime', commands[-1])
        self.assertTrue(commands[-1][-1].endswith('artifacts/wine-linux-amd64'))
        (self.repo / 'configs/crossover-source-lock.json').write_text('new recipe')
        after = build.plan(self.args('wine-linux-amd64'))
        self.assertNotEqual(before['workDirectory'], after['workDirectory'])

    def test_docker_mounts_are_literal_and_context_is_minimal(self):
        args = self.args('wine-linux-amd64', '--executor', 'docker', '--compile-only')
        value = build.plan(args)
        command = value['steps'][1]['command']
        self.assertIn(f'type=bind,src={self.repo},dst=/wine,readonly', command)
        self.assertIn('linux/amd64', command)
        self.assertIn('/output/task', command)
        self.assertEqual(2, len(value['contextFiles']))
        self.assertEqual(str(Path(value['output']) / 'docker-context'), value['steps'][0]['command'][-1])
        self.assertEqual('compile-only', value['acceptance'])
        self.assertFalse(Path(value['output']).exists())

    def test_docker_mount_csv_preserves_commas_and_quotes(self):
        source = self.root / 'source, "quoted" 包 $HOME'
        fields = next(csv.reader([build.mount(source, '/wine', readonly=True)]))
        self.assertEqual(['type=bind', 'src=' + str(source), 'dst=/wine', 'readonly'], fields)

    def test_linux_formats_share_one_payload_and_forward_version_to_docker(self):
        value = build.plan(self.args('whisky-linux-amd64', '--version', '0.2.0'))
        command = value['steps'][-1]['command']
        self.assertIn('package-linux.py', Path(command[1]).name)
        self.assertEqual(['deb', 'rpm', 'appimage'], command[command.index('--formats') + 1:])
        raw = build.plan(self.args('whisky-linux-amd64', '--formats', 'tar'))
        self.assertEqual(2, len(raw['steps']))
        docker = build.plan(self.args('whisky-linux-amd64', '--version', '0.2.0', '--formats', 'deb', '--executor', 'docker'))
        command = docker['steps'][-1]['command']
        self.assertIn('0.2.0', command)
        self.assertEqual(['deb'], command[command.index('--formats') + 1:])

    def test_macos_gpui_plan_adds_package_step_when_version_provided(self):
        self.assertEqual([name for name in build.TARGETS if name.startswith("whisky-macos-")],
                         ["whisky-macos-gpui-arm64"])
        dev = build.plan(self.args('whisky-macos-gpui-arm64'))
        self.assertEqual(1, len(dev['steps']))
        self.assertIn('package-app.sh', dev['steps'][0]['command'][1])
        self.assertNotIn('WHISKY_VERSION', dev['environment'])
        install = build.plan(self.args('whisky-macos-gpui-arm64', '--install'))
        self.assertEqual('install-macos.py', Path(install['steps'][-1]['command'][1]).name)
        with self.assertRaises(ValueError):
            build.plan(self.args('whisky-linux-amd64', '--install'))

        release = build.plan(self.args('whisky-macos-gpui-arm64', '--version', '0.4.0', '--build-number', '7'))
        self.assertEqual(2, len(release['steps']))
        self.assertEqual('0.4.0', release['environment']['WHISKY_VERSION'])
        self.assertEqual('7', release['environment']['BUILD_NUMBER'])
        self.assertIn('package-macos.py', release['steps'][1]['command'][1])
        self.assertIn('--version', release['steps'][1]['command'])
        self.assertIn('0.4.0', release['steps'][1]['command'])
        with self.assertRaises(ValueError):
            build.plan(self.args('whisky-macos-gpui-arm64', '--version', 'invalid_version'))

    def job(self, commands, **extra):
        value = dict(target='whisky-linux-amd64', executor='native', output=str(self.root / 'output'),
                     environment={}, steps=[dict(name='fixture', cwd=str(self.root), command=c) for c in commands])
        value.update(extra)
        return value

    def run_job(self, value):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            build.execute(value)

    def test_literal_paths_and_arguments_survive_real_process_execution(self):
        destination = self.root / 'result 包 $HOME ; $(touch BAD)'
        literal = '文字 " ; $HOME $(touch BAD)'
        job = self.job([[sys.executable, '-c',
            'from pathlib import Path; import sys; Path(sys.argv[1]).write_text(sys.argv[2])',
            str(destination), literal]])
        self.run_job(job)
        self.assertEqual(literal, destination.read_text())
        self.assertFalse((self.root / 'BAD').exists())
        report = json.loads((Path(job['output']) / 'build-report.json').read_text())
        self.assertEqual('passed', report['status'])
        self.assertEqual(0, report['results'][0]['exitCode'])

    def test_failure_preserves_evidence_and_stops_later_steps(self):
        marker = self.root / 'should-stay-absent'
        job = self.job([[sys.executable, '-c', 'print("build failure evidence"); raise SystemExit(7)'],
                        [sys.executable, '-c', f'from pathlib import Path; Path({str(marker)!r}).touch()']])
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_job(job)
        self.assertFalse(marker.exists())
        report = json.loads((Path(job['output']) / 'build-report.json').read_text())
        self.assertEqual('failed', report['status'])
        self.assertEqual(7, report['results'][0]['exitCode'])
        self.assertIn('build failure evidence', (Path(job['output']) / '01.log').read_text())
        with self.assertRaises(FileExistsError):
            self.run_job(job)
        self.assertIn('build failure evidence', (Path(job['output']) / '01.log').read_text())

    def test_wine_work_lock_blocks_concurrent_build_before_launch(self):
        work = self.root / 'cache/work'
        work.parent.mkdir()
        with (work.parent / 'work.build.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            job = self.job([[sys.executable, '-c', 'raise SystemExit(99)']],
                           target='wine-linux-amd64', workDirectory=str(work))
            with self.assertRaisesRegex(ValueError, '正在构建'):
                self.run_job(job)
        report = json.loads((Path(job['output']) / 'build-report.json').read_text())
        self.assertEqual('failed', report['status'])
        self.assertEqual([], report['results'])

    def test_cancellation_terminates_child_and_keeps_report(self):
        marker = self.root / 'child.pid'
        job = self.job([[sys.executable, '-c',
            'import os,time; from pathlib import Path; '
            f'Path({str(marker)!r}).write_text(str(os.getpid())); time.sleep(60)']])
        bootstrap = ('import importlib.util,json,sys; '
            's=importlib.util.spec_from_file_location("builder",sys.argv[1]); '
            'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
            'm.execute(json.loads(sys.argv[2]))')
        process = subprocess.Popen([sys.executable, '-c', bootstrap, str(SCRIPT), json.dumps(job)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        deadline = time.monotonic() + 10
        while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(marker.exists())
        child = int(marker.read_text())
        process.send_signal(signal.SIGINT)
        process.wait(timeout=15)
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)
        report = json.loads((Path(job['output']) / 'build-report.json').read_text())
        self.assertEqual('cancelled', report['status'])


if __name__ == '__main__':
    unittest.main()
