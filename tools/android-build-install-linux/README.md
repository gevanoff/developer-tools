# Android Build and Install — Ubuntu/Linux

Ubuntu/Linux counterpart to the Windows Android Build and Install dashboard in this repository.

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
- live operation output in a desktop dashboard;
- cancellation of active Gradle/Git/ADB subprocess groups;
- read-only device scan and report browsing.

## Ubuntu requirements

- Python 3.10 or newer
- python3-venv
- Git
- a compatible JDK
- an Android project with an executable gradlew
- Android SDK Platform-Tools (adb)
- Android SDK Build-Tools (aapt2 or aapt) for package inspection/comparison
- an Android device with USB debugging enabled

On Ubuntu, Android device access normally uses udev rules rather than a Windows USB driver. If adb devices shows no device, install/configure the appropriate Android udev rules for the device vendor and reconnect it.

## Run

From this directory:

    ./android-build-install

To open a specific project and immediately run Build & Install:

    ./android-build-install /path/to/project

The project path is remembered for future dashboard sessions. This is the Linux analogue of launching the Windows tool with a dragged/explicit project folder.

The launcher creates a dedicated virtual environment under:

    ~/.local/share/android-build-install/venv

and installs the tool editable into that environment on first launch.

## Desktop launcher

    ./install-desktop.sh

This creates a per-user desktop entry and a ~/.local/bin/android-build-install symlink. No root access is required.

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
4. reuse a fresh APK when possible;
5. rebuild when stale or missing;
6. compare local and installed APK hashes;
7. skip install when identical;
8. otherwise run adb install -r;
9. launch when enabled.

Multiple Gradle roots, multiple devices without a preference, or ambiguous APK outputs are treated as errors rather than guessed.

## Cancellation

Sync & Run, Build & Install, and Git Pull expose a Cancel action while a cancellable subprocess is active. The Linux implementation starts streamed commands in their own process group and sends SIGTERM to that group, so Gradle/ADB descendants are cancelled with the parent operation instead of being orphaned.

## Device scan and reports

Scan Device performs a read-only status pass over saved projects and reports the current local-build/device relationship without rebuilding or installing.

Reports opens the XDG state log directory containing timestamped operation logs.

## Tests

From an activated environment with the package installed:

    python -m unittest discover -s tests -v

The unit tests require no Android device or SDK.

## Current scope

This first Linux implementation preserves the safety and workflow semantics of the Windows tool while using Linux-native paths and processes. The Windows PowerShell implementation remains untouched.
