"""Build discovery and explicit APK contracts; importing this module runs nothing."""
from __future__ import annotations

import json
import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path

CONFIG = "android-build-install.json"
SKIP = {".git", ".gradle", ".godot", ".idea", "build", "node_modules", "out", ".venv", "venv"}


class BackendError(RuntimeError):
    pass


@dataclass
class BuildPlan:
    root: Path
    backend: str
    executable: str = ""
    arguments: tuple[str, ...] = ()
    apk: Path | None = None


def read_config(root: Path) -> dict:
    path = root / CONFIG
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(data, dict) or data.get("version") != 1:
            raise ValueError("Expected an object with version: 1")
        override = data.get("linux", {})
        if not isinstance(override, dict):
            raise ValueError("linux must be an object")
        data = {**data, **override}
        for key in ("backend", "executable", "preset", "apk"):
            if key in data and (not isinstance(data[key], str) or not data[key].strip()):
                raise ValueError(f"{key} must be a nonempty string")
        if "arguments" in data and (not isinstance(data["arguments"], list)
                                    or not all(isinstance(x, str) for x in data["arguments"])):
            raise ValueError("arguments must be an array of strings")
        return data
    except (ValueError, OSError) as exc:
        raise BackendError(f"Invalid {path}: {exc}") from exc


def find_roots(project: str, max_depth: int = 2) -> list[Path]:
    queue = [(Path(project).expanduser().resolve(), 0)]
    found = []
    while queue:
        root, depth = queue.pop(0)
        if any((root / name).is_file() for name in (CONFIG, "project.godot", "gradlew")):
            found.append(root)
            continue  # Godot owns its generated Android/Gradle subtree.
        if depth < max_depth:
            try:
                queue.extend((p, depth + 1) for p in sorted(root.iterdir())
                             if p.is_dir() and not p.is_symlink() and p.name not in SKIP)
            except OSError:
                pass
    return found


def android_presets(root: Path) -> list[str]:
    path = root / "export_presets.cfg"
    if not path.is_file():
        raise BackendError("Godot needs export_presets.cfg. In Godot, open Project > Export, "
                           "add an Android preset, configure the SDK/JDK and debug keystore, "
                           "and install matching export templates.")
    # Read only top-level preset sections; option values are Godot Variants, not INI.
    presets = []
    section = {}
    active = False
    for line in [*path.read_text(encoding="utf-8-sig").splitlines(), "[end]"]:
        line = line.strip()
        if line.startswith("["):
            if active and section.get("platform") == "Android" and section.get("name"):
                presets.append(section["name"])
            active = bool(re.fullmatch(r"\[preset\.\d+\]", line))
            section = {}
        elif active and "=" in line:
            key, value = line.split("=", 1)
            if key.strip() in {"name", "platform"}:
                try:
                    section[key.strip()] = json.loads(value)
                except ValueError as exc:
                    raise BackendError(f"Invalid Godot preset string: {line}") from exc
    return presets


def plan_for_root(root: Path) -> BuildPlan:
    data = read_config(root)
    backend = data.get("backend", "auto")
    if backend == "auto":
        backend = "godot" if (root / "project.godot").is_file() else "gradle"
    if backend == "gradle":
        if not (root / "gradlew").is_file():
            raise BackendError("No Gradle wrapper. Configure backend: custom in android-build-install.json.")
        return BuildPlan(root, backend)
    if backend not in {"godot", "custom"}:
        raise BackendError(f"Unsupported backend: {backend}. Use auto, gradle, godot or custom.")
    output = data.get("apk", "build/android/app-debug.apk" if backend == "godot" else "")
    if not output or Path(output).suffix.lower() != ".apk":
        raise BackendError("Set apk to an exact .apk output path (AAB and split APK sets cannot be installed).")
    apk = (root / output).resolve()
    if backend == "custom":
        if not data.get("executable"):
            raise BackendError("Custom builds require executable and apk in android-build-install.json.")
        return BuildPlan(root, backend, data["executable"], tuple(data.get("arguments", [])), apk)
    if not (root / "project.godot").is_file():
        raise BackendError("Godot backend requires project.godot in the build root.")
    presets = android_presets(root)
    preset = data.get("preset")
    if preset:
        if presets.count(preset) != 1:
            raise BackendError(f"Expected one Android export preset named {preset!r}.")
    elif len(presets) == 1:
        preset = presets[0]
    else:
        raise BackendError("Expected one Android export preset; set preset in android-build-install.json to select one.")
    return BuildPlan(root, backend, data.get("executable", ""),
                     ("--headless", "--path", str(root), "--export-debug", preset, str(apk)), apk)


def select_plan(project: str) -> BuildPlan:
    roots = find_roots(project)
    if len(roots) != 1:
        raise BackendError("Multiple build roots; select the specific project folder." if roots else
                           "No supported project found. Select a Godot/Gradle folder or configure "
                           "android-build-install.json for a custom build.")
    return plan_for_root(roots[0])


def command(plan: BuildPlan, gradle_task: str) -> list[str]:
    if plan.backend == "gradle":
        wrapper = plan.root / "gradlew"
        if not os.access(wrapper, os.X_OK):
            raise BackendError(f"Gradle wrapper is not executable: {wrapper}")
        return [str(wrapper), gradle_task, "--stacktrace"]
    executable = plan.executable
    if not executable:
        executable = shutil.which("godot4") or shutil.which("godot") or ""
    elif "/" in executable or (plan.root / executable).is_file():
        executable = str((plan.root / executable).resolve())
    else:
        executable = shutil.which(executable) or ""
    if not executable or not os.access(executable, os.X_OK):
        raise BackendError("Build executable not found or not executable. Configure executable in "
                           "android-build-install.json; Godot needs the Godot 4 editor binary.")
    return [executable, *plan.arguments]
