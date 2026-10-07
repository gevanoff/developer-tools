from __future__ import annotations

import hashlib
import json
import os
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Iterable

from . import backends

APP_NAME = "android-build-install"
SKIP_DIRS = {".git", ".gradle", ".idea", "build", "node_modules", "out", ".venv", "venv"}


class ToolError(backends.BackendError):
    pass


class OperationCancelled(ToolError):
    pass


class ProcessController:
    def __init__(self):
        self._lock = threading.Lock()
        self._process: subprocess.Popen[str] | None = None
        self._cancelled = False

    def reset(self) -> None:
        with self._lock:
            self._cancelled = False
            self._process = None

    def attach(self, process: subprocess.Popen[str]) -> None:
        with self._lock:
            if self._cancelled:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                raise OperationCancelled("Operation cancelled.")
            self._process = process

    def detach(self, process: subprocess.Popen[str]) -> None:
        with self._lock:
            if self._process is process:
                self._process = None

    def cancel(self) -> None:
        with self._lock:
            self._cancelled = True
            process = self._process
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    @property
    def cancelled(self) -> bool:
        with self._lock:
            return self._cancelled


@dataclass
class Device:
    serial: str
    state: str
    model: str


@dataclass
class Preferences:
    gradle_task: str = "assembleDebug"
    preferred_apk: str = ""
    java_home: str = ""
    device_serial: str = ""
    auto_launch: bool = True


@dataclass
class ProjectStatus:
    git: str
    build: str
    device: str
    detail: str = ""
    branch: str = ""

    @property
    def git_display(self) -> str:
        return f"{self.branch} | {self.git}" if self.branch else self.git


def config_root() -> Path:
    root = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return root / APP_NAME


def state_root() -> Path:
    root = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return root / APP_NAME


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def save_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def projects_path() -> Path:
    return config_root() / "projects.json"


def preferences_path() -> Path:
    return config_root() / "project-preferences.json"


def load_projects() -> list[str]:
    values = load_json(projects_path(), [])
    return [str(Path(p).expanduser().resolve()) for p in values if Path(p).expanduser().is_dir()]


def save_projects(projects: Iterable[str]) -> None:
    seen: set[str] = set()
    normalized: list[str] = []
    for p in projects:
        value = str(Path(p).expanduser().resolve())
        if value not in seen and Path(value).is_dir():
            seen.add(value)
            normalized.append(value)
    save_json(projects_path(), normalized)


def remember_project(project: str) -> None:
    p = str(Path(project).expanduser().resolve())
    save_projects([p, *[x for x in load_projects() if x != p]])


def remove_project(project: str) -> None:
    p = str(Path(project).expanduser().resolve())
    save_projects([x for x in load_projects() if x != p])


def load_preferences(project: str) -> Preferences:
    key = str(Path(project).expanduser().resolve())
    data = load_json(preferences_path(), {}).get(key, {})
    return Preferences(
        gradle_task=data.get("gradle_task", "assembleDebug") or "assembleDebug",
        preferred_apk=data.get("preferred_apk", "") or "",
        java_home=data.get("java_home", "") or "",
        device_serial=data.get("device_serial", "") or "",
        auto_launch=bool(data.get("auto_launch", True)),
    )


def save_preferences(project: str, pref: Preferences) -> None:
    key = str(Path(project).expanduser().resolve())
    data = load_json(preferences_path(), {})
    data[key] = asdict(pref)
    save_json(preferences_path(), data)


def run(argv: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None,
        check: bool = False, stream: Callable[[str], None] | None = None,
        controller: ProcessController | None = None) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    if stream or controller:
        if controller and controller.cancelled:
            raise OperationCancelled("Operation cancelled.")
        if stream:
            stream("$ " + shlex.join(argv))
        proc = subprocess.Popen(argv, cwd=cwd, env=merged_env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, start_new_session=True)
        if controller:
            controller.attach(proc)
        output: list[str] = []
        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                output.append(line)
                if stream:
                    stream(line.rstrip("\n"))
            rc = proc.wait()
        finally:
            if proc.stdout:
                proc.stdout.close()
            if controller:
                controller.detach(proc)
        if controller and controller.cancelled:
            raise OperationCancelled("Operation cancelled.")
        result = subprocess.CompletedProcess(argv, rc, "".join(output), "")
    else:
        result = subprocess.run(argv, cwd=cwd, env=merged_env, text=True, capture_output=True)
    if check and result.returncode:
        text = (result.stdout or "") + (result.stderr or "")
        raise ToolError(f"Command failed ({result.returncode}): {shlex.join(argv)}\n{text.strip()}")
    return result


