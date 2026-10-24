#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import importlib.util
import json
import os
import platform
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('formats', Path(__file__).with_name('package-linux.py'))
formats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(formats)


@unittest.skipUnless(sys.version_info >= (3, 12), 'Linux packager uses Python 3.12')
class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='whisky-format-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / 'Whisky'
        (self.bundle / 'bin').mkdir(parents=True)
        header = bytearray(20)
        header[:6] = b'\x7fELF\x02\x01'
        self.arch = 'aarch64' if platform.machine() in ('aarch64', 'arm64') else 'x86_64'
        struct.pack_into('<H', header, 18, formats.ARCHITECTURES[self.arch][2])
        for name in formats.PRODUCTS:
            path = self.bundle / 'bin' / name
            path.write_bytes(header)
            path.chmod(0o755)
        (self.bundle / 'Whisky').write_text('#!/bin/sh\nexit 0\n')
        (self.bundle / 'Whisky').chmod(0o755)
        files = {str(p.relative_to(self.bundle)): dict(sha256=hashlib.sha256(p.read_bytes()).hexdigest(),
                 bytes=p.stat().st_size, mode=p.stat().st_mode & 0o777) for p in self.bundle.rglob('*') if p.is_file()}
        self.manifest = dict(formatVersion=1, platform='linux', architecture=self.arch,
                             sourceCommit='fixture', systemLibraries=['libc.so.6'], files=files)
        (self.bundle / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_inventory_rejects_tampering_and_added_payload(self):
        self.assertEqual(self.arch, formats.verify(self.bundle)['architecture'])
        extra = self.bundle / 'extra'
        extra.touch()
        with self.assertRaisesRegex(ValueError, 'inventory'):
            formats.verify(self.bundle)
        extra.unlink()
        (self.bundle / 'bin/whisky-gpui').write_bytes(b'altered')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            formats.verify(self.bundle)

    def test_archive_rejects_traversal_and_symlinks(self):
        for kind in ('traversal', 'symlink'):
            archive = self.root / (kind + '.tar.gz')
            with tarfile.open(archive, 'w:gz') as stream:
                entry = tarfile.TarInfo('Whisky/../../outside' if kind == 'traversal' else 'Whisky/link')
                if kind == 'symlink':
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = '/etc/passwd'
                stream.addfile(entry)
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                formats.unpack(archive, self.root / kind)
        self.assertFalse((self.root / 'outside').exists())

    def test_tool_download_verifies_digest_and_repairs_corrupt_cache(self):
        source = self.root / 'tool'
        source.write_bytes(b'locked tool')
        item = dict(url=source.as_uri(), sha256=hashlib.sha256(source.read_bytes()).hexdigest())
        cache = self.root / 'cache'
        first = formats.download(item, cache)
        first.write_bytes(b'corrupt cache')
        self.assertEqual(b'locked tool', formats.download(item, cache).read_bytes())
        source.write_bytes(b'changed upstream')
        first.unlink()
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            formats.download(item, cache)

    @unittest.skipUnless(all(shutil.which(tool) for tool in ('dpkg-deb', 'rpmbuild', 'rpm', 'patchelf',
                                                             'dpkg-architecture', 'dpkg-query',
                                                             'desktop-file-validate',
                                                             'gio-querymodules', 'glib-compile-schemas'))
                         and list(Path('/usr/lib').glob('*/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders')),
                         'Requires Ubuntu native packaging tools and image loaders')
    def test_real_deb_and_rpm_preserve_payload_with_permissive_umask(self):
        (self.bundle / 'lib/swift').mkdir(parents=True)
        for name in formats.PRODUCTS:
            shutil.copyfile('/bin/true', self.bundle / 'bin' / name)
        self.manifest['files'] = {str(p.relative_to(self.bundle)): dict(sha256=formats.digest(p),
            bytes=p.stat().st_size, mode=p.stat().st_mode & 0o777)
            for p in self.bundle.rglob('*') if p.is_file() and p.name != 'manifest.json'}
        (self.bundle / 'manifest.json').write_text(json.dumps(self.manifest))
        output = self.root / 'packages'
        output.mkdir()
        workspace = self.root / 'work'
        workspace.mkdir()
        old = os.umask(0)
        try:
            deb = formats.deb(self.bundle, self.manifest, '0.1.0', output, workspace)
            rpm = formats.rpm(self.bundle, self.manifest, '0.1.0', output, workspace)
        finally:
            os.umask(old)
        self.assertEqual(formats.ARCHITECTURES[self.arch][0], formats.run('dpkg-deb', '-f', deb, 'Architecture').strip())
        extracted = self.root / 'deb-extracted'
        subprocess.run(['dpkg-deb', '-x', deb, extracted], check=True)
        formats.verify(extracted / 'opt/whisky')
        self.assertEqual(formats.ARCHITECTURES[self.arch][1], formats.run('rpm', '-qp', '--qf', '%{ARCH}', rpm).strip())
        entries = formats.run('rpm', '-qpl', rpm)
        self.assertIn('/usr/bin/whisky', entries)
        self.assertIn('/usr/share/applications/com.franke.Whisky.desktop', entries)


if __name__ == '__main__':
    unittest.main()
