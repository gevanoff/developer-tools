from __future__ import annotations

import sys
import json
import time
import traceback
from pathlib import Path

from PySide6.QtCore import (
    QItemSelectionModel, QObject, QRect, QRunnable, QSize, Qt, QThreadPool, QTimer, QUrl, Signal, Slot,
)
from PySide6.QtGui import QColor, QDesktopServices, QFont, QFontMetrics, QIcon, QKeySequence, QPainter, QPixmap, QShortcut
from PySide6.QtWidgets import (
    QAbstractItemView, QApplication, QCheckBox, QScrollArea, QDialog, QDialogButtonBox, QFileDialog,
    QFormLayout, QFrame, QHBoxLayout, QHeaderView, QInputDialog, QLabel, QLineEdit,
    QMainWindow, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QSizePolicy,
    QStackedWidget, QStyle, QStyledItemDelegate, QStyleOptionViewItem, QTableWidget,
    QTableWidgetItem, QVBoxLayout, QWidget,
)

from . import backends, core, presentation, projects, theme

ICON_PATH = Path(__file__).resolve().parent / "assets" / "droidrun-icon.png"
ROLE_PATH = 1001
ROLE_TONE = int(Qt.UserRole) + 2
ROLE_BRANCH = int(Qt.UserRole) + 3
ROLE_SUBTITLE = int(Qt.UserRole) + 4
COLUMNS = ["Project", "Git", "Local build", "Device", "Checked"]
PENDING = "Queued"
PLAIN = "plain"  # ROLE_TONE value for cells drawn as muted text instead of a chip


def display_path(path: str) -> str:
    """Show paths under the home directory as ~/… to save width."""
    home = str(Path.home())
    return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path


class ElidedLabel(QLabel):
    """Single-line label that elides in the middle and keeps the full text in a tooltip."""

    def __init__(self, text: str = "", parent=None):
        super().__init__(parent)
        self._full = ""
        self.setMinimumWidth(40)
        self.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
        self.setText(text)

    def setText(self, text: str) -> None:  # noqa: N802 - Qt naming
        self._full = text or ""
        self.setToolTip(self._full)
        self._apply()

    def full_text(self) -> str:
        return self._full

    def resizeEvent(self, event):  # noqa: N802
        super().resizeEvent(event)
        self._apply()

    def _apply(self) -> None:
        width = max(10, self.width())
        super().setText(self.fontMetrics().elidedText(self._full, Qt.ElideMiddle, width))


