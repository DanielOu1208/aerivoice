"""Packaging failure boundaries; synthetic bundles, no mounts or signing keys."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('dmg', Path(__file__).parents[1] / 'build-dmg.py')
dmg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dmg)


class DMGTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.app = self.root / 'AeriVoice.app'
        executable = self.app / 'Contents/MacOS/AeriVoice'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'synthetic executable')
        executable.chmod(0o755)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'AeriVoice'}))
        self.output = self.root / 'preview.dmg'

    def run_builder(self, builder):
        core = SimpleNamespace(build_dmg=builder, DMGError=RuntimeError)
        with patch.dict(sys.modules, {'dmgbuild.core': core}), \
             patch.object(dmg, 'check_tools'), patch.object(dmg, 'has_bundle_signature', return_value=False), \
             patch.object(dmg.subprocess, 'run'):
            dmg.build(self.app, 'AeriVoice', self.output)

    def test_existing_output_and_dangling_symlink_are_never_replaced(self):
        self.output.write_bytes(b'existing signed candidate')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            dmg.build(self.app, 'AeriVoice', self.output)
        self.assertEqual(self.output.read_bytes(), b'existing signed candidate')
        self.output.unlink()
        self.output.symlink_to(self.root / 'missing.dmg')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            dmg.build(self.app, 'AeriVoice', self.output)
        self.assertTrue(self.output.is_symlink())

    def test_partial_app_copy_is_rejected_without_publishing_output(self):
        copied = self.root / 'mounted/AeriVoice.app'
        shutil.copytree(self.app, copied)
        (copied / 'Contents/MacOS/AeriVoice').write_bytes(b'truncated')

        def incomplete_copy(filename, volume, *, callback, **kwargs):
            Path(filename).write_bytes(b'incomplete image')
            callback({'type': 'operation::finished', 'operation': 'file::add', 'file': str(copied)})

        with self.assertRaisesRegex(ValueError, 'Packaged app differs'):
            self.run_builder(incomplete_copy)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob('.aerivoice-dmg-*')))

    def test_source_change_during_packaging_is_rejected(self):
        def changing_source(filename, volume, **kwargs):
            Path(filename).write_bytes(b'image')
            (self.app / 'Contents/MacOS/AeriVoice').write_bytes(b'changed concurrently')

        with self.assertRaisesRegex(ValueError, 'Source app changed'):
            self.run_builder(changing_source)
        self.assertFalse(self.output.exists())

    def test_layout_metadata_cannot_invalidate_a_signed_app(self):
        copied = self.root / 'mounted/AeriVoice.app'
        shutil.copytree(self.app, copied)

        def modified_metadata(filename, volume, *, callback, **kwargs):
            Path(filename).write_bytes(b'image')
            callback({'type': 'operation::finished', 'operation': 'file::add', 'file': str(copied)})
            callback({'type': 'operation::finished', 'operation': 'dmg::create'})

        core = SimpleNamespace(build_dmg=modified_metadata, DMGError=RuntimeError)
        invalid_copy = subprocess.CalledProcessError(1, ['codesign', '--verify', str(copied)])
        with patch.dict(sys.modules, {'dmgbuild.core': core}), \
             patch.object(dmg, 'check_tools'), patch.object(dmg, 'has_bundle_signature', return_value=True), \
             patch.object(dmg, 'verify_signature', side_effect=[None, invalid_copy]) as verify, \
             patch.object(dmg.subprocess, 'run'):
            with self.assertRaises(subprocess.CalledProcessError):
                dmg.build(self.app, 'AeriVoice', self.output)
        self.assertEqual([call.args[0] for call in verify.call_args_list], [self.app.resolve(), copied])
        self.assertFalse(self.output.exists())

    def test_concurrent_output_is_preserved(self):
        def competing_build(filename, volume, **kwargs):
            Path(filename).write_bytes(b'new candidate')
            self.output.write_bytes(b'other build')

        with self.assertRaises(FileExistsError):
            self.run_builder(competing_build)
        self.assertEqual(self.output.read_bytes(), b'other build')

    def test_failed_build_detaches_only_its_still_mounted_volume(self):
        for actual_mount in ('/Volumes/AeriVoice-build', '/Volumes/Unrelated'):
            with self.subTest(actual_mount=actual_mount):
                def failed_build(filename, volume, *, callback, **kwargs):
                    callback({'type': 'command::finished', 'command': 'hdiutil::attach',
                              'output': {'system-entities': [
                                  {'dev-entry': '/dev/disk45s1', 'mount-point': '/Volumes/AeriVoice-build'}]}})
                    raise RuntimeError('sync failed')

                def command(args, **kwargs):
                    result = {'images': [{'system-entities': [
                        {'dev-entry': '/dev/disk45s1', 'mount-point': actual_mount}]}]}
                    return subprocess.CompletedProcess(args, 0, stdout=plistlib.dumps(result))

                core = SimpleNamespace(build_dmg=failed_build, DMGError=RuntimeError)
                with patch.dict(sys.modules, {'dmgbuild.core': core}), \
                     patch.object(dmg, 'check_tools'), \
                     patch.object(dmg, 'has_bundle_signature', return_value=False), \
                     patch.object(dmg.subprocess, 'run', side_effect=command) as run:
                    with self.assertRaisesRegex(ValueError, 'sync failed'):
                        dmg.build(self.app, 'AeriVoice', self.output)
                detaches = [call.args[0] for call in run.call_args_list
                            if call.args[0][:2] == ['hdiutil', 'detach']]
                expected = ([['hdiutil', 'detach', '-force', '/dev/disk45s1']]
                            if actual_mount == '/Volumes/AeriVoice-build' else [])
                self.assertEqual(detaches, expected)
                self.assertFalse(self.output.exists())

    def test_successful_detach_is_not_repeated_after_conversion_failure(self):
        def conversion_failed(filename, volume, *, callback, **kwargs):
            callback({'type': 'command::finished', 'command': 'hdiutil::attach',
                      'output': {'system-entities': [
                          {'dev-entry': '/dev/disk45s1', 'mount-point': '/Volumes/AeriVoice-build'}]}})
            callback({'type': 'command::finished', 'command': 'hdiutil::detach', 'ret': 0})
            raise RuntimeError('conversion failed')

        core = SimpleNamespace(build_dmg=conversion_failed, DMGError=RuntimeError)
        with patch.dict(sys.modules, {'dmgbuild.core': core}), \
             patch.object(dmg, 'check_tools'), patch.object(dmg, 'has_bundle_signature', return_value=False), \
             patch.object(dmg.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'conversion failed'):
                dmg.build(self.app, 'AeriVoice', self.output)
        self.assertFalse(any(call.args[0][0] == 'hdiutil' for call in run.call_args_list))
        self.assertFalse(self.output.exists())

    def test_signed_bundle_symlinks_and_executable_permissions_are_preserved(self):
        framework = self.app / 'Contents/Frameworks/Example.framework'
        (framework / 'Versions/A').mkdir(parents=True)
        (framework / 'Versions/A/Example').write_bytes(b'framework')
        (framework / 'Versions/Current').symlink_to('A')
        (framework / 'Example').symlink_to('Versions/Current/Example')
        expected = dmg.bundle_manifest(self.app)
        copied = self.root / 'copy.app'
        shutil.copytree(self.app, copied, symlinks=True)
        self.assertEqual(dmg.bundle_manifest(copied), expected)
        (copied / 'Contents/MacOS/AeriVoice').chmod(0o644)
        self.assertNotEqual(dmg.bundle_manifest(copied), expected)
        (copied / 'Contents/MacOS/AeriVoice').chmod(0o755)
        current = copied / 'Contents/Frameworks/Example.framework/Versions/Current'
        current.unlink()
        current.symlink_to('B')
        self.assertNotEqual(dmg.bundle_manifest(copied), expected)


if __name__ == '__main__':
    unittest.main()