def find_gradle_roots(project: str, max_depth: int = 2) -> list[Path]:
    root = Path(project).expanduser().resolve()
    found: list[Path] = []
    queue: list[tuple[Path, int]] = [(root, 0)]
    while queue:
        path, depth = queue.pop(0)
        wrapper = path / "gradlew"
        if wrapper.is_file():
            found.append(path)
        if depth >= max_depth:
            continue
        try:
            children = [p for p in path.iterdir() if p.is_dir() and p.name not in SKIP_DIRS]
        except OSError:
            continue
        queue.extend((p, depth + 1) for p in children)
    return sorted(set(found))


def select_gradle_root(project: str) -> Path:
    roots = find_gradle_roots(project)
    if not roots:
        raise ToolError("No gradlew was found in the selected folder or within two levels below it.")
    if len(roots) > 1:
        rendered = "\n".join(f"  - {p}" for p in roots)
        raise ToolError("Multiple Gradle roots were found. Select the specific Android project folder:\n" + rendered)
    wrapper = roots[0] / "gradlew"
    if not os.access(wrapper, os.X_OK):
        raise ToolError(f"Gradle wrapper is not executable: {wrapper}\nRun: chmod +x {shlex.quote(str(wrapper))}")
    return roots[0]


def local_sdk_dir(gradle_root: Path) -> Path | None:
    props = gradle_root / "local.properties"
    if not props.is_file():
        return None
    for raw in props.read_text(encoding="utf-8", errors="replace").splitlines():
        if raw.strip().startswith("sdk.dir="):
            value = raw.split("=", 1)[1].strip().replace("\\:", ":").replace("\\\\", "\\")
            return Path(os.path.expandvars(value)).expanduser()
    return None


def sdk_roots(gradle_root: Path) -> list[Path]:
    roots: list[Path] = []
    local = local_sdk_dir(gradle_root)
    if local:
        roots.append(local)
    for var in ("ANDROID_SDK_ROOT", "ANDROID_HOME"):
        if os.environ.get(var):
            roots.append(Path(os.environ[var]).expanduser())
    roots.extend([Path.home() / "Android" / "Sdk", Path.home() / ".android" / "sdk"])
    return list(dict.fromkeys(roots))


def resolve_adb(gradle_root: Path) -> str:
    for root in sdk_roots(gradle_root):
        candidate = root / "platform-tools" / "adb"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    path = shutil.which("adb")
    if path:
        return path
    raise ToolError("adb was not found. Install Android SDK Platform-Tools or configure ANDROID_SDK_ROOT.")


def resolve_aapt(gradle_root: Path) -> tuple[str, str] | None:
    for root in sdk_roots(gradle_root):
        build_tools = root / "build-tools"
        if not build_tools.is_dir():
            continue
        for directory in sorted((p for p in build_tools.iterdir() if p.is_dir()), reverse=True):
            for name in ("aapt2", "aapt"):
                candidate = directory / name
                if candidate.is_file() and os.access(candidate, os.X_OK):
                    return str(candidate), name
    return None


def connected_devices(adb: str) -> list[Device]:
    result = run([adb, "devices", "-l"], check=True)
    devices: list[Device] = []
    for raw in result.stdout.splitlines():
        parts = raw.split()
        if len(parts) < 2 or parts[0] == "List":
            continue
        state = parts[1]
        if state not in {"device", "offline", "unauthorized", "recovery", "sideload"}:
            continue
        model = parts[0]
        for token in parts[2:]:
            if token.startswith("model:"):
                model = token.split(":", 1)[1].replace("_", " ")
        devices.append(Device(parts[0], state, model))
    return devices


def resolve_device(adb: str, requested: str = "") -> Device:
    devices = connected_devices(adb)
    if requested:
        matches = [d for d in devices if d.serial == requested]
        if not matches:
            raise ToolError(f"Preferred device {requested!r} is not connected.")
        if matches[0].state != "device":
            raise ToolError(f"Preferred device {requested!r} is {matches[0].state}.")
        return matches[0]
    ready = [d for d in devices if d.state == "device"]
    if len(ready) == 1:
        return ready[0]
    if len(ready) > 1:
        raise ToolError("Multiple authorized Android devices are connected. Save a preferred device in Settings.")
    if any(d.state == "unauthorized" for d in devices):
        raise ToolError("Android device connected but unauthorized. Unlock it and accept the USB debugging prompt.")
    if any(d.state == "offline" for d in devices):
        raise ToolError("Android device is offline. Reconnect USB or restart USB debugging.")
    raise ToolError("No ready Android device was found.")


