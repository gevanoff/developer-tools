import os
import time
import unittest
from unittest import mock

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QThread
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

from android_build_install_linux import core
from android_build_install_linux.app import MainWindow


class AppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        with mock.patch.object(core, "load_projects", return_value=[]):
            self.window = MainWindow()

    def tearDown(self):
        self.window.pool.waitForDone(5000)
        self.window.close()
        self.window.deleteLater()
        self.app.processEvents()

    def wait_for_completion(self):
        deadline = time.monotonic() + 5
        while self.window.busy and time.monotonic() < deadline:
            QTest.qWait(10)
        self.assertFalse(self.window.busy, self.window.status.text())

    def test_refresh_updates_rows_and_can_repeat(self):
        project = "/tmp/android project with spaces"
        status = core.ProjectStatus("Current", "Fresh", "Same", "APK details")
        with mock.patch.object(core, "load_projects", return_value=[project]), \
                mock.patch.object(core, "project_status", return_value=status) as probe:
            self.window.reload_rows()
            for _ in range(2):
                self.window.refresh()
                self.wait_for_completion()
                self.assertEqual(self.window.status.text(), "Ready")
                self.assertEqual(
                    [self.window.table.item(0, col).text() for col in range(1, 4)],
                    ["Current", "Fresh", "Same"],
                )
            self.assertEqual(probe.call_count, 2)
            probe.assert_called_with(project, fetch=True)

    def test_completion_runs_on_ui_thread_and_can_start_next_operation(self):
        threads = []
        results = []

        def done(value):
            threads.append(QThread.currentThread())
            results.append(value)
            self.window.start("Next", lambda emit: "second", results.append)

        self.window.start("First", lambda emit: "first", done, cancellable=True)
        self.wait_for_completion()
        self.assertEqual(threads, [self.app.thread()])
        self.assertEqual(results, ["first", "second"])
        self.assertFalse(self.window.cancel_button.isEnabled())

    def test_failure_releases_busy_without_success_callback(self):
        done = mock.Mock()

        def task(emit):
            raise core.ToolError("Status unavailable")

        with mock.patch("android_build_install_linux.app.QMessageBox.critical") as error:
            self.window.start("Refreshing status…", task, done, cancellable=True)
            self.wait_for_completion()
            error.assert_called_once_with(self.window, "Operation failed", "Status unavailable")
        done.assert_not_called()
        self.assertEqual(self.window.status.text(), "Failed")
        self.assertFalse(self.window.cancel_button.isEnabled())
        self.window.start("Retry", lambda emit: None)
        self.wait_for_completion()
        self.assertEqual(self.window.status.text(), "Ready")


if __name__ == "__main__":
    unittest.main()
