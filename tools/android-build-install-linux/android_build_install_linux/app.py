from __future__ import annotations

import sys
import json
import traceback
from pathlib import Path

from PySide6.QtCore import QObject, QRunnable, QThreadPool, QTimer, QUrl, Signal, Slot
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QHBoxLayout, QHeaderView, QLabel, QLineEdit, QMainWindow, QMessageBox,
    QPushButton, QPlainTextEdit, QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget,
)

from . import core
from . import backends


class BackendDialog(QDialog):
    def __init__(self, project, parent=None):
        super().__init__(parent)
        roots = backends.find_roots(project)
        if len(roots) > 1:
            raise backends.BackendError("Select a specific build root before editing its configuration.")
        self.root = roots[0] if roots else Path(project)
        self.path = self.root / backends.CONFIG
        self.setWindowTitle("Godot / custom build configuration")
        self.resize(720, 480)
        layout = QVBoxLayout(self)
        help_text = QLabel("Godot is detected automatically. Configure its editor path/preset here if needed.\n"
                           "Custom builds run executable + arguments in this folder and must update apk.\n"
                           "This file contains build instructions: review commands before running them.\n"
                           f"{self.path}")
        help_text.setWordWrap(True)
        layout.addWidget(help_text)
        self.editor = QPlainTextEdit()
        default = {"version": 1, "backend": "godot", "apk": "build/android/app-debug.apk"}
        if not (self.root / "project.godot").is_file():
            default = {"version": 1, "backend": "custom", "executable": "flutter",
                       "arguments": ["build", "apk", "--debug"],
                       "apk": "build/app/outputs/flutter-apk/app-debug.apk"}
        self.editor.setPlainText(self.path.read_text(encoding="utf-8-sig") if self.path.exists()
                                 else json.dumps(default, indent=2))
        layout.addWidget(self.editor)
        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.save)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def save(self):
        try:
            data = json.loads(self.editor.toPlainText())
            if not isinstance(data, dict) or data.get("version") != 1:
                raise ValueError("Expected an object with version: 1")
            core.save_json(self.path, data)
            self.accept()
        except (ValueError, OSError) as exc:
            QMessageBox.critical(self, "Invalid configuration", str(exc))


class Signals(QObject):
    line = Signal(str)
    done = Signal(object)
    failed = Signal(str)


class Worker(QRunnable):
    def __init__(self, fn):
        super().__init__()
        self.fn = fn
        self.signals = Signals()

    @Slot()
    def run(self):
        try:
            self.signals.done.emit(self.fn(self.signals.line.emit))
        except Exception as exc:
            self.signals.failed.emit(f"{exc}\n\n{traceback.format_exc()}")


class SettingsDialog(QDialog):
    def __init__(self, project: str, parent=None):
        super().__init__(parent)
        self.project = project
        self.setWindowTitle("Project Settings")
        pref = core.load_preferences(project)

        self.gradle = QLineEdit(pref.gradle_task)
        self.apk = QLineEdit(pref.preferred_apk)
        self.java = QLineEdit(pref.java_home)
        self.device = QLineEdit(pref.device_serial)
        self.launch = QCheckBox()
        self.launch.setChecked(pref.auto_launch)

        form = QFormLayout()
        form.addRow("Gradle task (Gradle only)", self.gradle)
        form.addRow("Preferred APK", self.apk)
        form.addRow("JAVA_HOME", self.java)
        form.addRow("Preferred device serial", self.device)
        form.addRow("Auto-launch", self.launch)

        detect = QPushButton("Detect one connected device")
        detect.clicked.connect(self.detect)
        form.addRow("", detect)
        backend = QPushButton("Godot / custom build…")
        backend.clicked.connect(self.backend)
        form.addRow("Build configuration", backend)

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.save)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(buttons)

    def detect(self):
        try:
            roots = backends.find_roots(self.project)
            root = roots[0] if len(roots) == 1 else Path(self.project)
            adb = core.resolve_adb(root)
            devices = [d for d in core.connected_devices(adb) if d.state == "device"]
            if len(devices) == 1:
                self.device.setText(devices[0].serial)
            elif not devices:
                QMessageBox.warning(self, "No device", "No authorized Android device is connected.")
            else:
                QMessageBox.information(self, "Multiple devices",
                                        "Multiple devices are connected. Paste the desired serial from 'adb devices -l'.")
        except Exception as exc:
            QMessageBox.critical(self, "Detection failed", str(exc))

    def backend(self):
        try:
            BackendDialog(self.project, self).exec()
        except Exception as exc:
            QMessageBox.critical(self, "Configuration failed", str(exc))

    def save(self):
        core.save_preferences(self.project, core.Preferences(
            gradle_task=self.gradle.text().strip() or "assembleDebug",
            preferred_apk=self.apk.text().strip(),
            java_home=self.java.text().strip(),
            device_serial=self.device.text().strip(),
            auto_launch=self.launch.isChecked(),
        ))
        self.accept()


