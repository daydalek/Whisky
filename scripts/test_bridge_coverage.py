"""Regression tests for SwiftPM native and aggregate coverage exports."""

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from bridge_coverage import export_bridge_coverage


class BridgeCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='whisky-coverage-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.products = self.root / 'products'
        self.products.mkdir()
        self.output = self.root / 'bridge.lcov'
        self.env = {'COVERAGE_TEST': 'isolated'}

    def bundle(self, name):
        binary = self.products / f'{name}.xctest/Contents/MacOS' / name
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'test-object')
        return binary

    def profile(self):
        profile = self.products / 'codecov/default.profdata'
        profile.parent.mkdir()
        profile.write_bytes(b'test-profile')
        return profile

    def successful_export(self, command, *, env, stdout, check):
        self.assertEqual(env, self.env)
        self.assertTrue(check)
        stdout.write('SF:/repo/WhiskyBridge/Sources/WhiskyApplication/Service.swift\n'
                     'DA:1,1\nLF:1\nLH:1\nend_of_record\n')

    def test_native_bundles_include_portable_and_native_test_objects(self):
        portable = self.bundle('WhiskyBridgeTests')
        native = self.bundle('WhiskyNativeBridgeTests')
        profile = self.profile()
        with patch('bridge_coverage.subprocess.run', side_effect=self.successful_export) as run:
            report = export_bridge_coverage(self.products, self.output, self.env)
        self.assertEqual(run.call_args.args[0], [
            'xcrun', 'llvm-cov', 'export', str(portable),
            '--object=' + str(native), '--instr-profile=' + str(profile), '--format=lcov',
        ])
        self.assertEqual(report['coverageInputs']['binaries'], [str(portable), str(native)])
        self.assertEqual(report['coverage'], str(self.output))
        self.assertTrue(self.output.read_text().startswith('SF:'))

    def test_aggregate_package_bundle_needs_no_additional_object(self):
        binary = self.bundle('WhiskyBridgePackageTests')
        self.profile()
        with patch('bridge_coverage.subprocess.run', side_effect=self.successful_export) as run:
            export_bridge_coverage(self.products, self.output, self.env)
        command = run.call_args.args[0]
        self.assertEqual(command[3], str(binary))
        self.assertFalse(any(arg.startswith('--object=') for arg in command))

    def test_missing_inputs_fail_before_export(self):
        with patch('bridge_coverage.subprocess.run') as run:
            with self.assertRaises(RuntimeError):
                export_bridge_coverage(self.products, self.output, self.env)
            bundle = self.products / 'Broken.xctest'
            bundle.mkdir()
            with self.assertRaises(RuntimeError):
                export_bridge_coverage(self.products, self.output, self.env)
            run.assert_not_called()

    def test_missing_profile_fails_before_export(self):
        self.bundle('WhiskyBridgeTests')
        with patch('bridge_coverage.subprocess.run') as run:
            with self.assertRaises(RuntimeError):
                export_bridge_coverage(self.products, self.output, self.env)
            run.assert_not_called()

    def test_failed_export_preserves_previous_report_and_cleans_its_temporary(self):
        self.bundle('WhiskyBridgeTests')
        self.profile()
        self.output.write_text('previous successful report')
        with patch('bridge_coverage.subprocess.run',
                   side_effect=subprocess.CalledProcessError(1, ['xcrun'])):
            with self.assertRaises(subprocess.CalledProcessError):
                export_bridge_coverage(self.products, self.output, self.env)
        self.assertEqual(self.output.read_text(), 'previous successful report')
        self.assertEqual(list(self.root.glob('.bridge-coverage-*')), [])

    def test_empty_export_is_rejected(self):
        self.bundle('WhiskyBridgeTests')
        self.profile()
        with patch('bridge_coverage.subprocess.run'):
            with self.assertRaises(RuntimeError):
                export_bridge_coverage(self.products, self.output, self.env)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob('.bridge-coverage-*')), [])


if __name__ == '__main__':
    unittest.main()
