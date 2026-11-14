from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backup_core import load_settings
from drive_backup import BackupWindow, stop_and_reap


def window_without_ui(settings_path):
    window = BackupWindow.__new__(BackupWindow)
    window.window = Mock()
    window.config_path = settings_path
    window.settings = {'version': 1, 'sources': [], 'remote': '', 'root': '', 'computer': 'PC'}
    window.sources = SimpleNamespace(get=lambda *_: ('C:/folder with spaces',))
    window.remote_var = SimpleNamespace(get=lambda: 'google:')
    window.root_var = SimpleNamespace(get=lambda: 'New destination')
    window.worker = None
    window.close_requested = False
    return window


class ClosingTests(unittest.TestCase):
    def test_idle_close_saves_current_destination(self):
        with tempfile.TemporaryDirectory() as base:
            path = Path(base) / 'settings.json'
            window = window_without_ui(path)
            window.close()
            self.assertEqual(load_settings(path)['remote'], 'google:')
            self.assertEqual(load_settings(path)['root'], 'New destination')
            window.window.destroy.assert_called_once()

    def test_idle_close_keeps_window_open_when_save_fails(self):
        with tempfile.TemporaryDirectory() as base:
            window = window_without_ui(Path(base) / 'settings.json')
            with patch('drive_backup.save_settings', side_effect=OSError('disk full')):
                with patch('drive_backup.messagebox.showerror') as showerror:
                    window.close()
            window.window.destroy.assert_not_called()
            self.assertIn('disk full', str(showerror.call_args))

    def test_cancel_and_close_also_saves_before_destroying(self):
        with tempfile.TemporaryDirectory() as base:
            path = Path(base) / 'settings.json'
            window = window_without_ui(path)
            window.worker = object()
            window.close_requested = True
            window.events = queue.Queue()
            window.events.put(('done', 'Cancelled'))
            window.status_var = Mock()
            window.set_running = Mock()
            window.poll()
            self.assertEqual(load_settings(path)['root'], 'New destination')
            window.window.destroy.assert_called_once()

    def test_cancel_and_close_save_failure_leaves_polling_active(self):
        with tempfile.TemporaryDirectory() as base:
            window = window_without_ui(Path(base) / 'settings.json')
            window.worker = object()
            window.close_requested = True
            window.events = queue.Queue()
            window.events.put(('done', 'Cancelled'))
            window.status_var = Mock()
            window.set_running = Mock()
            with patch('drive_backup.save_settings', side_effect=OSError('disk full')):
                with patch('drive_backup.messagebox.showerror'):
                    window.poll()
            window.window.destroy.assert_not_called()
            window.window.after.assert_called_once()
            self.assertFalse(window.close_requested)


class ProcessCleanupTests(unittest.TestCase):
    @unittest.skipIf(sys.platform == 'win32', 'POSIX signals are not available on Windows')
    def test_unresponsive_child_is_killed_and_reaped(self):
        process = subprocess.Popen(
            [sys.executable, '-u', '-c',
             "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(60)"],
            stdout=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(process.stdout.readline().strip(), 'ready')
            stop_and_reap(process)
            self.assertIsNotNone(process.poll())
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            process.stdout.close()

    def test_log_write_failure_stops_and_reaps_active_child(self):
        with tempfile.TemporaryDirectory(prefix='process cleanup ') as base:
            base = Path(base)
            source = base / 'source folder'
            source.mkdir()
            script = base / 'long running child.py'
            script.write_text("import time\nprint('CHILD STARTED', flush=True)\ntime.sleep(60)\n", encoding='utf-8')
            window = BackupWindow.__new__(BackupWindow)
            window.rclone = 'unused'
            window.events = queue.Queue()
            window.dropped_lines = 0
            window.stop_requested = threading.Event()
            window.process = None
            processes = []
            actual_open = Path.open
            actual_popen = subprocess.Popen

            class FailingLog:
                def __init__(self, wrapped):
                    self.wrapped = wrapped

                def __enter__(self):
                    return self

                def __exit__(self, *args):
                    return self.wrapped.__exit__(*args)

                def write(self, value):
                    if 'CHILD STARTED' in value:
                        raise OSError('simulated full log volume')
                    return self.wrapped.write(value)

                def flush(self):
                    return self.wrapped.flush()

            def failing_open(path, *args, **kwargs):
                return FailingLog(actual_open(path, *args, **kwargs))

            def record_process(*args, **kwargs):
                process = actual_popen(*args, **kwargs)
                processes.append(process)
                return process

            worker = threading.Thread(
                target=window.run_backup,
                args=([str(source)], 'google:', 'Backups', 'PC', False, base / 'run.log'),
                daemon=True,
            )
            try:
                with patch.object(Path, 'open', failing_open), \
                     patch('drive_backup.copy_command', return_value=[sys.executable, '-u', str(script)]), \
                     patch('drive_backup.subprocess.Popen', side_effect=record_process):
                    worker.start()
                    worker.join(timeout=10)
                self.assertFalse(worker.is_alive(), 'backup worker did not finish')
                self.assertEqual(len(processes), 1)
                self.assertIsNotNone(processes[0].poll(), 'child remained alive after failure')
                self.assertIsNone(window.process)
                events = list(window.events.queue)
                self.assertIn(('done', 'Failed'), events)
                self.assertTrue(any('simulated full log volume' in str(value) for _, value in events))
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=5)
                worker.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