def paint_chip(painter: QPainter, rect: QRect, text: str, tone_name: str, font: QFont) -> int:
    """Draw a rounded status chip at the left of rect; return its right edge."""
    fg, bg = theme.chip_colors(tone_name)
    painter.setFont(font)
    metrics = painter.fontMetrics()  # measure on the paint device, not the default screen
    width = min(rect.width(), metrics.horizontalAdvance(text) + 22)  # slack avoids rounding elision
    height = metrics.height() + 6
    chip = QRect(rect.left(), rect.center().y() - height // 2 + 1, width, height)
    painter.save()
    painter.setRenderHint(QPainter.Antialiasing)
    painter.setPen(Qt.NoPen)
    painter.setBrush(QColor(bg))
    painter.drawRoundedRect(chip, height / 2, height / 2)
    painter.setPen(QColor(fg))
    painter.setFont(font)
    painter.drawText(chip.adjusted(9, 0, -9, 0), Qt.AlignVCenter | Qt.AlignLeft,
                     metrics.elidedText(text, Qt.ElideRight, chip.width() - 18))
    painter.restore()
    return chip.right()


class DashboardDelegate(QStyledItemDelegate):
    """Two-line project cell, branch + chip Git cell, and chip status cells."""

    def paint(self, painter: QPainter, option: QStyleOptionViewItem, index):
        selected = bool(option.state & QStyle.State_Selected)
        painter.save()
        painter.fillRect(option.rect, QColor(theme.SELECT if selected else theme.SURFACE))
        if index.column() == 0 and selected:
            painter.fillRect(QRect(option.rect.left(), option.rect.top(), 3, option.rect.height()),
                             QColor(theme.LIME))
        painter.setPen(QColor(theme.BORDER))
        painter.drawLine(option.rect.bottomLeft(), option.rect.bottomRight())
        painter.restore()

        rect = option.rect.adjusted(12, 0, -8, 0)
        text = str(index.data(Qt.DisplayRole) or "")
        font = QFont(option.font)
        painter.save()
        if index.column() == 0:
            bold = QFont(font)
            bold.setWeight(QFont.DemiBold)
            subtitle = str(index.data(ROLE_SUBTITLE) or "")
            top = QRect(rect.left(), rect.top() + 6, rect.width(), rect.height() // 2 - 4)
            bottom = QRect(rect.left(), rect.center().y() + 1, rect.width(), rect.height() // 2 - 6)
            painter.setFont(bold)
            painter.setPen(QColor(theme.TEXT))
            painter.drawText(top, Qt.AlignLeft | Qt.AlignBottom,
                             painter.fontMetrics().elidedText(text, Qt.ElideRight, top.width()))
            small = QFont(font)
            small.setPointSizeF(max(7.5, font.pointSizeF() - 1))
            painter.setFont(small)
            painter.setPen(QColor(theme.MUTED))
            painter.drawText(bottom, Qt.AlignLeft | Qt.AlignTop,
                             painter.fontMetrics().elidedText(subtitle, Qt.ElideMiddle, bottom.width()))
        elif index.column() == 4 or index.data(ROLE_TONE) == PLAIN:
            painter.setFont(font)
            painter.setPen(QColor(theme.MUTED))
            painter.drawText(rect, Qt.AlignVCenter | Qt.AlignLeft, text)
        else:
            painter.setFont(font)
            left = rect
            branch = str(index.data(ROLE_BRANCH) or "")
            if index.column() == 1 and branch:
                metrics = painter.fontMetrics()
                branch_width = min(metrics.horizontalAdvance(branch) + 4, max(40, rect.width() // 2))
                painter.setPen(QColor(theme.TEXT))
                painter.drawText(QRect(rect.left(), rect.top(), branch_width, rect.height()),
                                 Qt.AlignVCenter | Qt.AlignLeft,
                                 metrics.elidedText(branch, Qt.ElideMiddle, branch_width))
                left = rect.adjusted(branch_width + 8, 0, 0, 0)
            paint_chip(painter, left, text, str(index.data(ROLE_TONE) or presentation.NEUTRAL), font)
        painter.restore()

    def sizeHint(self, option, index):  # noqa: N802
        size = super().sizeHint(option, index)
        return QSize(size.width() + 24, 50)


class BackendDialog(QDialog):
    def __init__(self, project, parent=None):
        super().__init__(parent)
        roots = backends.find_roots(project)
        if len(roots) > 1:
            raise backends.BackendError("Select a specific build root before editing its configuration.")
        self.root = roots[0] if roots else Path(project)
        self.path = self.root / backends.CONFIG
        self.setWindowTitle("Godot / custom build — DroidRun")
        self.resize(720, 500)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 18, 18, 18)
        layout.setSpacing(10)
        title = QLabel("Godot / custom build configuration")
        title.setObjectName("sectionTitle")
        layout.addWidget(title)
        help_text = QLabel("Godot is detected automatically; set its editor path or export preset here if needed. "
                           "A custom build runs <i>executable</i> with <i>arguments</i> in this folder and must "
                           "update <i>apk</i>. This file runs commands: review it before saving.")
        help_text.setWordWrap(True)
        help_text.setObjectName("muted")
        layout.addWidget(help_text)
        location = ElidedLabel(str(self.path))
        location.setObjectName("path")
        layout.addWidget(location)
        self.editor = QPlainTextEdit()
        self.editor.setAccessibleName("Build configuration JSON")
        default = {"version": 1, "backend": "godot", "apk": "build/android/app-debug.apk"}
        if not (self.root / "project.godot").is_file():
            default = {"version": 1, "backend": "custom", "executable": "flutter",
                       "arguments": ["build", "apk", "--debug"],
                       "apk": "build/app/outputs/flutter-apk/app-debug.apk"}
        self.editor.setPlainText(self.path.read_text(encoding="utf-8-sig") if self.path.exists()
                                 else json.dumps(default, indent=2))
        layout.addWidget(self.editor, 1)
        self.error = QLabel("")
        self.error.setWordWrap(True)
        self.error.setStyleSheet(f"color: {theme.TONES['error']};")
        self.error.hide()
        layout.addWidget(self.error)
        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Save).setObjectName("primary")
        buttons.accepted.connect(self.save)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def save(self):
        try:
            data = json.loads(self.editor.toPlainText())
            if not isinstance(data, dict) or data.get("version") != 1:
                raise ValueError("Expected a JSON object with \"version\": 1.")
            core.save_json(self.path, data)
            self.accept()
        except (ValueError, OSError) as exc:
            # Keep the dialog and the edited text open, with the problem next to the editor.
            self.error.setText(f"Not saved: {exc}")
            self.error.show()
            self.editor.setFocus()


class Signals(QObject):
    line = Signal(str)
    progress = Signal(object)
    done = Signal(object)
    failed = Signal(object)


class Worker(QRunnable):
    """Run fn(emit_line, emit_progress) on the thread pool."""

    def __init__(self, fn):
        super().__init__()
        self.fn = fn
        self.signals = Signals()

    @Slot()
    def run(self):
        try:
            self.signals.done.emit(self.fn(self.signals.line.emit, self.signals.progress.emit))
        except Exception as exc:  # reported in the operation panel
            self.signals.failed.emit((exc, traceback.format_exc()))


class ProjectPickerDialog(QDialog):
    """Choose which of the projects found beneath a folder to add."""

    def __init__(self, discovery: projects.Discovery, existing: set[str], parent=None):
        super().__init__(parent)
        root = Path(discovery.root)
        self.setWindowTitle("Add projects — DroidRun")
        self.setMinimumWidth(620)
        self.resize(680, 520)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 18, 20, 18)
        layout.setSpacing(8)
        title = QLabel(f"Add projects from {root.name or root}")
        title.setObjectName("projectName")
        path = ElidedLabel(display_path(str(root)))
        path.setObjectName("path")
        layout.addWidget(title)
        layout.addWidget(path)

        candidates = discovery.candidates
        new = [c for c in candidates if c.path not in existing]
        if candidates and candidates[0].outside:
            intro = ("There are no projects beneath this folder, but it is inside this project. "
                     "Add it instead?")
        elif not new:
            intro = f"All {len(candidates)} projects found here are already in DroidRun."
        else:
            count = len(candidates)
            intro = (f"Found {count} project{'s' if count != 1 else ''}. Choose the ones to add. "
                     "Unchecked ones may not build yet; the reason is shown under each.")
        if discovery.truncated:
            intro += (" The search stopped early because this folder is very large; choose a folder "
                      "closer to the projects to see everything.")
        self.intro = QLabel(intro)
        self.intro.setWordWrap(True)
        self.intro.setObjectName("muted")
        layout.addSpacing(4)
        layout.addWidget(self.intro)

        rows = QWidget()
        rows_layout = QVBoxLayout(rows)
        rows_layout.setContentsMargins(4, 4, 4, 4)
        rows_layout.setSpacing(10)
        self.boxes: list[tuple[QCheckBox, projects.Candidate]] = []
        for candidate in candidates:
            added = candidate.path in existing
            box = QCheckBox(Path(candidate.path).name)
            box.setStyleSheet("font-weight: 600;")
            box.setChecked(candidate.recommended and not added)
            box.setEnabled(not added)
            location = "this folder" if candidate.relative == "." else display_path(candidate.relative)
            detail_text = f"{candidate.kind}  ·  {location}"
            if added:
                detail_text += "  ·  already in DroidRun"
            elif candidate.note:
                detail_text += f"\n{candidate.note}"
            box.setToolTip(candidate.path)
            box.setAccessibleDescription(detail_text.replace("\n", ". "))
            detail = QLabel(detail_text)
            detail.setObjectName("muted")
            detail.setWordWrap(True)
            detail.setContentsMargins(26, 0, 0, 0)
            if candidate.note and not added:
                detail.setStyleSheet(f"color: {theme.TONES['warn']};")
            item = QVBoxLayout()
            item.setSpacing(1)
            item.addWidget(box)
            item.addWidget(detail)
            rows_layout.addLayout(item)
            box.toggled.connect(self._update_count)
            self.boxes.append((box, candidate))
        rows_layout.addStretch(1)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(rows)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setAccessibleName("Projects found")
        layout.addWidget(scroll, 1)

        buttons = QHBoxLayout()
        self.all_button = QPushButton("Select all")
        self.all_button.setObjectName("quiet")
        self.all_button.clicked.connect(lambda: self._set_all(True))
        self.none_button = QPushButton("Clear")
        self.none_button.setObjectName("quiet")
        self.none_button.clicked.connect(lambda: self._set_all(False))
        self.add_button = QPushButton("Add")
        self.add_button.setObjectName("primary")
        self.add_button.setDefault(True)
        self.add_button.clicked.connect(self.accept)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        for button in (self.all_button, self.none_button):
            buttons.addWidget(button)
        buttons.addStretch(1)
        buttons.addWidget(cancel)
        buttons.addWidget(self.add_button)
        layout.addLayout(buttons)
        multiple = sum(1 for box, _ in self.boxes if box.isEnabled()) > 1
        self.all_button.setVisible(multiple)
        self.none_button.setVisible(multiple)
        self._update_count()

    def _set_all(self, checked: bool) -> None:
        for box, _ in self.boxes:
            if box.isEnabled():
                box.setChecked(checked)

    def _update_count(self, *_):
        count = len(self.chosen())
        self.add_button.setText("Add project" if count == 1 else f"Add {count} projects")
        self.add_button.setEnabled(count > 0)

    def chosen(self) -> list[str]:
        return [candidate.path for box, candidate in self.boxes if box.isEnabled() and box.isChecked()]


class SettingsDialog(QDialog):
    def __init__(self, project: str, parent=None):
        super().__init__(parent)
        self.project = project
        self.setWindowTitle(f"{projects.display_name(project)} settings — DroidRun")
        self.setMinimumWidth(640)
        pref = core.load_preferences(project)

        self.gradle = QLineEdit(pref.gradle_task)
        self.gradle.setPlaceholderText("assembleDebug")
        self.apk = QLineEdit(pref.preferred_apk)
        self.apk.setPlaceholderText("Automatic: the only APK, or app-debug.apk")
        self.java = QLineEdit(pref.java_home)
        self.java.setPlaceholderText("From the environment (JAVA_HOME or java on PATH)")
        self.device = QLineEdit(pref.device_serial)
        self.device.setPlaceholderText("Automatic when exactly one device is connected")
        self.launch = QCheckBox("Launch the app after a successful install")
        self.launch.setChecked(pref.auto_launch)
        self.error = QLabel("")
        self.error.setWordWrap(True)
        self.error.setStyleSheet(f"color: {theme.TONES['error']};")
        self.error.hide()

        def with_button(field: QLineEdit, label: str, handler) -> QWidget:
            row = QWidget()
            box = QHBoxLayout(row)
            box.setContentsMargins(0, 0, 0, 0)
            box.addWidget(field, 1)
            button = QPushButton(label)
            button.clicked.connect(handler)
            box.addWidget(button)
            return row

        title = QLabel(projects.display_name(project))
        title.setObjectName("projectName")
        path = ElidedLabel(project)
        path.setObjectName("path")

        form = QFormLayout()
        form.setLabelAlignment(Qt.AlignRight | Qt.AlignVCenter)
        form.setHorizontalSpacing(14)
        form.setVerticalSpacing(10)
        form.addRow("Gradle task", self.gradle)
        form.addRow("Preferred APK", with_button(self.apk, "Browse…", self.browse_apk))
        form.addRow("JAVA_HOME", with_button(self.java, "Browse…", self.browse_java))
        form.addRow("Preferred device", with_button(self.device, "Detect…", self.detect))
        form.addRow("", self.launch)
        note = QLabel("Gradle task applies to Gradle projects only. Godot and custom builds use their own "
                      "configuration file.")
        note.setWordWrap(True)
        note.setObjectName("muted")
        form.addRow("", note)
        backend = QPushButton("Godot / custom build…")
        backend.clicked.connect(self.backend)
        form.addRow("Build configuration", backend)

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel | QDialogButtonBox.RestoreDefaults)
        buttons.button(QDialogButtonBox.Save).setObjectName("primary")
        buttons.button(QDialogButtonBox.RestoreDefaults).setText("Reset to defaults")
        buttons.button(QDialogButtonBox.RestoreDefaults).clicked.connect(self.reset_defaults)
        buttons.accepted.connect(self.save)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 18, 20, 18)
        layout.setSpacing(12)
        layout.addWidget(title)
        layout.addWidget(path)
        layout.addLayout(form)
        layout.addWidget(self.error)
        layout.addWidget(buttons)

    def show_error(self, message: str, field: QWidget | None = None) -> None:
        self.error.setText(message)
        self.error.show()
        if field is not None:
            field.setFocus()

    def browse_apk(self):
        path, _ = QFileDialog.getOpenFileName(self, "Choose preferred APK", self.project,
                                              "Android packages (*.apk);;All files (*)")
        if not path:
            return
        chosen = Path(path).resolve()
        root = Path(self.project).resolve()
        try:
            self.apk.setText(str(chosen.relative_to(root)))
        except ValueError:
            self.apk.setText(str(chosen))

    def browse_java(self):
        path = QFileDialog.getExistingDirectory(self, "Choose a JDK folder containing bin/java",
                                                self.java.text() or str(Path.home()))
        if path:
            self.java.setText(path)

    def detect(self):
        try:
            roots = backends.find_roots(self.project)
            root = roots[0] if len(roots) == 1 else Path(self.project)
            adb = core.resolve_adb(root)
            devices = [d for d in core.connected_devices(adb) if d.state == "device"]
        except Exception as exc:
            self.show_error(f"Device detection failed: {exc}", self.device)
            return
        if not devices:
            self.show_error("No authorised Android device is connected. Unlock it and accept the "
                            "USB debugging prompt, then try again.", self.device)
            return
        self.error.hide()
        if len(devices) == 1:
            self.device.setText(devices[0].serial)
            return
        labels = [f"{d.model}  [{d.serial}]" for d in devices]
        choice, ok = QInputDialog.getItem(self, "Choose preferred device",
                                          "Several devices are connected. Use:", labels, 0, False)
        if ok and choice in labels:
            self.device.setText(devices[labels.index(choice)].serial)

    def backend(self):
        try:
            BackendDialog(self.project, self).exec()
        except Exception as exc:
            self.show_error(f"Build configuration could not be opened: {exc}")

    def reset_defaults(self):
        defaults = core.Preferences()
        self.gradle.setText(defaults.gradle_task)
        self.apk.clear()
        self.java.clear()
        self.device.clear()
        self.launch.setChecked(defaults.auto_launch)

    def save(self):
        java_home = self.java.text().strip()
        if java_home and not (Path(java_home).expanduser() / "bin" / "java").is_file():
            self.show_error("JAVA_HOME must be a JDK folder that contains bin/java.", self.java)
            return
        core.save_preferences(self.project, core.Preferences(
            gradle_task=self.gradle.text().strip() or "assembleDebug",
            preferred_apk=self.apk.text().strip(),
            java_home=java_home,
            device_serial=self.device.text().strip(),
            auto_launch=self.launch.isChecked(),
        ))
        self.accept()


