"""Project discovery, display names, and refresh scope for the dashboard.

No Qt here. The Windows dashboard has the same rules in tools/DroidRun/DroidRunProjects.ps1;
keep them in step.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from . import backends, core

# Discovery looks a little deeper than build-root selection (backends.find_roots, depth 2)
# because a repository may keep its Android projects in nested folders.
DISCOVERY_DEPTH = 4
DISCOVERY_FOLDER_LIMIT = 4000
ANDROID_HINT_DEPTH = 4
NAME_LIMIT = 80


@dataclass
class Candidate:
    path: str            # normalized absolute path
    relative: str        # path relative to the folder the user chose ("." for the folder itself)
    kind: str            # Gradle, Godot, or Custom build
    note: str            # why it may not build yet; empty when it looks ready
    recommended: bool    # pre-checked in the picker
    outside: bool = False  # found above the chosen folder (the user picked a subfolder)


@dataclass
class Discovery:
    root: str
    candidates: list[Candidate]
    truncated: bool      # the folder limit stopped the search early


def _has_android_manifest(root: Path) -> bool:
    queue = [(root, 0)]
    seen = 0
    while queue and seen < 600:
        folder, depth = queue.pop(0)
        seen += 1
        try:
            children = sorted(folder.iterdir())
        except OSError:
            continue
        for child in children:
            if child.name == "AndroidManifest.xml" and child.is_file():
                return True
            if (depth < ANDROID_HINT_DEPTH and child.is_dir() and not child.is_symlink()
                    and child.name not in backends.SKIP):
                queue.append((child, depth + 1))
    return False


def describe(root: Path) -> tuple[str, str, bool]:
    """Return (kind, note, recommended) for a folder that has a build marker."""
    if (root / backends.CONFIG).is_file():
        try:
            data = backends.read_config(root)
        except backends.BackendError:
            return "Custom build", "Its build configuration has errors; fix it in Settings.", False
        kind = {"godot": "Godot", "gradle": "Gradle"}.get(str(data.get("backend", "")).lower(), "Custom build")
        return kind, "", True
    if (root / "project.godot").is_file():
        try:
            presets = backends.android_presets(root)
        except (backends.BackendError, OSError):
            presets = []
        if presets:
            return "Godot", "", True
        return "Godot", "No Android export preset yet (Project > Export in Godot).", False
    if not _has_android_manifest(root):
        return "Gradle", "No Android app module found (no AndroidManifest.xml).", False
    if not backends.has_wrapper(root):
        if backends.installed_gradle():
            return "Gradle", "No Gradle wrapper; builds use the Gradle installed on PATH.", True
        return "Gradle", "No Gradle wrapper, and no Gradle installed on PATH.", False
    return "Gradle", "", True


def _is_root(folder: Path) -> bool:
    return backends.is_build_root(folder)


def discover(folder: str, max_depth: int = DISCOVERY_DEPTH,
             folder_limit: int = DISCOVERY_FOLDER_LIMIT) -> Discovery:
    """Find build roots at or beneath folder, like backends.find_roots but deeper.

    A build root is not searched further (a Godot project owns its generated Gradle
    tree). If nothing is found beneath, the nearest enclosing root (up to four
    levels up) is offered instead, for when the user picked a module folder.
    """
    start = Path(folder).expanduser().resolve()
    found: list[Path] = []
    queue = [(start, 0)]
    visited = 0
    truncated = False
    while queue:
        current, depth = queue.pop(0)
        visited += 1
        if visited > folder_limit:
            truncated = True
            break
        if _is_root(current):
            found.append(current)
            continue
        if depth >= max_depth:
            continue
        try:
            queue.extend((p, depth + 1) for p in sorted(current.iterdir())
                         if p.is_dir() and not p.is_symlink() and p.name not in backends.SKIP)
        except OSError:
            pass

    outside = False
    if not found:
        for parent in list(start.parents)[:4]:
            if _is_root(parent):
                found, outside = [parent], True
                break

    candidates = []
    for root in found:
        kind, note, recommended = describe(root)
        if outside:
            relative = str(root)
        else:
            relative = "." if root == start else str(root.relative_to(start))
        candidates.append(Candidate(str(root), relative, kind, note, recommended, outside))
    candidates.sort(key=lambda c: c.relative.casefold())
    return Discovery(str(start), candidates, truncated)


# ----- display names -----------------------------------------------------------------

def names_path() -> Path:
    return core.config_root() / "project-names.json"


def clean_name(name: str) -> str:
    """Collapse whitespace, drop control characters, and cap the length."""
    text = re.sub(r"[\x00-\x1f\x7f]", " ", name or "")
    text = re.sub(r"\s+", " ", text).strip()
    return text[:NAME_LIMIT].rstrip()


def load_names() -> dict[str, str]:
    data = core.load_json(names_path(), {})
    if not isinstance(data, dict):
        return {}
    return {str(k): clean_name(str(v)) for k, v in data.items() if clean_name(str(v))}


def display_name(project: str, names: dict[str, str] | None = None) -> str:
    key = str(Path(project).expanduser().resolve())
    return (names if names is not None else load_names()).get(key) or Path(key).name


def set_name(project: str, name: str) -> str:
    """Save a display name; an empty name (or the folder name) removes the override.

    Returns the name that will be shown.
    """
    key = str(Path(project).expanduser().resolve())
    value = clean_name(name)
    data = load_names()
    if not value or value == Path(key).name:
        data.pop(key, None)
    else:
        data[key] = value
    core.save_json(names_path(), data)
    return value or Path(key).name


# ----- refresh scope -----------------------------------------------------------------

def refresh_targets(projects: Iterable[str], selected: Iterable[str]) -> list[str]:
    """Selected projects, in list order; every project when nothing is selected."""
    projects = list(projects)
    chosen = set(selected)
    subset = [p for p in projects if p in chosen]
    return subset or projects


def refresh_label(selected_count: int) -> str:
    if selected_count <= 0:
        return "Refresh All"
    if selected_count == 1:
        return "Refresh Selected"
    return f"Refresh {selected_count} Selected"
