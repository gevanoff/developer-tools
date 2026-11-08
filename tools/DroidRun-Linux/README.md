# DroidRun — Ubuntu/Linux

Ubuntu/Linux counterpart to the Windows DroidRun dashboard in this repository.

It preserves the same operating model:

- saved Android projects;
- Sync & Run for the normal development loop;
- explicit Build & Install and Git Pull actions;
- conservative Git handling: fetch plus pull --ff-only, never stash/reset/merge;
- stale/fresh APK detection;
- deterministic APK selection with a per-project preferred APK;
- exact local-vs-installed APK SHA-256 comparison when possible;
- per-project JDK and preferred-device settings;
- adb install -r without automatic uninstall;
- optional app auto-launch;
- timestamped logs;
- live operation output in a desktop dashboard with Running/Done/Failed/Cancelled states;
- the same dark theme, status-chip colours, and Sync & Run preview as the Windows dashboard (see its README's *Dashboard layout*);
- cancellation of active Gradle/Git/ADB subprocess groups;
- read-only device scan and report browsing.

## Ubuntu requirements

- Python 3.10 or newer
- python3-venv
- Git
- a Gradle project with an executable gradlew and compatible JDK, a Godot 4 project, or a configured custom build
- Android SDK Platform-Tools (adb)
- Android SDK Build-Tools (aapt2 or aapt) for package inspection/comparison
- an Android device with USB debugging enabled

On Ubuntu, Android device access normally uses udev rules rather than a Windows USB driver. If adb devices shows no device, install/configure the appropriate Android udev rules for the device vendor and reconnect it.

## Run

From this directory:

    ./droidrun

To open a specific project and immediately run Build & Install:

    ./droidrun /path/to/project

The project path is remembered for future dashboard sessions. This is the Linux analogue of launching the Windows tool with a dragged/explicit project folder.

The launcher creates a dedicated virtual environment under:

    ~/.local/share/android-build-install/venv

and installs the tool editable into that environment on first launch.

The existing `android-build-install` XDG settings, state, and virtualenv paths are retained deliberately for upgrade compatibility; the Python import package remains `android_build_install_linux`. The user-facing command and desktop entry are now `droidrun`.

## Desktop launcher

    ./install-desktop.sh

This creates a per-user desktop entry and a ~/.local/bin/droidrun symlink. No root access is required. Reinstallation removes the old generated `android-build-install.desktop` entry after the new launcher is installed, while preserving customized entries. The `android-build-install` CLI alias remains available.

## State

Saved projects and preferences live under:

    ${XDG_CONFIG_HOME:-~/.config}/android-build-install/

Logs live under:

    ${XDG_STATE_HOME:-~/.local/state}/android-build-install/logs/

## SDK discovery

The tool searches, in order:

1. sdk.dir in the selected Gradle project's local.properties
2. ANDROID_SDK_ROOT
3. ANDROID_HOME
4. ~/Android/Sdk
5. ~/.android/sdk
6. adb on PATH

## Sync & Run

The optimized path:

1. fetch Git remote-tracking state;
2. stop on dirty/diverged/no-upstream states that make automatic updating unsafe;
3. fast-forward with git pull --ff-only only when behind;
4. reuse a fresh Gradle or Godot APK when possible;
5. rebuild when stale or missing; always invoke custom builders to validate their dependencies;
6. compare local and installed APK hashes;
7. skip install when identical;
8. otherwise run adb install -r;
9. launch when enabled.

Multiple build roots, multiple devices without a preference, or ambiguous APK outputs are treated as errors rather than guessed.

## Cancellation

Sync & Run, Build & Install, and Git Pull expose a Cancel action while a cancellable subprocess is active. The Linux implementation starts streamed commands in their own process group and sends SIGTERM to that group, so Gradle/ADB descendants are cancelled with the parent operation instead of being orphaned.

Cancel stays disabled while cancellation is pending and is available again when the next operation starts.

## Device scan and reports

Scan Device performs a read-only status pass over saved projects and shows a table of the current local-build/device relationship without rebuilding or installing.

Reports opens the XDG state log directory containing timestamped operation logs.

## Tests

From an activated environment with the package installed:

    python -m unittest discover -s tests -v

The unit tests require no Android device or SDK.

## Current scope

The Linux and Windows implementations share Gradle, Godot 4, and custom build behavior while using platform-native paths and processes.

See [Godot and custom builds](../DroidRun/BUILD-BACKENDS.md) for setup and the shared configuration schema. Settings → Godot / custom build opens the configuration editor.

The Git column shows the checked-out branch before its status chip, for example
`main` with **Current** or `feature/camera-flip` with **Dirty**. Detached checkouts show
`detached @ <short SHA>`. Hover over the row to read the full branch name
and status details if the column is truncated.

## Dashboard

- Select a project to see what Sync & Run will do from the last check (for example *Pull 2 commits → Build → Install → Launch*) or why it will stop and how to fix it. Enter or a double-click runs Sync & Run.
- **Add project…** asks for a repository or project folder and lists the Android projects inside it (Gradle `gradlew`, Godot `project.godot`, or `android-build-install.json`, up to four folders deep). Ready-looking projects are checked; ones that may not build yet are unchecked with the reason; ones already added can't be added twice. A folder that is itself a project is added straight away, and a module folder offers its enclosing project. The rules match the Windows README's *Adding projects*.
- **Rename…** (F2) changes the name DroidRun shows; leave it empty to use the folder name. The folder is never renamed. Names are stored in `~/.config/android-build-install/project-names.json`.
- Several projects can be selected (Ctrl/Shift+click, Ctrl+A). The refresh button checks the selected projects (**Refresh Selected**, **Refresh N Selected**), or every project when none is selected (**Refresh All**). Nothing is selected at start; Esc clears the selection. Ctrl+R or F5 does the same; **Stop refresh** stops after the current project. After an operation only that project is rechecked, without fetching.
- Failures and cancellations appear in the operation panel; expected tool errors are shown without a Python traceback.
- Remove asks first and never changes the folder or its saved settings.
- Settings can browse for the APK and JDK, choose among several connected devices, and checks that JAVA_HOME contains bin/java before saving. Branch identity is local and
remains available when remote or build-configuration checks fail.
