#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import struct
import sys
import tarfile
import types
import tempfile
import unittest
import zipfile

TOOLS = Path(__file__).resolve().parents[2] / 'apps/whisky-gpui/tools'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


builder = load('upscaler_builder', TOOLS / 'build-linux-upscaler.py')
sys.modules.setdefault('tomllib', types.ModuleType('tomllib'))
if not hasattr(hashlib, 'file_digest'):
    hashlib.file_digest = lambda stream, algorithm: hashlib.new(algorithm, stream.read())
packager = load('upscaler_packager', TOOLS / 'package-linux.py')
distro = load('distribution_packager', Path(__file__).with_name('package-linux.py'))


class UpscalerBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='whisky-upscaler-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_source_extractors_reject_traversal_and_links(self):
        tar_path = self.root / 'unsafe.tar.gz'
        with tarfile.open(tar_path, 'w:gz') as archive:
            member = tarfile.TarInfo('../outside')
            member.size = 1
            archive.addfile(member, __import__('io').BytesIO(b'x'))
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            builder.extract_tar(tar_path, self.root / 'tar')

        zip_path = self.root / 'unsafe.zip'
        with zipfile.ZipFile(zip_path, 'w') as archive:
            info = zipfile.ZipInfo('link')
            info.external_attr = (0o120777 << 16)
            archive.writestr(info, '/etc/passwd')
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            builder.extract_zip(zip_path, self.root / 'zip')
        self.assertFalse((self.root / 'outside').exists())

    def test_corrupt_cached_source_is_rejected(self):
        sources = self.root / 'sources'
        sources.mkdir()
        (sources / 'realcugan.tar.gz').write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'Corrupt cached source archive'):
            builder.source_archive(builder.LOCK['realcugan'], self.root)

    def test_payload_inventory_checks_architecture_hashes_and_refresh(self):
        arch = 'aarch64' if platform.machine() in ('aarch64', 'arm64') else 'x86_64'
        helper_rel = 'bin/realcugan-ncnn-vulkan'
        model_dir = 'share/realcugan-ncnn-vulkan/models-se'
        files = {}
        payload = self.root / 'payload'
        helper = payload / helper_rel
        helper.parent.mkdir(parents=True)
        header = bytearray(64)
        header[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', header, 18, 183 if arch == 'aarch64' else 62)
        helper.write_bytes(header)
        helper.chmod(0o755)
        for name, content in [('up2x-no-denoise.param', b'param'), ('up2x-no-denoise.bin', b'model')]:
            path = payload / model_dir / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            relative = f'{model_dir}/{name}'
            files[relative] = dict(sha256=hashlib.sha256(content).hexdigest(), size=len(content))
        files[helper_rel] = dict(sha256=hashlib.sha256(header).hexdigest(), size=len(header))
        manifest = dict(schemaVersion=1, architecture=arch, modelFamily='models-se', files=files)
        manifest_path = payload / 'share/whisky/upscalers/manifest.json'
        manifest_path.parent.mkdir(parents=True)
        manifest_path.write_text(json.dumps(manifest))
        packager.verify_upscaler(payload, arch)
        helper.write_bytes(bytes(header) + b'patched')
        distro.refresh_upscaler_manifest(payload)
        distro.verify_upscaler(payload, arch)
        packager.refresh_upscaler_manifest(payload)
        packager.verify_upscaler(payload, arch)
        (payload / model_dir / 'up2x-no-denoise.bin').write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            packager.verify_upscaler(payload, arch)


if __name__ == '__main__':
    unittest.main()