class MainWindow(QMainWindow):
    def __init__(self, initial_project: str | None = None):
        super().__init__()
        self.initial_project = initial_project
        self.setWindowTitle("Android Build and Install — Linux")
        self.resize(1120, 720)
        self.pool = QThreadPool.globalInstance()
        self.busy = False
        self.controller = core.ProcessController()

        root = QWidget()
        self.setCentralWidget(root)
        outer = QVBoxLayout(root)

        outer.addWidget(QLabel("Android project dashboard"))

        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["Project", "Git", "Local Build", "Device"])
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        self.table.setColumnWidth(1, 280)
        self.table.setSelectionBehavior(QTableWidget.SelectRows)
        self.table.setEditTriggers(QTableWidget.NoEditTriggers)
        self.table.doubleClicked.connect(lambda _: self.sync_run())
        outer.addWidget(self.table, 2)

        row = QHBoxLayout()
        for label, callback in [
            ("Sync & Run", self.sync_run),
            ("Build & Install", self.build_install),
            ("Git Pull", self.git_pull),
            ("Refresh Status", self.refresh),
            ("Scan Device…", self.scan_device),
            ("Reports…", self.reports),
            ("Settings…", self.settings),
            ("Add…", self.add_project),
            ("Remove", self.remove_project),
        ]:
            button = QPushButton(label)
            button.clicked.connect(callback)
            row.addWidget(button)
        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.setEnabled(False)
        self.cancel_button.clicked.connect(self.cancel_operation)
        row.addWidget(self.cancel_button)
        outer.addLayout(row)

        outer.addWidget(QLabel("Operation output"))
        self.output = QPlainTextEdit()
        self.output.setReadOnly(True)
        self.output.document().setMaximumBlockCount(4000)
        outer.addWidget(self.output, 1)

        self.status = QLabel("")
        outer.addWidget(self.status)

        if self.initial_project:
            core.remember_project(self.initial_project)
        self.reload_rows()
        self.select_project(self.initial_project)
        if not self.initial_project:
            self.refresh()

    def selected_project(self) -> str | None:
        row = self.table.currentRow()
        if row < 0:
            return None
        item = self.table.item(row, 0)
        return item.data(1001) if item else None

    def select_project(self, project: str | None):
        if not project:
            return
        normalized = str(Path(project).expanduser().resolve())
        for row in range(self.table.rowCount()):
            item = self.table.item(row, 0)
            if item and item.data(1001) == normalized:
                self.table.selectRow(row)
                return

    def reload_rows(self):
        projects = core.load_projects()
        self.table.setRowCount(len(projects))
        for row, project in enumerate(projects):
            item = QTableWidgetItem(Path(project).name)
            item.setToolTip(project)
            item.setData(1001, project)
            self.table.setItem(row, 0, item)
            for col in range(1, 4):
                self.table.setItem(row, col, QTableWidgetItem("Queued"))
        if projects:
            self.table.selectRow(0)

    def append(self, line: str):
        self.output.appendPlainText(line)

    def start(self, label: str, fn, done=None, cancellable: bool = False):
        if self.busy:
            QMessageBox.information(self, "Busy", "An operation is already running.")
            return
        self.busy = True
        self.controller.reset()
        self.cancel_button.setEnabled(cancellable)
        self.status.setText(label)
        worker = Worker(fn)
        worker.signals.line.connect(self.append)
        worker.signals.failed.connect(self.failed)

        def finished(value):
            self.busy = False
            self.cancel_button.setEnabled(False)
            self.status.setText("Ready")
            if done:
                done(value)

        worker.signals.done.connect(finished)
        self.pool.start(worker)

    def failed(self, message: str):
        self.busy = False
        self.cancel_button.setEnabled(False)
        first = message.split("\n\n", 1)[0]
        if first.strip() == "Operation cancelled.":
            self.status.setText("Cancelled")
            self.append("Operation cancelled.")
            return
        self.status.setText("Failed")
        self.append(message)
        QMessageBox.critical(self, "Operation failed", first)

    def cancel_operation(self):
        if not self.busy:
            return
        self.status.setText("Cancelling…")
        self.cancel_button.setEnabled(False)
        self.controller.cancel()

    def require_project(self) -> str | None:
        project = self.selected_project()
        if not project:
            QMessageBox.information(self, "No project", "Select or add an Android project first.")
        return project

    def refresh(self):
        projects = core.load_projects()
        if not projects or self.busy:
            return

        def task(emit):
            results = {}
            for i, project in enumerate(projects, 1):
                emit(f"Refreshing {i}/{len(projects)}: {project}")
                results[project] = core.project_status(project, fetch=True)
            return results

        def done(results):
            for row in range(self.table.rowCount()):
                project = self.table.item(row, 0).data(1001)
                st = results.get(project)
                if not st:
                    continue
                for col, value in enumerate((st.git_display, st.build, st.device), 1):
                    self.table.item(row, col).setText(value)
                    self.table.item(row, col).setToolTip(f"Git: {st.git_display}\n{st.detail}")

        self.start("Refreshing status…", task, done)

    def sync_run(self):
        project = self.require_project()
        if not project:
            return
        self.output.clear()
        self.start("Sync & Run…",
                   lambda emit: core.build_install(project, sync=True, force_build=False,
                                                   stream=emit, controller=self.controller),
                   lambda _: self.refresh(), cancellable=True)

    def build_install(self):
        project = self.require_project()
        if not project:
            return
        self.output.clear()
        self.start("Build & Install…",
                   lambda emit: core.build_install(project, sync=False, force_build=True,
                                                   stream=emit, controller=self.controller),
                   lambda _: self.refresh(), cancellable=True)

    def git_pull(self):
        project = self.require_project()
        if not project:
            return
        self.output.clear()
        self.start("Git Pull…",
                   lambda emit: core.safe_git_pull(project, emit, self.controller),
                   lambda _: self.refresh(), cancellable=True)

    def scan_device(self):
        projects = core.load_projects()
        if not projects:
            QMessageBox.information(self, "No projects", "Add an Android project first.")
            return

        def task(emit):
            lines = []
            for project in projects:
                emit(f"Scanning device state: {project}")
                status = core.project_status(project, fetch=False)
                lines.append(
                    f"{Path(project).name}\n"
                    f"  Device: {status.device}\n"
                    f"  Local build: {status.build}\n"
                    f"  {status.detail or ''}"
                )
            return "\n\n".join(lines)

        def done(text):
            dialog = QDialog(self)
            dialog.setWindowTitle("Android Device Scan")
            dialog.resize(760, 520)
            layout = QVBoxLayout(dialog)
            output = QPlainTextEdit()
            output.setReadOnly(True)
            output.setPlainText(text)
            layout.addWidget(output)
            buttons = QDialogButtonBox(QDialogButtonBox.Close)
            buttons.rejected.connect(dialog.reject)
            buttons.clicked.connect(dialog.accept)
            layout.addWidget(buttons)
            dialog.exec()

        self.start("Scanning device…", task, done)

    def reports(self):
        log_dir = core.state_root() / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(log_dir)))

    def settings(self):
        project = self.require_project()
        if not project:
            return
        if SettingsDialog(project, self).exec():
            self.refresh()

    def add_project(self):
        path = QFileDialog.getExistingDirectory(self, "Choose Android project or repository")
        if not path:
            return
        core.remember_project(path)
        self.reload_rows()
        self.refresh()

    def remove_project(self):
        project = self.require_project()
        if not project:
            return
        core.remove_project(project)
        self.reload_rows()


def main() -> int:
    initial_project = None
    for arg in sys.argv[1:]:
        candidate = Path(arg).expanduser()
        if candidate.is_dir():
            initial_project = str(candidate.resolve())
            break

    app = QApplication(sys.argv)
    win = MainWindow(initial_project=initial_project)
    win.show()
    if initial_project:
        QTimer.singleShot(0, win.build_install)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
