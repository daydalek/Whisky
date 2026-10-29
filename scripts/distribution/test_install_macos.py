# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise deployment replacement and rollback using disposable app fixtures."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('install_macos', Path(__file__).with_name('install-macos.py'))
install_macos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(install_macos)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'source.app'
        self.target = self.root / 'Whisky.app'
        for app, content in ((self.source, b'new'), (self.target, b'old')):
            for rel in ('Contents/MacOS/whisky-gpui', 'Contents/Resources/whisky-bridge'):
                path = app / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)

    def ditto(self, command, **_kwargs):
        shutil.copytree(command[1], command[2])

    def test_replaces_only_after_staged_verification(self):
        with mock.patch.object(install_macos, 'verify'), mock.patch.object(install_macos.subprocess, 'run', self.ditto):
            install_macos.install(self.source, self.target)
        self.assertEqual((self.target / 'Contents/MacOS/whisky-gpui').read_bytes(), b'new')
        self.assertEqual(list(self.root.glob('.whisky-install-*')), [])
        self.assertTrue(self.source.exists())

    def test_removes_source_only_after_successful_install(self):
        with mock.patch.object(install_macos, 'verify'), mock.patch.object(install_macos.subprocess, 'run', self.ditto):
            install_macos.install(self.source, self.target, remove_source=True)
        self.assertFalse(self.source.exists())
        self.assertEqual((self.target / 'Contents/MacOS/whisky-gpui').read_bytes(), b'new')

    def test_failed_install_verification_restores_previous_app(self):
        def verify(path):
            if path == self.target and (path / 'Contents/MacOS/whisky-gpui').read_bytes() == b'new':
                raise ValueError('failed verification')
        with mock.patch.object(install_macos, 'verify', verify), mock.patch.object(install_macos.subprocess, 'run', self.ditto):
            with self.assertRaises(ValueError):
                install_macos.install(self.source, self.target, remove_source=True)
        self.assertEqual((self.target / 'Contents/MacOS/whisky-gpui').read_bytes(), b'old')
        self.assertTrue(self.source.exists())

    def test_rejects_removing_install_destination(self):
        with self.assertRaises(ValueError):
            install_macos.install(self.target, self.target, remove_source=True)
        self.assertTrue(self.target.exists())

    def test_rejects_symlink_target(self):
        shutil.rmtree(self.target)
        self.target.symlink_to(self.source)
        with self.assertRaises(ValueError):
            install_macos.install(self.source, self.target)
        self.assertTrue(self.target.is_symlink())


if __name__ == '__main__':
    unittest.main()
