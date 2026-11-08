"""DroidRun dark theme: palette and Qt style sheet.

The palette is shared with the Windows dashboard (tools/DroidRun/DroidRunTheme.ps1).
Text colours are at least 4.5:1 against every surface they are drawn on; status
chips draw their tinted background against SURFACE, never the selection colour.
"""
from __future__ import annotations

BG = "#0E1726"
SURFACE = "#142238"
RAISED = "#1B2C46"
SELECT = "#22395C"
BORDER = "#2A3D5C"
TEXT = "#E8EEF6"
MUTED = "#9FB0C8"
LIME = "#B8F526"
LIME_HOVER = "#CCFF4D"
LIME_PRESSED = "#A3DB1F"
ON_LIME = "#142238"

TONES = {
    "ok": "#5EE0A0",
    "action": "#7CC4FF",
    "warn": "#FFC857",
    "error": "#FF8A80",
    "neutral": "#9FB0C8",
}
CHIP_ALPHA = 0.16


def mix(foreground: str, background: str, alpha: float) -> str:
    """Blend two #RRGGBB colours; used for opaque chip backgrounds."""
    fg = [int(foreground[i:i + 2], 16) for i in (1, 3, 5)]
    bg = [int(background[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(f * alpha + b * (1 - alpha)):02X}" for f, b in zip(fg, bg))


def chip_colors(tone_name: str) -> tuple[str, str]:
    """Return (text, background) for a status chip."""
    text = TONES.get(tone_name, TONES["neutral"])
    return text, mix(text, SURFACE, CHIP_ALPHA)


STYLE_SHEET = f"""
QWidget {{ background: {BG}; color: {TEXT}; font-size: 10pt; }}
QMainWindow, QDialog {{ background: {BG}; }}
QToolTip {{ background: {RAISED}; color: {TEXT}; border: 1px solid {BORDER}; padding: 6px; }}

QFrame#header {{ background: {SURFACE}; border-bottom: 1px solid {BORDER}; }}
QFrame#header QLabel, QFrame#card QLabel {{ background: transparent; }}
QLabel#appName {{ font-size: 15pt; font-weight: 600; }}
QLabel#muted, QLabel#path, QLabel#settingsSummary, QLabel#refreshState {{ color: {MUTED}; }}
QLabel#sectionTitle {{ font-size: 11pt; font-weight: 600; }}
QLabel#projectName {{ font-size: 13pt; font-weight: 600; }}
QLabel#emptyTitle {{ font-size: 13pt; font-weight: 600; }}

QFrame#card {{ background: {SURFACE}; border: 1px solid {BORDER}; border-radius: 8px; }}

QPushButton {{
    background: {RAISED}; color: {TEXT}; border: 1px solid {BORDER};
    border-radius: 6px; padding: 6px 14px; min-height: 20px;
}}
QPushButton:hover {{ background: {SELECT}; border-color: #3A5480; }}
QPushButton:pressed {{ background: {BORDER}; }}
QPushButton:focus {{ border: 2px solid {LIME}; padding: 5px 13px; }}
QPushButton:disabled {{ background: {SURFACE}; color: #7D8DA6; border-color: {RAISED}; }}
QPushButton#primary {{
    background: {LIME}; color: {ON_LIME}; border: 1px solid {LIME}; font-weight: 600;
    padding: 8px 20px;
}}
QPushButton#primary:hover {{ background: {LIME_HOVER}; border-color: {LIME_HOVER}; }}
QPushButton#primary:pressed {{ background: {LIME_PRESSED}; }}
QPushButton#primary:focus {{ border: 2px solid {TEXT}; padding: 7px 19px; }}
QPushButton#primary:disabled {{ background: #3C4A2A; color: #A9B88F; border-color: #3C4A2A; }}
QPushButton#quiet {{ background: transparent; border-color: transparent; }}
QPushButton#quiet:hover {{ background: {RAISED}; border-color: {BORDER}; }}
QPushButton#quiet:focus {{ border: 2px solid {LIME}; }}
QPushButton#quiet:disabled {{ background: transparent; border-color: transparent; }}

QTableView {{
    background: {SURFACE}; alternate-background-color: {SURFACE}; border: 1px solid {BORDER};
    border-radius: 8px; gridline-color: {BORDER}; selection-background-color: {SELECT};
    selection-color: {TEXT}; outline: 0;
}}
QTableView:focus {{ border: 1px solid {LIME}; }}
QHeaderView::section {{
    background: {RAISED}; color: {MUTED}; border: none; border-bottom: 1px solid {BORDER};
    padding: 6px 10px; font-weight: 600;
}}
QTableCornerButton::section {{ background: {RAISED}; border: none; }}

QPlainTextEdit {{
    background: #0A111D; color: #D5DEEA; border: 1px solid {BORDER}; border-radius: 6px;
    font-family: "DejaVu Sans Mono", "Ubuntu Mono", monospace; font-size: 9pt;
    selection-background-color: {SELECT};
}}
QPlainTextEdit:focus {{ border: 1px solid {LIME}; }}

QLineEdit {{
    background: #0A111D; color: {TEXT}; border: 1px solid {BORDER}; border-radius: 6px;
    padding: 5px 8px; selection-background-color: {SELECT};
}}
QLineEdit:focus {{ border: 1px solid {LIME}; }}
QCheckBox {{ background: transparent; spacing: 8px; }}
QCheckBox::indicator {{ width: 16px; height: 16px; border: 1px solid #4A6288; border-radius: 4px; background: #0A111D; }}
QCheckBox::indicator:checked {{ background: {LIME}; border-color: {LIME}; }}
QCheckBox:focus {{ color: {LIME}; }}

QProgressBar {{ background: {RAISED}; border: none; border-radius: 2px; max-height: 4px; }}
QProgressBar::chunk {{ background: {LIME}; border-radius: 2px; }}

QScrollBar:vertical {{ background: {SURFACE}; width: 12px; margin: 0; }}
QScrollBar:horizontal {{ background: {SURFACE}; height: 12px; margin: 0; }}
QScrollBar::handle {{ background: #3A5070; border-radius: 4px; min-height: 24px; min-width: 24px; margin: 2px; }}
QScrollBar::handle:hover {{ background: #4A6288; }}
QScrollBar::add-line, QScrollBar::sub-line {{ width: 0; height: 0; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: none; }}

QMessageBox QLabel {{ background: transparent; }}
"""
