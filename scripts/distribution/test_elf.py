#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('elf_audit', Path(__file__).with_name('audit-elf.py'))
elf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elf)


@unittest.skipUnless(shutil.which('readelf') and shutil.which('cc'), 'Requires Linux ELF tools')
class ElfAuditTests(unittest.TestCase):
    def test_real_binary_imports_and_baseline_rejection(self):
        with tempfile.TemporaryDirectory(prefix='whisky-abi-') as folder:
            root = Path(folder)
            source = root / 'fixture.c'
            source.write_text('#include <unistd.h>\nint main(void) { return getpid() == 0; }\n')
            subprocess.run(['cc', str(source), '-Wl,-rpath,$ORIGIN/../lib', '-o', str(root / 'fixture')], check=True)
            report = elf.audit(root, '99.0', shutil.which('readelf'))
            self.assertTrue(report['passed'])
            self.assertEqual(1, report['elfFiles'])
            self.assertIn('libc.so.6', report['files'][0]['needed'])
            self.assertEqual(['$ORIGIN/../lib'], report['files'][0]['runpath'])
            self.assertIsNotNone(report['requiredGlibc'])
            self.assertFalse(elf.audit(root, '0.0', shutil.which('readelf'))['passed'])

    def test_empty_payload_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertFalse(elf.audit(Path(folder), '2.39', shutil.which('readelf'))['passed'])


if __name__ == '__main__':
    unittest.main()
