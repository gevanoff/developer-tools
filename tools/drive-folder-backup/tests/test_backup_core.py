import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backup_core import (BackupError, canonical_source, copy_command, destination,
                         discover_drive_remotes, load_settings, save_settings,
                         source_identifier, validate_root)


class PlanningTests(unittest.TestCase):
    def test_stable_destination_and_distinct_same_named_folders(self):
        with tempfile.TemporaryDirectory() as base:
            one = Path(base) / 'a' / 'Project'
            two = Path(base) / 'b' / 'Project'
            one.mkdir(parents=True)
            two.mkdir(parents=True)
            self.assertNotEqual(source_identifier(str(one)), source_identifier(str(two)))
            self.assertEqual(destination('drive:', 'PC Backups', 'HOST', str(one)),
                             destination('drive:', 'PC Backups', 'HOST', str(one)))
            self.assertTrue(destination('drive:', 'PC Backups', 'HOST', str(one)).startswith('drive:PC Backups/HOST/'))

    def test_roots_reject_traversal_and_absolute_and_remote_syntax(self):
        for root in ('', '/', '/root', '../bad', 'root/../bad', 'a//b', 'a/./b', 'C:/bad', 'a\\b', 'a/ bad ', 'a\nb'):
            with self.subTest(root=root), self.assertRaises(BackupError):
                validate_root(root)
        self.assertEqual(validate_root('Project Backups/2026'), 'Project Backups/2026')

    def test_no_arbitrary_remote_or_shell_arguments(self):
        with self.assertRaises(BackupError):
            destination('../drive:', 'backup', 'host', '/tmp')
        argv = copy_command('rclone', 'C:/Path with spaces/--danger', 'gdrive:Path name/child', True)
        self.assertIn('--dry-run', argv)
        self.assertEqual(argv[-3:], ['--', 'C:/Path with spaces/--danger', 'gdrive:Path name/child'])
        self.assertNotIn('sync', argv)

    def test_bad_settings_are_not_overwritten(self):
        with tempfile.TemporaryDirectory() as base:
            p = Path(base) / 'settings.json'
            p.write_text('{broken', encoding='utf-8')
            with self.assertRaises(BackupError):
                load_settings(p)
            self.assertEqual(p.read_text(encoding='utf-8'), '{broken')

    def test_atomic_save_and_load_in_path_with_spaces(self):
        with tempfile.TemporaryDirectory() as base:
            p = Path(base) / 'with spaces' / 'settings.json'
            data = {'version': 1, 'sources': ['C:/data path'], 'root': 'backup', 'remote': 'gdrive:', 'computer': 'PC'}
            save_settings(p, data)
            self.assertEqual(load_settings(p), data)
            self.assertEqual(list(p.parent.iterdir()), [p])

    def test_drive_remote_only(self):
        fake = subprocess.CompletedProcess(['rclone'], 0, 'other: local\ngdrive: drive\nmydrive: drive\n', '')
        with patch('backup_core.subprocess.run', return_value=fake) as call:
            self.assertEqual(discover_drive_remotes('rclone'), ['gdrive:', 'mydrive:'])
            self.assertEqual(call.call_args.args[0], ['rclone', 'listremotes', '--long'])
        with patch('backup_core.subprocess.run', return_value=subprocess.CompletedProcess(['rclone'], 1, '', 'not configured')):
            with self.assertRaises(BackupError):
                discover_drive_remotes('rclone')

    @unittest.skipUnless(shutil.which('rclone'), 'rclone is not installed')
    def test_discover_with_installed_rclone_and_isolated_config(self):
        with tempfile.TemporaryDirectory(prefix='rclone test ') as base:
            config = Path(base) / 'rclone config.conf'
            config.write_text('[google]\ntype = drive\n[local]\ntype = local\n', encoding='utf-8')
            with patch.dict(os.environ, {'RCLONE_CONFIG': str(config)}):
                self.assertEqual(discover_drive_remotes(shutil.which('rclone')), ['google:'])

    @unittest.skipUnless(shutil.which('rclone'), 'rclone is not installed')
    def test_real_rclone_copy_preview_and_remote_only_file(self):
        with tempfile.TemporaryDirectory(prefix='rclone copy ') as base:
            src, dst = Path(base) / 'source folder', Path(base) / 'destination folder'
            src.mkdir()
            dst.mkdir()
            (src / 'file name.txt').write_text('new contents', encoding='utf-8')
            (dst / 'remote only.txt').write_text('keep', encoding='utf-8')
            binary = shutil.which('rclone')
            with patch.dict(os.environ, {'RCLONE_CONFIG': str(Path(base) / 'isolated.conf')}):
                for dry_run in (True, False):
                    result = subprocess.run(copy_command(binary, str(src), str(dst), dry_run),
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((dst / 'file name.txt').exists(), not dry_run)
                    self.assertEqual((dst / 'remote only.txt').read_text(encoding='utf-8'), 'keep')
                restore = Path(base) / 'restore folder'
                result = subprocess.run(copy_command(binary, str(dst), str(restore)),
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((restore / 'file name.txt').read_text(encoding='utf-8'), 'new contents')
                self.assertEqual((restore / 'remote only.txt').read_text(encoding='utf-8'), 'keep')

    @unittest.skipIf(sys.platform == 'win32', 'Unix shebang test; Windows path/GUI needs separate acceptance')
    def test_copy_to_fake_drive_does_not_delete_existing_files(self):
        with tempfile.TemporaryDirectory() as base:
            home = Path(base)
            src = home / 'source with spaces'
            src.mkdir()
            (src / 'file name.txt').write_text('v1')
            drive = home / 'drive'
            fake = home / 'fake-rclone'
            fake.write_text('#!/usr/bin/env python3\n'
                            'import pathlib, sys, shutil\n'
                            'assert sys.argv[1] == "copy" and "--" in sys.argv\n'
                            'src = pathlib.Path(sys.argv[-2])\n'
                            'dst = pathlib.Path(sys.argv[-1].split(":",1)[1])\n'
                            'dst.mkdir(parents=True, exist_ok=True)\n'
                            'for p in src.iterdir():\n'
                            '    if p.is_file(): shutil.copy2(p, dst/p.name)\n')
            fake.chmod(0o755)
            target = 'fake:' + str(drive)
            argv = copy_command(str(fake), str(src), target)
            self.assertEqual(subprocess.run(argv, capture_output=True).returncode, 0)
            (drive / 'only on remote.txt').write_text('keep')
            (src / 'file name.txt').write_text('v2')
            self.assertEqual(subprocess.run(argv, capture_output=True).returncode, 0)
            self.assertEqual((drive / 'file name.txt').read_text(), 'v2')
            self.assertEqual((drive / 'only on remote.txt').read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
