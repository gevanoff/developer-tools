"""Offscreen widget tests for the dashboard. No Git, ADB, or device needed."""
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

try:
    from PySide6.QtWidgets import QApplication, QFileDialog, QInputDialog, QMessageBox
except ImportError:  # pragma: no cover - PySide6 is a runtime dependency
    QApplication = None

from android_build_install_linux import core


@unittest.skipIf(QApplication is None, "PySide6 is not installed")
class DashboardTestCase(unittest.TestCase):
    """Shared setup: two saved projects and a mocked status check."""
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


class DashboardTests(DashboardTestCase):
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


class ProjectManagementTests(DashboardTestCase):
    """Adding projects from a repository, renaming, and refresh scope."""

    def make_project(self, folder: Path) -> Path:
        (folder / "app" / "src" / "main").mkdir(parents=True)
        (folder / "app" / "src" / "main" / "AndroidManifest.xml").write_text("<manifest/>")
        (folder / "gradlew").write_text("")
        return folder

    def calls_during_refresh(self, action):
        calls = []
        core.project_status.side_effect = lambda project, fetch=False: (
            calls.append(project) or self.statuses.get(project) or core.ProjectStatus("Current", "Fresh", "Same", ""))
        action()
        self.wait(lambda: not self.window.refreshing)
        return calls

    def test_nothing_is_selected_at_start_so_refresh_checks_all(self):
        self.assertEqual(self.window.selected_projects(), [])
        self.assertEqual(self.window.refresh_button.text(), "Refresh All")
        self.assertEqual(sorted(self.calls_during_refresh(self.window.refresh_or_stop)), sorted(self.projects))

    def test_refresh_checks_only_the_selected_projects(self):
        self.select(self.projects[1])
        self.assertEqual(self.window.refresh_button.text(), "Refresh Selected")
        self.assertEqual(self.calls_during_refresh(self.window.refresh_or_stop), [self.projects[1]])
        self.window.select_projects(self.projects)
        self.app.processEvents()
        self.assertEqual(self.window.refresh_button.text(), "Refresh 2 Selected")
        self.assertIn("2 projects selected", self.window.detail_name.text())
        self.assertFalse(self.window.sync_button.isEnabled())
        self.window.table.clearSelection()
        self.app.processEvents()
        self.assertEqual(self.window.refresh_button.text(), "Refresh All")

    def test_rename_and_reset_to_folder_name(self):
        self.select(self.projects[0])
        with mock.patch.object(QInputDialog, "getText", return_value=("Chess (phone)", True)):
            self.window.rename_project()
        row = self.window._row_for(self.projects[0])
        self.assertEqual(self.window.table.item(row, 0).text(), "Chess (phone)")
        self.assertEqual(self.window.detail_name.text(), "Chess (phone)")
        self.assertEqual(self.window.selected_project(), self.projects[0])
        with mock.patch.object(QInputDialog, "getText", return_value=("", True)):
            self.window.rename_project()
        self.assertEqual(self.window.table.item(row, 0).text(), "alpha app")
        with mock.patch.object(QInputDialog, "getText", return_value=("Ignored", False)):
            self.window.rename_project()
        self.assertEqual(self.window.table.item(row, 0).text(), "alpha app")

    def test_add_offers_every_project_beneath_the_repository(self):
        repo = Path(self.temp.name) / "big repo"
        phone = self.make_project(repo / "phone app")
        watch = self.make_project(repo / "wear" / "watch app")
        (repo / "server").mkdir()
        (repo / "server" / "gradlew").write_text("")  # not Android: listed, not pre-checked
        seen = {}

        def accept(dialog):
            seen["names"] = [box.text() for box, _ in dialog.boxes]
            seen["checked"] = [box.text() for box, _ in dialog.boxes if box.isChecked()]
            seen["button"] = dialog.add_button.text()
            return 1

        from android_build_install_linux import app as app_module
        with mock.patch.object(QFileDialog, "getExistingDirectory", return_value=str(repo)), \
                mock.patch.object(app_module.ProjectPickerDialog, "exec", accept):
            added = self.calls_during_refresh(self.window.add_project)
        self.assertEqual(seen["names"], ["phone app", "server", "watch app"])
        self.assertEqual(seen["checked"], ["phone app", "watch app"])
        self.assertEqual(seen["button"], "Add 2 projects")
        expected = [str(phone.resolve()), str(watch.resolve())]
        self.assertEqual(sorted(added), sorted(expected))
        self.assertEqual(sorted(self.window.selected_projects()), sorted(expected))
        self.assertNotIn(str((repo / "server").resolve()), core.load_projects())

    def test_a_project_folder_is_added_without_asking(self):
        project = self.make_project(Path(self.temp.name) / "solo")
        from android_build_install_linux import app as app_module
        with mock.patch.object(QFileDialog, "getExistingDirectory", return_value=str(project)), \
                mock.patch.object(app_module.ProjectPickerDialog, "exec", side_effect=AssertionError("asked")):
            self.calls_during_refresh(self.window.add_project)
        self.assertIn(str(project.resolve()), core.load_projects())

    def test_projects_already_added_cannot_be_added_again(self):
        repo = Path(self.temp.name) / "src with spaces"
        self.make_project(repo / "alpha app")
        from android_build_install_linux import app as app_module, projects
        dialog = app_module.ProjectPickerDialog(projects.discover(str(repo)), set(core.load_projects()), self.window)
        box = dict((b.text(), b) for b, _ in dialog.boxes)["alpha app"]
        self.assertFalse(box.isEnabled())
        self.assertEqual(dialog.chosen(), [])
        self.assertFalse(dialog.add_button.isEnabled())
        dialog.close()

    def test_nothing_found_asks_before_adding_the_folder(self):
        empty = Path(self.temp.name) / "notes"
        empty.mkdir()
        with mock.patch.object(QFileDialog, "getExistingDirectory", return_value=str(empty)), \
                mock.patch.object(QMessageBox, "question", return_value=QMessageBox.Cancel):
            self.window.add_project()
        self.assertNotIn(str(empty.resolve()), core.load_projects())


if __name__ == "__main__":
    unittest.main()
