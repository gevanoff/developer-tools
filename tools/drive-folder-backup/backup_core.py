"""Pure backup planning, rclone discovery, and local preferences for Drive Folder Backup."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile


class BackupError(ValueError):
    """Configuration or input must be corrected before a backup."""


def state_directory() -> Path:
    base = os.environ.get("LOCALAPPDATA")
    return (Path(base) if base else Path.home() / ".local" / "share") / "DeveloperTools" / "DriveFolderBackup"


def default_settings() -> dict:
    return {
        "version": 1,
        "sources": [],
        "remote": "",
        "root": "Workstation Backups",
        "computer": safe_segment(socket.gethostname()),
    }


def safe_segment(value: str) -> str:
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value).strip(" .")
    return value or "folder"


def canonical_source(folder: str) -> str:
    return os.path.normcase(os.path.realpath(os.path.abspath(os.path.expanduser(folder))))


def source_identifier(folder: str) -> str:
    normalized = canonical_source(folder)
    label = safe_segment(os.path.basename(normalized.rstrip("\\/")) or normalized)
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:12]
    return f"{label}--{digest}"


def validate_root(root: str) -> str:
    root = root.strip()
    if not root or root.startswith("/") or "\\" in root or ":" in root:
        raise BackupError("Destination must be a relative Drive folder path (e.g. Workstation Backups).")
    parts = root.split("/")
    if any(not p or p in (".", "..") or p != p.strip() or re.search(r"[\x00-\x1f]", p) for p in parts):
        raise BackupError("Destination has an empty, dot, or invalid path component.")
    return root


def destination(remote: str, root: str, computer: str, source: str) -> str:
    if not re.fullmatch(r"[^:\r\n/\\]+:", remote):
        raise BackupError("Choose a configured Google Drive remote.")
    return f"{remote}{validate_root(root)}/{safe_segment(computer)}/{source_identifier(source)}"


def resolve_rclone() -> str:
    # A standalone rclone.exe can be placed beside the launcher; never download binaries silently.
    base = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
    bundled = base / ("rclone.exe" if os.name == "nt" else "rclone")
    if bundled.is_file():
        return str(bundled)
    found = shutil.which("rclone")
    if not found:
        raise BackupError("rclone was not found. Install it or place rclone.exe beside the app.")
    return found


def discover_drive_remotes(binary: str) -> list[str]:
    try:
        result = subprocess.run(
            [binary, "listremotes", "--type", "drive", "--exact"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20,
            check=False, stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BackupError(f"Cannot query rclone configuration: {exc}") from exc
    if result.returncode:
        raise BackupError(f"rclone listremotes failed (exit {result.returncode}): {result.stderr.strip()[:400]}")
    return sorted({line.strip() for line in result.stdout.splitlines() if re.fullmatch(r"[^:\r\n/\\]+:", line.strip())})


def copy_command(binary: str, source: str, target: str, dry_run: bool = False) -> list[str]:
    # Never use shell=True or `sync`: copy retains remote-only files. `--` prevents option injection.
    args = [binary, "copy", "--stats=5s", "--stats-one-line", "--log-level=INFO", "--create-empty-src-dirs"]
    if dry_run:
        args.append("--dry-run")
    return args + ["--", source, target]


def load_settings(path: Path) -> dict:
    if not path.exists():
        return default_settings()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BackupError(f"Cannot read {path}: {exc}. The file has not been overwritten.") from exc
    if (not isinstance(data, dict) or data.get("version") != 1
            or not isinstance(data.get("sources"), list)
            or any(not isinstance(item, str) for item in data["sources"])
            or any(not isinstance(data.get(k), str) for k in ("remote", "root", "computer"))):
        raise BackupError(f"Invalid settings in {path}; no changes made.")
    return data


def save_settings(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                         prefix=".settings-", suffix=".tmp", delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