def make_status_table(columns: list[str]) -> QTableWidget:
    table = QTableWidget(0, len(columns))
    table.setHorizontalHeaderLabels(columns)
    table.setItemDelegate(DashboardDelegate(table))
    table.verticalHeader().setVisible(False)
    table.verticalHeader().setDefaultSectionSize(50)
    table.setShowGrid(False)
    table.setSelectionBehavior(QAbstractItemView.SelectRows)
    table.setSelectionMode(QAbstractItemView.SingleSelection)
    table.setEditTriggers(QAbstractItemView.NoEditTriggers)
    table.setWordWrap(False)
    table.setMouseTracking(True)
    header = table.horizontalHeader()
    header.setDefaultAlignment(Qt.AlignLeft | Qt.AlignVCenter)
    header.setHighlightSections(False)
    return table


class MainWindow(QMainWindow):
    def __init__(self, initial_project: str | None = None):
        super().__init__()
        self.initial_project = initial_project
        self.setWindowTitle("DroidRun")
        self.setWindowIcon(QIcon(str(ICON_PATH)))
        self.resize(1180, 780)
        self.setMinimumSize(900, 640)
        self.setStyleSheet(theme.STYLE_SHEET)
        self.pool = QThreadPool.globalInstance()
        self.busy = False
        self.refreshing = False
        self.stop_refresh = False
        self.controller = core.ProcessController()
        self.statuses: dict[str, core.ProjectStatus] = {}
        self.checked: dict[str, str] = {}
        self.operation_label = ""
        self.operation_started = 0.0
        self.workers: list[Worker] = []

        root = QWidget()
        self.setCentralWidget(root)
        outer = QVBoxLayout(root)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)
        outer.addWidget(self._build_header())

        body = QWidget()
        body_layout = QVBoxLayout(body)
        body_layout.setContentsMargins(18, 14, 18, 16)
        body_layout.setSpacing(12)
        outer.addWidget(body, 1)

        projects_row = QHBoxLayout()
        self.projects_title = QLabel("Projects")
        self.projects_title.setObjectName("sectionTitle")
        projects_row.addWidget(self.projects_title)
        projects_row.addStretch(1)
        self.add_button = QPushButton("Add project…")
        self.add_button.setObjectName("quiet")
        self.add_button.clicked.connect(self.add_project)
        projects_row.addWidget(self.add_button)
        body_layout.addLayout(projects_row)

        self.table = make_status_table(COLUMNS)
        self.table.setAccessibleName("Projects")
        # Several projects can be selected to refresh just those (Ctrl/Shift+click, Ctrl+A).
        self.table.setSelectionMode(QAbstractItemView.ExtendedSelection)
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(0, QHeaderView.Stretch)
        header.setSectionResizeMode(4, QHeaderView.Fixed)
        self.table.setColumnWidth(1, 250)
        self.table.setColumnWidth(2, 170)
        self.table.setColumnWidth(3, 150)
        self.table.setColumnWidth(4, 96)
        self.table.doubleClicked.connect(lambda _: self.sync_run())
        self.table.itemSelectionChanged.connect(self.update_details)
        QShortcut(QKeySequence(Qt.Key_Return), self.table, self.sync_run, context=Qt.WidgetShortcut)
        QShortcut(QKeySequence(Qt.Key_Enter), self.table, self.sync_run, context=Qt.WidgetShortcut)
        QShortcut(QKeySequence(Qt.Key_Escape), self.table, self.table.clearSelection, context=Qt.WidgetShortcut)
        QShortcut(QKeySequence(Qt.Key_F2), self.table, self.rename_project, context=Qt.WidgetShortcut)

        self.empty = self._build_empty_state()
        self.project_stack = QStackedWidget()
        self.project_stack.addWidget(self.table)
        self.project_stack.addWidget(self.empty)
        body_layout.addWidget(self.project_stack, 3)

        self.details = self._build_details()
        body_layout.addWidget(self.details)
        self.operation = self._build_operation_panel()
        body_layout.addWidget(self.operation, 2)

        QShortcut(QKeySequence("Ctrl+R"), self, self.refresh)
        QShortcut(QKeySequence("F5"), self, self.refresh)

        self.elapsed_timer = QTimer(self)
        self.elapsed_timer.setInterval(1000)
        self.elapsed_timer.timeout.connect(self._tick_elapsed)

        if self.initial_project:
            core.remember_project(self.initial_project)
        self.reload_rows()
        self.select_project(self.initial_project)
        self.set_operation_state("idle", "Ready", "Output from the next operation appears here.")
        self.update_controls()
        self.table.setFocus()
        if not self.initial_project:
            self.refresh()

    # ----- construction ---------------------------------------------------------------
    def _build_header(self) -> QFrame:
        header = QFrame()
        header.setObjectName("header")
        row = QHBoxLayout(header)
        row.setContentsMargins(18, 12, 18, 12)
        row.setSpacing(10)
        icon = QLabel()
        icon.setPixmap(QPixmap(str(ICON_PATH)).scaled(34, 34, Qt.KeepAspectRatio, Qt.SmoothTransformation))
        icon.setAccessibleName("DroidRun")
        row.addWidget(icon)
        names = QVBoxLayout()
        names.setSpacing(0)
        app_name = QLabel("DroidRun")
        app_name.setObjectName("appName")
        subtitle = QLabel("Build, install, and launch Android projects")
        subtitle.setObjectName("muted")
        names.addWidget(app_name)
        names.addWidget(subtitle)
        row.addLayout(names)
        row.addStretch(1)
        self.refresh_state = QLabel("Status not checked")
        self.refresh_state.setObjectName("refreshState")
        self.refresh_state.setAccessibleName("Status refresh")
        row.addWidget(self.refresh_state)
        self.refresh_progress = QProgressBar()
        self.refresh_progress.setTextVisible(False)
        self.refresh_progress.setFixedWidth(90)
        self.refresh_progress.hide()
        row.addWidget(self.refresh_progress)
        self.scan_button = QPushButton("Scan device…")
        self.scan_button.clicked.connect(self.scan_device)
        self.reports_button = QPushButton("Reports…")
        self.reports_button.clicked.connect(self.reports)
        self.refresh_button = QPushButton("Refresh All")
        self.refresh_button.setToolTip("Fetch Git remotes and recheck builds and the device for the selected "
                                       "projects, or every project when none is selected (Ctrl+R). "
                                       "Esc clears the selection.")
        self.refresh_button.clicked.connect(self.refresh_or_stop)
        for button in (self.scan_button, self.reports_button, self.refresh_button):
            row.addWidget(button)
        return header

    def _build_empty_state(self) -> QFrame:
        empty = QFrame()
        empty.setObjectName("card")
        box = QVBoxLayout(empty)
        box.setAlignment(Qt.AlignCenter)
        title = QLabel("No projects yet")
        title.setObjectName("emptyTitle")
        title.setAlignment(Qt.AlignCenter)
        text = QLabel("Add an Android repository or project folder. DroidRun remembers it and checks its "
                      "Git, build, and device state.")
        text.setObjectName("muted")
        text.setWordWrap(True)
        text.setAlignment(Qt.AlignCenter)
        text.setFixedWidth(440)
        add = QPushButton("Add project…")
        add.setObjectName("primary")
        add.clicked.connect(self.add_project)
        self.empty_add_button = add
        box.addWidget(title)
        box.addWidget(text, 0, Qt.AlignCenter)
        box.addSpacing(6)
        box.addWidget(add, 0, Qt.AlignCenter)
        return empty

    def _build_details(self) -> QFrame:
        card = QFrame()
        card.setObjectName("card")
        grid = QHBoxLayout(card)
        grid.setContentsMargins(16, 14, 16, 14)
        grid.setSpacing(18)

        info = QVBoxLayout()
        info.setSpacing(3)
        self.detail_name = QLabel("No project selected")
        self.detail_name.setObjectName("projectName")
        self.detail_path = ElidedLabel("")
        self.detail_path.setObjectName("path")
        self.detail_plan = QLabel("")
        self.detail_plan.setWordWrap(True)
        self.detail_plan.setAccessibleName("Sync & Run preview")
        self.detail_fix = QLabel("")
        self.detail_fix.setObjectName("muted")
        self.detail_fix.setWordWrap(True)
        self.detail_settings = QLabel("")
        self.detail_settings.setObjectName("settingsSummary")
        self.detail_settings.setWordWrap(True)
        for widget in (self.detail_name, self.detail_path):
            info.addWidget(widget)
        info.addSpacing(6)
        for widget in (self.detail_plan, self.detail_fix, self.detail_settings):
            info.addWidget(widget)
        grid.addLayout(info, 1)

        actions = QVBoxLayout()
        actions.setSpacing(8)
        primary_row = QHBoxLayout()
        primary_row.setSpacing(8)
        self.build_button = QPushButton("Build && Install")
        self.build_button.setToolTip("Always build, then install and launch according to settings")
        self.build_button.clicked.connect(self.build_install)
        self.sync_button = QPushButton("Sync && Run")
        self.sync_button.setObjectName("primary")
        self.sync_button.setToolTip("Pull, build, and install only what is needed, then launch (Enter)")
        self.sync_button.clicked.connect(self.sync_run)
        primary_row.addStretch(1)
        primary_row.addWidget(self.build_button)
        primary_row.addWidget(self.sync_button)
        secondary_row = QHBoxLayout()
        secondary_row.setSpacing(4)
        self.pull_button = QPushButton("Git pull")
        self.pull_button.setToolTip("git pull --ff-only; stops on local changes or divergence")
        self.pull_button.clicked.connect(self.git_pull)
        self.settings_button = QPushButton("Settings…")
        self.settings_button.clicked.connect(self.settings)
        self.rename_button = QPushButton("Rename…")
        self.rename_button.setToolTip("Change the name shown in DroidRun (F2)")
        self.rename_button.clicked.connect(self.rename_project)
        self.remove_button = QPushButton("Remove…")
        self.remove_button.setToolTip("Forget this project; files and settings are kept")
        self.remove_button.clicked.connect(self.remove_project)
        secondary_row.addStretch(1)
        for button in (self.pull_button, self.rename_button, self.settings_button, self.remove_button):
            button.setObjectName("quiet")
            secondary_row.addWidget(button)
        actions.addLayout(primary_row)
        actions.addLayout(secondary_row)
        actions.addStretch(1)
        grid.addLayout(actions)
        return card

    def _build_operation_panel(self) -> QFrame:
        card = QFrame()
        card.setObjectName("card")
        box = QVBoxLayout(card)
        box.setContentsMargins(16, 12, 16, 14)
        box.setSpacing(8)
        row = QHBoxLayout()
        row.setSpacing(10)
        self.op_badge = QLabel("")
        self.op_badge.setAlignment(Qt.AlignCenter)
        self.op_badge.setMinimumWidth(80)
        self.op_badge.setFixedHeight(24)
        self.op_title = QLabel("")
        self.op_title.setObjectName("sectionTitle")
        self.op_title.setAccessibleName("Operation status")
        self.op_detail = ElidedLabel("")
        self.op_detail.setObjectName("muted")
        row.addWidget(self.op_badge)
        row.addWidget(self.op_title)
        row.addWidget(self.op_detail, 1)
        self.copy_button = QPushButton("Copy output")
        self.copy_button.setObjectName("quiet")
        self.copy_button.clicked.connect(self.copy_output)
        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.clicked.connect(self.cancel_operation)
        row.addWidget(self.copy_button)
        row.addWidget(self.cancel_button)
        box.addLayout(row)
        self.op_progress = QProgressBar()
        self.op_progress.setRange(0, 0)
        self.op_progress.setTextVisible(False)
        self.op_progress.hide()
        box.addWidget(self.op_progress)
        self.output = QPlainTextEdit()
        self.output.setReadOnly(True)
        self.output.setAccessibleName("Operation output")
        self.output.setLineWrapMode(QPlainTextEdit.NoWrap)
        self.output.document().setMaximumBlockCount(4000)
        box.addWidget(self.output, 1)
        return card

    # ----- projects -------------------------------------------------------------------
    def selected_projects(self) -> list[str]:
        """Selected project paths, in list order."""
        rows = sorted(index.row() for index in self.table.selectionModel().selectedRows())
        return [self.table.item(row, 0).data(ROLE_PATH) for row in rows if self.table.item(row, 0)]

    def selected_project(self) -> str | None:
        """The selected project when exactly one is selected; actions need exactly one."""
        selected = self.selected_projects()
        return selected[0] if len(selected) == 1 else None

    def select_project(self, project: str | None):
        self.select_projects([project] if project else [])

    def select_projects(self, chosen: list[str]):
        wanted = {str(Path(p).expanduser().resolve()) for p in chosen}
        if not wanted:
            return
        self.table.clearSelection()
        first = None
        for row in range(self.table.rowCount()):
            item = self.table.item(row, 0)
            if item and item.data(ROLE_PATH) in wanted:
                self.table.selectionModel().select(
                    self.table.model().index(row, 0),
                    QItemSelectionModel.Select | QItemSelectionModel.Rows)
                first = first or item
        if first is not None:
            self.table.setCurrentItem(first, QItemSelectionModel.NoUpdate)
            self.table.scrollToItem(first)

    def _set_cell(self, row: int, column: int, text: str, tone_name: str = presentation.NEUTRAL,
                  tooltip: str = "", branch: str = "") -> None:
        item = self.table.item(row, column)
        if item is None:
            item = QTableWidgetItem()
            self.table.setItem(row, column, item)
        item.setText(text)
        item.setData(ROLE_TONE, tone_name)
        item.setData(ROLE_BRANCH, branch)
        item.setToolTip(tooltip)

    def _apply_status(self, row: int, project: str) -> None:
        status = self.statuses.get(project)
        checked = self.checked.get(project, PENDING)
        if status is None:
            for column in (1, 2, 3):
                self._set_cell(row, column, checked if checked in (PENDING, "Checking…") else "Unknown")
        else:
            tip = f"Git: {status.git_display}\nLocal build: {status.build}\nDevice: {status.device}"
            if status.detail:
                tip += f"\n\n{status.detail}"
            self._set_cell(row, 1, status.git, presentation.tone(status.git), tip, status.branch)
            self._set_cell(row, 2, status.build, presentation.tone(status.build), tip)
            self._set_cell(row, 3, status.device, presentation.tone(status.device), tip)
        self._set_cell(row, 4, checked)

    def reload_rows(self):
        selected = self.selected_projects()
        saved = core.load_projects()
        names = projects.load_names()
        self.table.setRowCount(len(saved))
        for row, project in enumerate(saved):
            item = QTableWidgetItem(projects.display_name(project, names))
            item.setToolTip(project)
            item.setData(ROLE_PATH, project)
            item.setData(ROLE_SUBTITLE, display_path(project))
            self.table.setItem(row, 0, item)
            self._apply_status(row, project)
        self.projects_title.setText(f"Projects ({len(saved)})" if saved else "Projects")
        self.project_stack.setCurrentWidget(self.table if saved else self.empty)
        # Nothing is selected by default, so Refresh All means every project.
        self.select_projects(selected)
        self.update_details()

    def update_details(self):
        selected = self.selected_projects()
        project = selected[0] if len(selected) == 1 else None
        if not project:
            names = projects.load_names()
            if selected:
                self.detail_name.setText(f"{len(selected)} projects selected")
                self.detail_path.setText(", ".join(projects.display_name(p, names) for p in selected))
                self.detail_plan.setText("Refresh checks only these projects. Select one project to build, "
                                         "install, rename, or change its settings.")
            else:
                self.detail_name.setText("No project selected")
                self.detail_path.setText("")
                self.detail_plan.setText("Select a project to build, install, and run it. With none selected, "
                                         "Refresh checks every project." if self.table.rowCount()
                                         else "Add a project to build, install, and run it.")
            self.detail_plan.setStyleSheet(f"color: {theme.MUTED};")
            self.detail_fix.hide()
            self.detail_settings.setText("")
            self.update_controls()
            return
        pref = core.load_preferences(project)
        self.detail_name.setText(projects.display_name(project))
        self.detail_path.setText(display_path(project))
        status = self.statuses.get(project)
        if status is None:
            preview = presentation.sync_preview("", "", "", pref.auto_launch)
        else:
            preview = presentation.sync_preview(status.git, status.build, status.device, pref.auto_launch)
        color = theme.TONES["ok"] if preview.ready else (
            theme.MUTED if status is None else theme.TONES["warn"])
        marker = "▶" if preview.ready else ("…" if status is None else "!")
        self.detail_plan.setText(f"{marker}  {preview.headline}")
        self.detail_plan.setStyleSheet(f"color: {color}; font-weight: 600;")
        self.detail_fix.setText(preview.fix)
        self.detail_fix.setVisible(bool(preview.fix))
        apk = pref.preferred_apk or "automatic"
        java = pref.java_home or "from environment"
        device = pref.device_serial or "automatic"
        self.detail_settings.setText(
            f"Task {pref.gradle_task}  ·  APK {apk}  ·  JDK {java}  ·  Device {device}  ·  "
            f"Auto-launch {'on' if pref.auto_launch else 'off'}")
        self.update_controls()

    def update_controls(self):
        has_project = self.selected_project() is not None
        idle = not self.busy and not self.refreshing
        for button in (self.sync_button, self.build_button, self.pull_button, self.rename_button,
                       self.settings_button, self.remove_button):
            button.setEnabled(has_project and idle)
        self.add_button.setEnabled(idle)
        self.empty_add_button.setEnabled(idle)
        self.scan_button.setEnabled(idle and self.table.rowCount() > 0)
        self.refresh_button.setEnabled(not self.busy and self.table.rowCount() > 0)
        self.refresh_button.setText("Stop refresh" if self.refreshing else
                                    projects.refresh_label(len(self.selected_projects())))
        self.table.setEnabled(not self.busy)
        self.copy_button.setEnabled(bool(self.output.toPlainText()))

    # ----- operation panel ------------------------------------------------------------
    def set_operation_state(self, state: str, title: str, detail: str = "") -> None:
        tones = {"idle": "neutral", "running": "action", "success": "ok", "failed": "error", "cancelled": "warn"}
        words = {"idle": "Idle", "running": "Running", "success": "Done", "failed": "Failed",
                 "cancelled": "Cancelled"}
        fg, bg = theme.chip_colors(tones[state])
        self.op_badge.setText(words[state])
        self.op_badge.setStyleSheet(f"background: {bg}; color: {fg}; border-radius: 11px; "
                                    f"padding: 0 10px; font-weight: 600;")
        self.op_title.setText(title)
        self.op_detail.setText(detail)
        self.op_progress.setVisible(state == "running")
        self.cancel_button.setVisible(state == "running")
        self.operation_state = state

    def _tick_elapsed(self):
        if self.busy:
            self.op_detail.setText(f"{self._elapsed()} elapsed")

    def _elapsed(self) -> str:
        seconds = int(time.monotonic() - self.operation_started)
        return f"{seconds // 60}:{seconds % 60:02d}"

    def append(self, line: str):
        self.output.appendPlainText(line)
        self.copy_button.setEnabled(True)

    def _launch(self, fn, done=None, failed=None, progress=None):
        worker = Worker(fn)
        self.workers.append(worker)
        worker.setAutoDelete(False)
        worker.signals.line.connect(self.append)
        if progress:
            worker.signals.progress.connect(progress)

        def finish(handler, value):
            if worker in self.workers:
                self.workers.remove(worker)
            if handler:
                handler(value)

        worker.signals.done.connect(lambda value: finish(done, value))
        worker.signals.failed.connect(lambda value: finish(failed, value))
        self.pool.start(worker)

    def start(self, label: str, fn, done=None):
        if self.busy or self.refreshing:
            return
        project = self.selected_project()
        self.busy = True
        self.operation_label = label
        self.operation_started = time.monotonic()
        self.controller.reset()
        self.cancel_button.setEnabled(True)
        self.output.clear()
        self.set_operation_state("running", label, "0:00 elapsed")
        self.elapsed_timer.start()
        self.setWindowTitle(f"{label} — DroidRun")
        self.update_controls()

        def finished(value):
            self._finish_operation()
            self.set_operation_state("success", f"{label} finished", f"in {self._elapsed()}")
            self.append(f"\n{label} finished successfully.")
            if done:
                done(value)
            self.refresh(fetch=False, only=project)

        def failed(error):
            exc, details = error
            self._finish_operation()
            message = str(exc) or exc.__class__.__name__
            if isinstance(exc, core.OperationCancelled):
                self.set_operation_state("cancelled", f"{label} cancelled", f"after {self._elapsed()}")
                self.append(f"\n{label} cancelled.")
            else:
                first = message.splitlines()[0]
                self.set_operation_state("failed", f"{label} failed", first)
                self.append(f"\nFAILED: {message}")
                if not isinstance(exc, backends.BackendError):
                    self.append(details)
            self.refresh(fetch=False, only=project)

        self._launch(fn, finished, failed)

    def _finish_operation(self):
        self.busy = False
        self.elapsed_timer.stop()
        self.setWindowTitle("DroidRun")
        self.update_controls()

    def cancel_operation(self):
        if not self.busy:
            return
        self.cancel_button.setEnabled(False)
        self.op_detail.setText("Stopping the process group…")
        self.controller.cancel()

    def copy_output(self):
        QApplication.clipboard().setText(self.output.toPlainText())
        self.op_detail.setText("Output copied to the clipboard.")

    # ----- status refresh -------------------------------------------------------------
    def refresh_or_stop(self):
        if self.refreshing:
            self.stop_refresh = True
            self.refresh_state.setText("Stopping after the current project…")
            self.refresh_button.setEnabled(False)
        else:
            # The selected projects, or every project when none is selected.
            self.refresh(targets=projects.refresh_targets(core.load_projects(), self.selected_projects()))

    def refresh(self, fetch: bool = True, only: str | None = None, targets: list[str] | None = None):
        saved = core.load_projects()
        if only:
            targets = [only]
        projects_to_check = [p for p in saved if targets is None or p in targets]
        self._refresh(projects_to_check, fetch, len(projects_to_check) == len(saved))

    def _refresh(self, to_check: list[str], fetch: bool, everything: bool):
        if not to_check or self.busy or self.refreshing:
            return
        self.refreshing = True
        self.stop_refresh = False
        for project in to_check:
            self.checked[project] = PENDING
        for row in range(self.table.rowCount()):
            project = self.table.item(row, 0).data(ROLE_PATH)
            if project in to_check:
                self._set_cell(row, 4, PENDING)
        self.refresh_progress.setRange(0, len(to_check))
        self.refresh_progress.setValue(0)
        self.refresh_progress.show()
        self.update_controls()

        def task(_emit, progress):
            for index, project in enumerate(to_check, 1):
                if self.stop_refresh:
                    break
                progress(("start", project, index, len(to_check)))
                try:
                    result = core.project_status(project, fetch=fetch)
                except Exception as exc:  # keep checking the remaining projects
                    result = core.ProjectStatus("Unknown", "Unknown", "Unknown", str(exc))
                progress(("done", project, index, len(to_check), result))
            return len(to_check)

        def on_progress(event):
            kind, project, index, total = event[:4]
            row = self._row_for(project)
            if kind == "start":
                self.refresh_state.setText(f"Checking {index}/{total}: {self._name(project)}")
                self.checked[project] = "Checking…"
            else:
                self.statuses[project] = event[4]
                self.checked[project] = time.strftime("%H:%M:%S")
                self.refresh_progress.setValue(index)
            if row is not None:
                self._apply_status(row, project)
            if project == self.selected_project():
                self.update_details()

        def finish(_value):
            stopped = self.stop_refresh
            self.refreshing = False
            self.stop_refresh = False
            self.refresh_progress.hide()
            for project, value in list(self.checked.items()):
                if value in (PENDING, "Checking…"):
                    self.checked[project] = "Not checked"
                    row = self._row_for(project)
                    if row is not None:
                        self._apply_status(row, project)
            stamp = time.strftime("%H:%M")
            scope = "" if everything else (f" {self._name(to_check[0])}" if len(to_check) == 1
                                           else f" {len(to_check)} to_check")
            self.refresh_state.setText(f"Refresh stopped at {stamp}" if stopped else
                                       f"{'Checked' if fetch else 'Rechecked'}{scope} at {stamp}")
            self.update_controls()
            self.update_details()

        self._launch(task, finish, lambda error: finish(None), on_progress)

    def _name(self, project: str) -> str:
        return projects.display_name(project)

    def _row_for(self, project: str) -> int | None:
        for row in range(self.table.rowCount()):
            item = self.table.item(row, 0)
            if item and item.data(ROLE_PATH) == project:
                return row
        return None

    # ----- actions --------------------------------------------------------------------
    def require_project(self) -> str | None:
        return self.selected_project()

    def sync_run(self):
        project = self.require_project()
        if not project:
            return
        self.start("Sync & Run",
                   lambda emit, _p: core.build_install(project, sync=True, force_build=False,
                                                       stream=emit, controller=self.controller))

    def build_install(self):
        project = self.require_project()
        if not project:
            return
        self.start("Build & Install",
                   lambda emit, _p: core.build_install(project, sync=False, force_build=True,
                                                       stream=emit, controller=self.controller))

    def git_pull(self):
        project = self.require_project()
        if not project:
            return
        self.start("Git pull", lambda emit, _p: core.safe_git_pull(project, emit, self.controller))

    def scan_device(self):
        projects = core.load_projects()
        if not projects or self.busy or self.refreshing:
            return
        self.busy = True
        self.update_controls()
        self.refresh_state.setText("Scanning the device…")

        def task(_emit, _progress):
            return [(project, core.project_status(project, fetch=False)) for project in projects]

        def done(results):
            self.busy = False
            self.refresh_state.setText(f"Device scanned at {time.strftime('%H:%M')}")
            for project, status in results:
                self.statuses[project] = status
                self.checked[project] = time.strftime("%H:%M:%S")
            self.reload_rows()
            self.update_controls()
            ScanDialog(results, self).exec()

        def failed(error):
            self.busy = False
            self.refresh_state.setText(f"Device scan failed: {error[0]}")
            self.update_controls()

        self._launch(task, done, failed)

    def reports(self):
        log_dir = core.state_root() / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(log_dir)))

    def settings(self):
        project = self.require_project()
        if not project:
            return
        if SettingsDialog(project, self).exec():
            self.update_details()
            self.refresh(fetch=False, only=project)

    def add_project(self):
        path = QFileDialog.getExistingDirectory(self, "Choose a repository or project folder")
        if not path:
            return
        QApplication.setOverrideCursor(Qt.WaitCursor)
        try:
            found = projects.discover(path)
        finally:
            QApplication.restoreOverrideCursor()
        chosen = self.choose_projects(found)
        if not chosen:
            return
        for project in reversed(chosen):
            core.remember_project(project)
        self.reload_rows()
        self.select_projects(chosen)
        self.refresh(targets=chosen)

    def choose_projects(self, found: projects.Discovery) -> list[str]:
        """Ask which discovered projects to add; returns the paths to add."""
        existing = set(core.load_projects())
        candidates = found.candidates
        if not candidates:
            answer = QMessageBox.question(
                self, "No projects found",
                f"No Android projects were found in {display_path(found.root)}.\n\nDroidRun looks up to "
                f"{projects.DISCOVERY_DEPTH} folders deep for gradlew, project.godot, or "
                f"{backends.CONFIG}. Add this folder anyway? You can set up a custom build for it "
                "later in Settings.",
                QMessageBox.Yes | QMessageBox.Cancel, QMessageBox.Cancel)
            return [found.root] if answer == QMessageBox.Yes else []
        only = candidates[0]
        if (len(candidates) == 1 and only.relative == "." and only.path not in existing
                and only.recommended):
            return [only.path]  # The chosen folder is the project; nothing to choose.
        dialog = ProjectPickerDialog(found, existing, self)
        return dialog.chosen() if dialog.exec() else []

    def rename_project(self):
        project = self.selected_project()
        if not project or self.busy or self.refreshing:
            return
        folder = Path(project).name
        current = projects.display_name(project)
        name, ok = QInputDialog.getText(
            self, "Rename project",
            f"Name shown in DroidRun for {display_path(project)}.\n"
            f"Leave it empty to use the folder name ({folder}). The folder itself is not renamed.",
            QLineEdit.Normal, current)
        if not ok:
            return
        projects.set_name(project, name)
        self.reload_rows()
        self.select_project(project)

    def remove_project(self):
        project = self.require_project()
        if not project:
            return
        answer = QMessageBox.question(
            self, "Remove project",
            f"Remove {projects.display_name(project)} from DroidRun?\n\nThe folder, its files, and its saved "
            "settings are not changed. You can add it again later.",
            QMessageBox.Yes | QMessageBox.Cancel, QMessageBox.Cancel)
        if answer != QMessageBox.Yes:
            return
        core.remove_project(project)
        self.statuses.pop(project, None)
        self.checked.pop(project, None)
        self.reload_rows()

    def closeEvent(self, event):  # noqa: N802
        if self.busy and getattr(self, "operation_state", "") == "running":
            answer = QMessageBox.warning(
                self, "DroidRun", f"{self.operation_label} is still running. Cancel it and quit?",
                QMessageBox.Yes | QMessageBox.No, QMessageBox.No)
            if answer != QMessageBox.Yes:
                event.ignore()
                return
            self.controller.cancel()
        self.stop_refresh = True
        super().closeEvent(event)