def java_env(pref: Preferences) -> dict[str, str]:
    if pref.java_home:
        home = Path(pref.java_home).expanduser().resolve()
        if not (home / "bin" / "java").is_file():
            raise ToolError(f"Configured JAVA_HOME does not contain bin/java: {home}")
        return {"JAVA_HOME": str(home)}
    if os.environ.get("JAVA_HOME"):
        home = Path(os.environ["JAVA_HOME"])
        if not (home / "bin" / "java").is_file():
            raise ToolError(f"JAVA_HOME does not contain bin/java: {home}")
        return {}
    if not shutil.which("java"):
        raise ToolError("Java was not found. Configure JAVA_HOME or install a compatible JDK.")
    return {}


def all_apk_candidates(gradle_root: Path, max_depth: int = 2) -> list[Path]:
    queue: list[tuple[Path, int]] = [(gradle_root, 0)]
    found: set[Path] = set()
    while queue:
        path, depth = queue.pop(0)
        apk_root = path / "build" / "outputs" / "apk"
        if apk_root.is_dir():
            found.update(p for p in apk_root.rglob("*.apk") if "androidTest" not in p.parts)
        if depth >= max_depth:
            continue
        try:
            children = [p for p in path.iterdir() if p.is_dir() and p.name not in SKIP_DIRS]
        except OSError:
            continue
        queue.extend((p, depth + 1) for p in children)
    return sorted(found, key=lambda p: p.stat().st_mtime, reverse=True)


def apk_candidates(gradle_root: Path, max_depth: int = 2) -> list[Path]:
    candidates = all_apk_candidates(gradle_root, max_depth=max_depth)
    debug = [p for p in candidates if "debug" in p.parts or "debug" in p.name.lower()]
    return debug or candidates


def deterministic_apk(project: str, gradle_root: Path, pref: Preferences) -> Path | None:
    plan = backends.plan_for_root(gradle_root) if any(
        (gradle_root / name).is_file() for name in (backends.CONFIG, "project.godot")
    ) else None
    if plan and plan.apk:
        if pref.preferred_apk:
            preferred = (Path(project) / Path(pref.preferred_apk).expanduser()).resolve()
            if preferred != plan.apk:
                raise ToolError("Preferred APK conflicts with the backend output. Clear Preferred APK or match the configured apk.")
        return plan.apk if plan.apk.is_file() else None
    all_candidates = all_apk_candidates(gradle_root)
    if not all_candidates:
        return None
    if pref.preferred_apk:
        preferred = Path(pref.preferred_apk).expanduser()
        if not preferred.is_absolute():
            preferred = Path(project).resolve() / preferred
        preferred = preferred.resolve()
        matches = [p for p in all_candidates if p.resolve() == preferred]
        return matches[0] if len(matches) == 1 else None

    candidates = apk_candidates(gradle_root)
    if len(candidates) == 1:
        return candidates[0]
    conventional = [p for p in candidates if p.as_posix().endswith("/app/build/outputs/apk/debug/app-debug.apk")]
    return conventional[0] if len(conventional) == 1 else None


def package_id(apk: Path, gradle_root: Path) -> str | None:
    inspector = resolve_aapt(gradle_root)
    if not inspector:
        return None
    tool, kind = inspector
    if kind == "aapt2":
        result = run([tool, "dump", "packagename", str(apk)])
        return next((x.strip() for x in result.stdout.splitlines() if "." in x and " " not in x.strip()), None)
    result = run([tool, "dump", "badging", str(apk)])
    for line in result.stdout.splitlines():
        if line.startswith("package:") and "name='" in line:
            return line.split("name='", 1)[1].split("'", 1)[0]
    return None


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def installed_apk_hash(adb: str, device: Device, package: str) -> str | None:
    paths = run([adb, "-s", device.serial, "shell", "pm", "path", package])
    if paths.returncode:
        return None
    remote = [line.split("package:", 1)[1].strip() for line in paths.stdout.splitlines() if line.startswith("package:")]
    if len(remote) != 1:
        return None
    with tempfile.TemporaryDirectory(prefix="android-build-install-") as td:
        local = Path(td) / "installed.apk"
        pulled = run([adb, "-s", device.serial, "pull", remote[0], str(local)])
        return sha256(local) if pulled.returncode == 0 and local.is_file() else None


