"""Offscreen widget tests for the dashboard. No Git, ADB, or device needed."""
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

try:
    from PySide6.QtWidgets import QApplication, QMessageBox
except ImportError:  # pragma: no cover - PySide6 is a runtime dependency
    QApplication = None

from android_build_install_linux import core


@unittest.skipIf(QApplication is None, "PySide6 is not installed")
class DashboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        patcher = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(root / "config"),
                                               "XDG_STATE_HOME": str(root / "state")})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.projects = []
        for name in ("alpha app", "beta"):
            path = root / "src with spaces" / name
            path.mkdir(parents=True)
            core.remember_project(str(path))
            self.projects.append(str(path.resolve()))
        self.statuses = {
            self.projects[0]: core.ProjectStatus("Behind 2", "Stale", "Different", "", "main"),
            self.projects[1]: core.ProjectStatus("Dirty", "Fresh", "Same", "Working tree has local changes.", "dev"),
        }
        status = mock.patch.object(core, "project_status",
                                   side_effect=lambda project, fetch=False: self.statuses[project])
        status.start()
        self.addCleanup(status.stop)
        from android_build_install_linux.app import MainWindow
        self.window = MainWindow()
        self.addCleanup(self.close_window)
        self.wait(lambda: not self.window.refreshing)

    def close_window(self):
        self.window.busy = False
        self.window.close()
        self.temp.cleanup()

    def wait(self, condition, timeout=5.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.app.processEvents()
            if condition():
                return
            time.sleep(0.01)
        self.fail("Timed out waiting for the dashboard")

    def select(self, project):
        self.window.select_project(project)
        self.app.processEvents()

    def test_button_labels_keep_their_ampersand(self):
        # A bare "&" in a Qt label is a mnemonic and was rendered as "Sync _Run".
        self.assertEqual(self.window.sync_button.text().replace("&&", "&"), "Sync & Run")
        self.assertEqual(self.window.build_button.text().replace("&&", "&"), "Build & Install")

    def test_refresh_fills_status_chips_and_preview(self):
        self.select(self.projects[0])
        row = self.window._row_for(self.projects[0])
        self.assertEqual(self.window.table.item(row, 1).text(), "Behind 2")
        self.assertEqual(self.window.table.item(row, 3).text(), "Different")
        self.assertIn("Pull 2 commits", self.window.detail_plan.text())
        self.select(self.projects[1])
        self.assertIn("will stop", self.window.detail_plan.text())

    def test_failure_is_reported_in_the_panel_without_a_dialog(self):
        self.select(self.projects[0])

        def fail(*_args, **_kwargs):
            raise core.ToolError("Sync & Run stopped: Git state is Dirty.")

        with mock.patch.object(core, "build_install", side_effect=fail), \
                mock.patch.object(QMessageBox, "critical") as critical:
            self.window.sync_run()
            self.wait(lambda: not self.window.busy and not self.window.refreshing)
        critical.assert_not_called()
        self.assertEqual(self.window.operation_state, "failed")
        self.assertIn("Git state is Dirty", self.window.op_detail.full_text())
        self.assertNotIn("Traceback", self.window.output.toPlainText())

    def test_success_rechecks_only_the_project_without_fetching(self):
        self.select(self.projects[0])
        calls = []
        core.project_status.side_effect = lambda project, fetch=False: (
            calls.append((project, fetch)) or self.statuses[project])
        with mock.patch.object(core, "build_install", return_value="log"):
            self.window.sync_run()
            self.wait(lambda: not self.window.busy and not self.window.refreshing)
        self.assertEqual(self.window.operation_state, "success")
        self.assertEqual(calls, [(self.projects[0], False)])

    def test_cancel_is_reenabled_for_each_new_operation(self):
        self.select(self.projects[0])
        # Keep the worker pending so clicks and completion are deterministic.
        with mock.patch.object(self.window, "_launch") as launch, \
                mock.patch.object(self.window, "refresh"):
            for _ in range(2):
                self.window.sync_run()
                self.assertTrue(self.window.busy)
                self.assertFalse(self.window.controller.cancelled)
                self.assertFalse(self.window.cancel_button.isHidden())
                self.assertTrue(self.window.cancel_button.isEnabled())
                self.window.cancel_button.click()
                self.assertTrue(self.window.controller.cancelled)
                self.assertFalse(self.window.cancel_button.isEnabled())
                # An unrelated controls update must not re-enable a pending cancel.
                self.window.update_controls()
                self.assertFalse(self.window.cancel_button.isEnabled())
                failed = launch.call_args.args[2]
                failed((core.OperationCancelled("Cancelled"), ""))
                self.assertFalse(self.window.busy)
                self.assertEqual(self.window.operation_state, "cancelled")
                self.assertTrue(self.window.cancel_button.isHidden())

    def test_remove_asks_first_and_keeps_the_project_on_cancel(self):
        self.select(self.projects[1])
        with mock.patch.object(QMessageBox, "question", return_value=QMessageBox.Cancel):
            self.window.remove_project()
        self.assertIn(self.projects[1], core.load_projects())
        with mock.patch.object(QMessageBox, "question", return_value=QMessageBox.Yes):
            self.window.remove_project()
        self.assertNotIn(self.projects[1], core.load_projects())
        self.assertTrue(Path(self.projects[1]).is_dir())

    def test_actions_are_disabled_while_busy(self):
        self.select(self.projects[0])
        self.window.busy = True
        self.window.update_controls()
        self.assertFalse(self.window.sync_button.isEnabled())
        self.assertFalse(self.window.remove_button.isEnabled())
        self.window.busy = False
        self.window.update_controls()
        self.assertTrue(self.window.sync_button.isEnabled())

    def test_empty_state(self):
        for project in core.load_projects():
            core.remove_project(project)
        self.window.reload_rows()
        self.assertIs(self.window.project_stack.currentWidget(), self.window.empty)
        self.assertFalse(self.window.sync_button.isEnabled())


if __name__ == "__main__":
    unittest.main()
