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
WRAPPER = "gradlew"
# A Gradle build is rooted at its settings file even when the repository does not
# commit the Gradle wrapper. Keep in step with AndroidBuildBackends.ps1.
GRADLE_SETTINGS = ("settings.gradle", "settings.gradle.kts")
ROOT_MARKERS = (CONFIG, "project.godot", WRAPPER, *GRADLE_SETTINGS)
NO_GRADLE_MESSAGE = ("This Gradle project has no wrapper (gradlew) and no installed Gradle was found on PATH. "
                     "Add the Gradle wrapper to the repository (run 'gradle wrapper' once and commit the files), "
                     "or install Gradle and add it to PATH.")


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


def is_build_root(folder: Path) -> bool:
    return any((folder / name).is_file() for name in ROOT_MARKERS)


def has_wrapper(root: Path) -> bool:
    return (root / WRAPPER).is_file()


def installed_gradle() -> str:
    """The Gradle on PATH, used only when a project has no wrapper."""
    return shutil.which("gradle") or ""


def find_roots(project: str, max_depth: int = 2) -> list[Path]:
    queue = [(Path(project).expanduser().resolve(), 0)]
    found = []
    while queue:
        root, depth = queue.pop(0)
        if is_build_root(root):
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
        if has_wrapper(root):
            return BuildPlan(root, backend)
        if not any((root / name).is_file() for name in GRADLE_SETTINGS):
            raise BackendError("No Gradle wrapper or settings.gradle(.kts) in the build root. "
                               "Select the Gradle project folder, or configure backend: custom in "
                               "android-build-install.json.")
        gradle = installed_gradle()
        if not gradle:
            raise BackendError(NO_GRADLE_MESSAGE)
        return BuildPlan(root, backend, gradle)
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
        if plan.executable:  # no wrapper: the installed Gradle chosen by plan_for_root
            return [plan.executable, gradle_task, "--stacktrace"]
        wrapper = plan.root / WRAPPER
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


# ----- Gradle download-cache recovery -------------------------------------------------
# A Gradle daemon or a reused configuration-cache entry can still point at library files
# that have since disappeared from ~/.gradle/caches (cache cleanup, antivirus, a disk
# cleaner). The build then fails in seconds with FileNotFoundException for those paths.
# DroidRun retries such a build once with fresh dependency resolution. It never deletes
# anything in the Gradle cache. Keep in step with AndroidBuildBackends.ps1.

_MISSING_FILE = re.compile(r"(?:FileNotFoundException|NoSuchFileException):\s*(.+?)\s*$")
_MISSING_SUFFIX = re.compile(
    r"\s*\((?:The system cannot find the (?:path|file) specified|No such file or directory)\)?\.?$")
_CACHE_SEGMENT = re.compile(r"[\\/]caches[\\/]")


def missing_gradle_cache_files(output: str) -> list[str]:
    """Paths under a Gradle caches folder that the build reported as missing, in order."""
    found: list[str] = []
    for line in output.splitlines():
        match = _MISSING_FILE.search(line)
        if not match:
            continue
        path = _MISSING_SUFFIX.sub("", match.group(1)).strip()
        if _CACHE_SEGMENT.search(path) and path not in found:
            found.append(path)
    return found


def gradle_recovery_arguments(output: str) -> list[str]:
    """Extra arguments for the single retry after a missing-cache-file failure."""
    arguments = ["--refresh-dependencies"]
    # Only builds that use the configuration cache know this switch's meaning; it is
    # what replays the stale file list without re-checking it.
    if "configuration cache" in output.lower():
        arguments.insert(0, "--no-configuration-cache")
    return arguments


def gradle_cache_entries(paths: list[str]) -> list[str]:
    """Folders to clear by hand: the group/artifact/version folder for downloaded
    modules, otherwise the folder that held the missing file."""
    entries: list[str] = []
    for path in paths:
        parts = re.split(r"[\\/]", path)
        separator = "\\" if "\\" in path else "/"
        try:
            index = parts.index("files-2.1")
            entry = separator.join(parts[:index + 4])
        except ValueError:
            entry = separator.join(parts[:-1])
        if entry and entry not in entries:
            entries.append(entry)
    return entries


def gradle_cache_repair_message(paths: list[str]) -> str:
    entries = gradle_cache_entries(paths)
    shown = "\n".join(f"  {entry}" for entry in entries[:8])
    more = f"\n  ...and {len(entries) - 8} more" if len(entries) > 8 else ""
    return ("Gradle's download cache is still missing files after a fresh retry. "
            "Close Android Studio and other Gradle builds, delete these cache folders "
            "(Gradle downloads them again), and run DroidRun again:\n" + shown + more)