def git_branch(project: str) -> str:
    """Read checkout identity even when upstream/fetch/build checks fail."""
    try:
        branch = run(["git", "-C", project, "symbolic-ref", "--quiet", "--short", "HEAD"])
        if branch.returncode == 0:
            return branch.stdout.strip()
        commit = run(["git", "-C", project, "rev-parse", "--short", "HEAD"])
        return f"detached @ {commit.stdout.strip()}" if commit.returncode == 0 else ""
    except OSError:
        return ""


def git_status(project: str, fetch: bool = False,
               controller: ProcessController | None = None,
               stream: Callable[[str], None] | None = None) -> tuple[str, str]:
    probe = run(["git", "-C", project, "rev-parse", "--show-toplevel"])
    if probe.returncode:
        return "Not Git", ""
    root = probe.stdout.strip()
    if fetch:
        fetched = run(["git", "-C", root, "fetch", "--quiet"],
                      controller=controller, stream=stream)
        if fetched.returncode:
            detail = ((fetched.stdout or "") + (fetched.stderr or "")).strip()
            raise ToolError(f"git fetch failed for {root}" + (f":\n{detail}" if detail else "."))
    dirty = run(["git", "-C", root, "status", "--porcelain"])
    if dirty.stdout.strip():
        return "Dirty", dirty.stdout.strip()
    upstream = run(["git", "-C", root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
    if upstream.returncode:
        return "No upstream", ""
    counts = run(["git", "-C", root, "rev-list", "--left-right", "--count", "HEAD...@{u}"], check=True)
    ahead, behind = [int(x) for x in counts.stdout.split()]
    if ahead and behind:
        return f"Diverged {ahead}/{behind}", ""
    if behind:
        return f"Behind {behind}", ""
    if ahead:
        return f"Ahead {ahead}", ""
    return "Current", ""


def safe_git_pull(project: str, stream: Callable[[str], None] | None = None,
                  controller: ProcessController | None = None) -> None:
    status, _ = git_status(project, fetch=True, controller=controller, stream=stream)
    if status == "Dirty" or status.startswith("Diverged") or status == "No upstream":
        raise ToolError(f"Refusing Git pull because repository state is {status}.")
    if not status.startswith("Behind"):
        return
    run(["git", "-C", project, "pull", "--ff-only"], check=True, stream=stream, controller=controller)


def newest_project_input_mtime(project: str) -> float:
    newest = 0.0
    queue = [Path(project).resolve()]
    while queue:
        directory = queue.pop()
        try:
            children = list(directory.iterdir())
        except OSError:
            continue
        for path in children:
            if path.name in SKIP_DIRS:
                continue
            try:
                if path.is_symlink() and path.is_dir():
                    continue
                if path.is_dir():
                    queue.append(path)
                elif path.is_file():
                    newest = max(newest, path.stat().st_mtime)
            except OSError:
                pass
    return newest


def build_status(project: str, gradle_root: Path, pref: Preferences) -> tuple[str, str]:
    apk = deterministic_apk(project, gradle_root, pref)
    candidates = apk_candidates(gradle_root)
    if pref.preferred_apk and apk is None:
        return ("Preferred missing" if candidates else "No APK"), ""
    if apk is None:
        return ("Ambiguous" if candidates else "No APK"), ""
    if any((gradle_root / name).is_file() for name in (backends.CONFIG, "project.godot")):
        if backends.plan_for_root(gradle_root).backend != "gradle":
            return "Stale", "Export/build required; non-Gradle dependency freshness is delegated to the builder."
    return ("Fresh" if newest_project_input_mtime(project) <= apk.stat().st_mtime else "Stale"), str(apk)


def device_status(project: str, gradle_root: Path, pref: Preferences) -> tuple[str, str]:
    apk = deterministic_apk(project, gradle_root, pref)
    if apk is None:
        return "No local build", ""
    try:
        adb = resolve_adb(gradle_root)
        device = resolve_device(adb, pref.device_serial)
    except ToolError as exc:
        return "No device", str(exc)
    package = package_id(apk, gradle_root)
    if not package:
        return "Unknown", "Could not determine APK package ID."
    remote = installed_apk_hash(adb, device, package)
    if remote is None:
        query = run([adb, "-s", device.serial, "shell", "pm", "path", package])
        return ("Not installed" if query.returncode or not query.stdout.strip() else "Unknown"), package
    return ("Same" if remote == sha256(apk) else "Different"), package


def project_status(project: str, fetch: bool = False) -> ProjectStatus:
    pref = load_preferences(project)
    branch = git_branch(project)
    try:
        git, git_detail = git_status(project, fetch=fetch)
    except (ToolError, OSError) as exc:
        git, git_detail = "Unknown", str(exc)
    try:
        gradle_root = backends.select_plan(project).root
        build, build_detail = build_status(project, gradle_root, pref)
    except backends.BackendError as exc:
        return ProjectStatus(git, "Configuration needed", "Unknown",
                             "\n".join(x for x in (git_detail, str(exc)) if x), branch)
    device, device_detail = device_status(project, gradle_root, pref)
    return ProjectStatus(git, build, device, "\n".join(x for x in (git_detail, build_detail, device_detail) if x), branch)


def log_file(project: str) -> Path:
    import datetime as dt
    root = state_root() / "logs"
    root.mkdir(parents=True, exist_ok=True)
    return root / f"{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}-{Path(project).name.replace(' ', '_')}.log"


def build_install(project: str, *, sync: bool = False, force_build: bool = True,
                  stream: Callable[[str], None] | None = None,
                  controller: ProcessController | None = None) -> str:
    project = str(Path(project).expanduser().resolve())
    pref = load_preferences(project)
    plan = backends.select_plan(project)
    gradle_root = plan.root
    adb = resolve_adb(gradle_root)
    device = resolve_device(adb, pref.device_serial)
    env = {}
    env["ANDROID_SERIAL"] = device.serial
    log = log_file(project)

    def emit(line: str) -> None:
        with log.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        if stream:
            stream(line)

    emit(f"Project: {project}")
    emit(f"Build backend: {plan.backend}; root: {gradle_root}")
    emit(f"Device: {device.model} [{device.serial}]")

    if sync:
        git, _ = git_status(project, fetch=True, controller=controller, stream=emit)
        emit(f"Git: {git}")
        if git == "Dirty" or git.startswith("Diverged") or git == "No upstream":
            raise ToolError(f"Sync & Run stopped: Git state is {git}.")
        safe_git_pull(project, emit, controller)

    # Git pull may change the build contract or project layout.
    plan = backends.select_plan(project)
    gradle_root = plan.root
    build, _ = build_status(project, gradle_root, pref)
    built = force_build or build in {"Stale", "No APK", "Preferred missing", "Ambiguous"}
    if built:
        argv = backends.command(plan, pref.gradle_task)
        if plan.backend == "gradle" or pref.java_home:
            env.update(java_env(pref))
        previous_output = None
        if plan.apk:
            plan.apk.parent.mkdir(parents=True, exist_ok=True)
            previous_output = plan.apk.stat() if plan.apk.is_file() else None
        result = run(argv, cwd=gradle_root, env=env, stream=emit, controller=controller)
        if result.returncode:
            raise ToolError(f"{plan.backend} failed with exit code {result.returncode}. See {log}")
        if plan.apk:
            current = plan.apk.stat() if plan.apk.is_file() else None
            if current is None or current.st_size == 0 or (previous_output is not None and
                    (current.st_mtime_ns, current.st_size) ==
                    (previous_output.st_mtime_ns, previous_output.st_size)):
                raise ToolError("Build did not produce/update the configured APK; refusing to install old output.")
    else:
        emit(f"Build skipped: local build is {build}.")

    apk = deterministic_apk(project, gradle_root, pref)
    if apk is None:
        raise ToolError("A deterministic APK could not be selected. Configure Preferred APK in Settings.")
    if built:
        os.utime(apk, None)
        emit(f"Build freshness validated: {apk}")

    package = package_id(apk, gradle_root)
    install_needed = True
    if sync and package:
        install_needed = installed_apk_hash(adb, device, package) != sha256(apk)
        if not install_needed:
            emit("Install skipped: device has the same APK.")

    if install_needed:
        result = run([adb, "-s", device.serial, "install", "-r", str(apk)],
                     stream=emit, controller=controller)
        if result.returncode:
            if "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in result.stdout:
                raise ToolError("Signing key mismatch. Automatic uninstall is disabled because it would remove app data.")
            raise ToolError(f"adb install failed with exit code {result.returncode}. See {log}")

    if pref.auto_launch:
        if package:
            result = run([adb, "-s", device.serial, "shell", "monkey", "-p", package,
                          "-c", "android.intent.category.LAUNCHER", "1"],
                         stream=emit, controller=controller)
            if result.returncode or "No activities found" in result.stdout:
                emit(f"WARNING: launch failed for {package}.")
        else:
            emit("WARNING: package ID could not be determined; launch skipped.")

    emit(f"Completed successfully. Log: {log}")
    return str(log)