class ScanDialog(QDialog):
    def __init__(self, results, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Device scan — DroidRun")
        self.resize(900, 420)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 16, 18, 16)
        layout.setSpacing(10)
        title = QLabel("Device scan")
        title.setObjectName("sectionTitle")
        hint = QLabel("Read-only comparison of each project's local APK with the installed app. "
                      "Same and Different are exact SHA-256 comparisons. Nothing was built or installed.")
        hint.setObjectName("muted")
        hint.setWordWrap(True)
        layout.addWidget(title)
        layout.addWidget(hint)
        table = make_status_table(["Project", "Device", "Local build", "Detail"])
        table.setAccessibleName("Device scan results")
        table.horizontalHeader().setSectionResizeMode(3, QHeaderView.Stretch)
        table.setColumnWidth(0, 220)
        table.setColumnWidth(1, 160)
        table.setColumnWidth(2, 190)
        table.setRowCount(len(results))
        for row, (project, status) in enumerate(results):
            name = QTableWidgetItem(projects.display_name(project))
            name.setData(ROLE_SUBTITLE, project)
            table.setItem(row, 0, name)
            for column, value in ((1, status.device), (2, status.build)):
                item = QTableWidgetItem(value)
                item.setData(ROLE_TONE, presentation.tone(value))
                table.setItem(row, column, item)
            detail = QTableWidgetItem((status.detail or "").replace("\n", "  ·  "))
            detail.setToolTip(status.detail or "")
            detail.setData(ROLE_TONE, PLAIN)
            table.setItem(row, 3, detail)
        layout.addWidget(table, 1)
        buttons = QDialogButtonBox(QDialogButtonBox.Close)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)


def main() -> int:
    initial_project = None
    for arg in sys.argv[1:]:
        candidate = Path(arg).expanduser()
        if candidate.is_dir():
            initial_project = str(candidate.resolve())
            break

    app = QApplication(sys.argv)
    app.setApplicationName("DroidRun")
    app.setWindowIcon(QIcon(str(ICON_PATH)))
    win = MainWindow(initial_project=initial_project)
    win.show()
    if initial_project:
        QTimer.singleShot(0, win.build_install)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
