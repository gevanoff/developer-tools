# Android Build and Install

Build Android projects with Gradle, Godot 4, or a configured custom builder, keep local repositories current, compare installed APKs with local builds, and run the right build/install/launch steps from one Windows 11 dashboard.

## Requirements

- Windows 11
- Windows PowerShell 5.1 or later
- Git for Windows for Git status/update features
- a Gradle project containing `gradlew.bat`, a Godot 4 project, or a configured custom build
- the selected backend's toolchain (a compatible JDK for Gradle; Godot editor/export templates for Godot)
- Android SDK Platform-Tools (`adb.exe`)
- Android SDK Build-Tools (`aapt2.exe` or `aapt.exe`) for package inspection, device comparison, and auto-launch
- an Android device with USB debugging enabled
- the appropriate Windows USB driver when the device requires one

The project remains responsible for its build dependencies and Android SDK components. See [Godot and custom builds](BUILD-BACKENDS.md) for setup, examples, and the shared Windows/Linux configuration contract.

## Normal workflow

1. Connect and unlock the Android device.
2. Double-click `Build-And-Install-Android.bat`.
3. The dashboard refreshes each saved project and displays its **Git**, **Local Build**, and **Device** state.
4. Select a project and use **Sync & Run** for the normal development loop, or choose an explicit lower-level action when needed.
5. Follow live output in the dashboard while the operation runs. After Build & Install or Sync & Run finishes, project status refreshes for additional work.

The available actions are:

- **Sync & Run** — safely update Git when needed, rebuild stale/missing Gradle APKs, run Godot/custom builders to validate their dependencies, install only when the device differs, and optionally launch the app;
- **Build & Install** — always run the configured build, install the selected APK, and optionally launch it;
- **Git Pull** — explicitly run the safe fast-forward-only repository update;
- **Refresh Status** — refresh Git remote state, local APK freshness, and device comparison;
- **Settings...** — configure persistent project-specific defaults including a preferred device;
- **Scan Device...** — show device/APK comparison details for all saved projects;
- **Reports...** — inspect previous build/install logs;
- **Add... / Remove** — manage remembered repository paths.

The dashboard is resizable and scales with Windows display settings. It uses a distinct phone/build/install icon in the window, taskbar, and notification area so it is easy to distinguish from a generic PowerShell window. Double-clicking a project and pressing Enter both run the primary **Sync & Run** action. **Build & Install** remains available when an unconditional rebuild is wanted.

## Start menu and taskbar shortcut

Double-click `Install-Start-Menu-Shortcut.bat` once to install a per-user **Android Build and Install** shortcut. It uses the tool's own icon and does not require administrator access.

To pin it on Windows 11:

1. Open Start and search for **Android Build and Install**.
2. Right-click the result and choose **Pin to taskbar**. If Windows puts the action under a submenu, choose **More**, then **Pin to taskbar**.

You can also launch the dashboard normally, right-click its distinct taskbar icon while it is running, and choose **Pin to taskbar**. The dashboard supplies Windows with a stable application identity, relaunch command, display name, and icon resource, so the pinned item starts this tool rather than a generic PowerShell window.

The shortcut points to this checkout. If the repository is moved, run the installer again from its new location. To remove the Start menu shortcut, run:

```powershell
.\Install-AndroidBuildInstallShortcut.ps1 -Remove
```

### Operation output and cancellation

Sync & Run, Build & Install, and the explicit Git Pull action run in the background while the dashboard remains open for the entire operation. The **Operation output** panel streams PowerShell, Gradle, Git, and ADB output; **Copy Output** copies the visible transcript for troubleshooting. The normal completion, failure, or cancellation result remains visible in the dashboard instead of closing the window.

Use **Cancel** to stop the active PowerShell process and its child process tree, including a running Gradle or ADB command. Closing the dashboard during an operation asks for confirmation before requesting the same cancellation. Dashboard output is bounded so a very large Gradle transcript does not consume memory indefinitely; the complete build/install output remains in the saved report.

Build stages execute inside a single logging wrapper rather than a nested redirected PowerShell process. When Gradle starts a persistent daemon, the dashboard waits for the actual build/install process—not for output handles inherited by that daemon—so a successful install can complete immediately while the reusable Gradle daemon remains available for later builds.

Background dashboard operations never wait for hidden console input. If multiple build roots, devices, or APKs require a choice, the operation stops with an actionable message directing you to select a narrower project folder or save the appropriate project setting.

The notification-area icon remains available while the dashboard is running. Double-click it or choose **Open Dashboard** to restore and activate the window. Its menu can cancel the current operation or status refresh, and a notification reports operation completion when the dashboard is not running a UI test.

## Project status dashboard

The main project list contains these live status columns:

### Git

Examples include:

- **Current** — local branch matches its upstream;
- **Behind N** — upstream has commits that can potentially be fast-forwarded;
- **Ahead N** — local branch has commits not present upstream;
- **Diverged A/B** — both local and upstream have unique commits;
- **Dirty** — tracked or untracked local changes are present;
- **Detached** / **No upstream** / **Fetch failed** — Git state needs explicit attention.

A full **Refresh Status** performs `git fetch --quiet` to update remote-tracking information. It never merges, resets, checks out, or changes the working tree.

### Local Build

Typical states are:

- **Fresh** — a usable local APK exists and no non-generated project file is newer than it;
- **Stale** — at least one project input is newer than the local APK;
- **No APK** — no local debug APK exists yet;
- **Ambiguous** — multiple APK outputs exist and no deterministic target can be selected;
- **Preferred missing** — the configured preferred APK is not currently present.

Fresh/stale detection is deliberately conservative. Generated/build/cache directories such as `.git`, `.gradle`, `.idea`, `build`, `node_modules`, and `out` are ignored; other project files are treated as potential inputs so asset changes are not missed.

### Device

Examples include:

- **Same** — the installed APK and selected local APK have identical SHA-256 hashes;
- **Different** — the app is installed but its APK bytes differ;
- **Not installed**;
- **No local build**;
- **No device**;
- **Choose device** — multiple authorized devices are attached and no preferred device has been saved;
- **Preferred absent** — the remembered device is not currently connected/authorized;
- **Unknown** — an exact comparison cannot safely be made.

Status refreshes run in the background one project at a time, so the dashboard remains responsive. Existing results appear immediately as cached rows; the **Checked** column changes from **Queued** to a check time as each project completes. The upper-right status text shows overall progress. **Cancel Refresh** stops the current status subprocess and leaves completed rows intact, and an unresponsive project check is cancelled after 60 seconds instead of freezing the whole dashboard.

Hovering a status row shows more detailed Git/build/device diagnostics.

## Sync & Run

**Sync & Run** is the optimized one-click path. It performs these checks/actions in order:

1. refresh Git remote-tracking state and validate the repository;
2. validate that the target Android device is connected before doing an expensive build;
3. when the clean branch is behind its upstream, update it with `git pull --ff-only`;
4. inspect the local APK;
5. rebuild only when the APK is missing or stale;
6. compare the resulting local APK with the installed APK;
7. skip installation when the SHA-256 hashes already match;
8. otherwise install with `adb install -r`;
9. launch the app when auto-launch is enabled.

Examples of valid optimized paths include:

```text
Current Git -> Fresh APK -> Same on device -> Launch only
```

```text
Behind upstream -> Fast-forward pull -> Stale APK -> Build -> Install -> Launch
```

```text
Current Git -> Fresh APK -> Not installed -> Install -> Launch
```

Sync & Run stops rather than guessing when safety or targeting is ambiguous. In particular it stops on dirty/diverged Git state, unavailable remembered devices, or ambiguous APK selection. The explicit **Build & Install**, **Git Pull**, and **Settings...** actions remain available for handling those cases deliberately.

Projects that are not Git repositories can still use Sync & Run; the Git update stage is simply skipped.

## Drag and drop

Drag an Android repository or project folder onto `Build-And-Install-Android.bat` in File Explorer.

The dragged path is used immediately, remembered for future sessions, and **Build & Install** starts in the dashboard using saved per-project settings.

Both root-level and nested Android layouts are supported. For example:

```text
chatturanga/
    gradlew.bat
```

and:

```text
prism-break/
    android/
        gradlew.bat
```

The tool searches for `gradlew.bat` in the selected directory and up to two directory levels below it. If multiple Gradle roots exist, explicit Build & Install may ask which one to use; Sync & Run treats an ambiguous project layout as a condition requiring attention.

## Saved projects

Remembered repository paths are stored per Windows user at:

```text
%LOCALAPPDATA%\WindowsTools\android-build-install\projects.json
```

The most recently used project moves to the top. Paths that no longer exist are omitted from the dashboard. Removing a project from the dashboard does not modify or delete the repository.

## Per-project settings

Click **Settings...** for the selected project. Settings are stored outside Git at:

```text
%LOCALAPPDATA%\WindowsTools\android-build-install\project-preferences.json
```

Existing preference files are backward compatible; newly added fields simply use their normal defaults until configured.

### Gradle task

Default:

```text
assembleDebug
```

This can be changed for projects that use another assemble task, for example:

```text
assembleDemoDebug
```

### Preferred APK

When a project produces several debug APKs, a preferred APK can be stored so Build & Install, Scan Device, dashboard status, and Sync & Run all use the same deterministic target.

The path can be absolute or relative to the saved repository path. A relative path is recommended because it remains valid if the entire repository tree is moved together.

For Prism Break, the conventional preferred APK is:

```text
android\app\build\outputs\apk\debug\app-debug.apk
```

If a configured preferred APK is missing, the dashboard reports **Preferred missing**. Explicit Build & Install may fall back to its APK chooser; Sync & Run stops and asks for the preference/layout to be corrected rather than guessing.

### JAVA_HOME

A project-specific JDK directory can be selected. When configured, the tool sets `JAVA_HOME` for that build before invoking the project's Gradle wrapper.

When blank, Java resolution follows the normal environment:

1. existing `JAVA_HOME`;
2. `java.exe` on `PATH`.

### Preferred device

A project can remember one ADB device serial. Click **Detect...** in Settings to list currently connected/authorized devices and choose one; the serial is stored with that project's preferences.

This is especially useful when more than one phone/tablet/emulator is attached. Build & Install, dashboard status, Scan Device, and Sync & Run then target the remembered device instead of prompting or guessing.

Leave the field blank to retain automatic behavior when only one authorized device is attached.

### Auto-launch

When enabled, a successful install is followed by an attempt to launch the installed package's launcher activity through ADB. Sync & Run also uses this preference when it determines that installation can be skipped: an already-current app can be launched without rebuilding or reinstalling it.

The APK package ID is read with Android Build-Tools. Auto-launch failure is treated as a warning after a successful installation.

## Git Pull

Select a project and click **Git Pull** to update its repository explicitly.

The action deliberately uses:

```text
git pull --ff-only
```

and has conservative safety rules:

- the selected path must be inside a Git repository;
- the current branch must have an upstream tracking branch;
- detached HEAD is rejected;
- any tracked or untracked working-tree change causes the pull to stop;
- no automatic stash, merge commit, reset, checkout, or conflict resolution is performed;
- non-fast-forward pulls fail without changing history.

Sync & Run uses the same update helper when its status preflight determines that a clean project is behind its upstream.

## Build and install behavior

The default build command is:

```text
gradlew.bat assembleDebug --stacktrace
```

After a successful build the tool searches Android module output directories under:

```text
build\outputs\apk
```

If there is one debug APK it is selected automatically. When several exist, the saved preferred APK is used if it exactly matches a produced APK; otherwise explicit Build & Install asks which one to install.

Installation uses:

```text
adb -s <device-serial> install -r <apk>
```

`-r` replaces an existing installation while preserving app data when Android permits the update.

The internal build/install runner also supports separate build-only, install-only, and launch-only stages. Sync & Run uses those stages to avoid redundant work; normal **Build & Install** retains the familiar full build/install behavior.

The tool does **not** automatically uninstall an app when Android reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Uninstalling normally removes local app data, so that remains an explicit user action.

## Device scan

Click **Scan Device...** to compare existing local debug APKs with packages currently installed on the appropriate attached device. The scan does not rebuild or install anything.

Results include **Same**, **Different**, **Not installed**, **No local build**, and **Unknown**. The scanner identifies package IDs using Android Build-Tools, queries the installed package with ADB, temporarily pulls a single installed APK when possible, computes SHA-256 hashes with the built-in .NET cryptography provider, and removes the temporary copy afterward.

Split APK installations and other cases where byte-for-byte comparison is not reliable are reported as **Unknown** rather than guessed.

## Reports and failure logs

Each build/install stage is recorded under:

```text
%LOCALAPPDATA%\WindowsTools\android-build-install\logs
```

Reports include:

- selected project;
- Gradle task;
- preferred APK preference;
- JDK override;
- preferred/explicit device serial;
- auto-launch setting;
- whether build/install stages were skipped;
- Gradle output when a build ran;
- ADB install/launch output when those stages ran;
- final exit code.

Use **Reports...** to browse and open previous runs. Dashboard-managed failures remain visible in Operation output and link to the saved reports without opening a competing window. Standalone command-line runs retain the existing failure dialog and automatic Notepad behavior.

## Finding ADB

The tool does not require `adb` to be on `PATH`. It checks, in order:

1. `sdk.dir` in the selected Gradle project's `local.properties`;
2. `ANDROID_SDK_ROOT`;
3. `ANDROID_HOME`;
4. `%LOCALAPPDATA%\Android\Sdk`;
5. `adb.exe` on `PATH`.

## Device handling

- A remembered preferred device is used when configured and available.
- With no preference and one authorized device, that device is selected automatically.
- With no preference and multiple authorized devices, explicit Build & Install can ask which target to use; dashboard status reports **Choose device**, and Sync & Run asks you to save a preferred device first.
- An unauthorized/offline/missing preferred device causes a clear stop rather than silently selecting another device.

## Command-line use

The compatibility entrypoint remains:

```powershell
.\Build-And-Install-Android.ps1 -Project "C:\src\chatturanga"
```

Optional arguments include:

```powershell
.\Build-And-Install-Android.ps1 `
    -Project "C:\src\some-app" `
    -GradleTask "assembleDemoDebug" `
    -PreferredApk "app\build\outputs\apk\demo\debug\app-demo-debug.apk" `
    -JavaHome "C:\Program Files\Android\Android Studio\jbr" `
    -DeviceSerial "DEVICE_SERIAL" `
    -AutoLaunch
```

Direct command-line calls do not use the saved-project dashboard or persistent per-project preferences unless those values are explicitly supplied.

## Safety characteristics

- project source remains untouched by build/install operations;
- each project uses its own Gradle wrapper;
- Sync & Run never stashes, resets, discards, checks out, or auto-merges Git work;
- Git remote refresh uses fetch only; repository updating uses `git pull --ff-only` only when status is safe;
- installation never starts when a required Gradle build fails;
- the tool never automatically uninstalls an Android application;
- `adb install -r` is used to preserve app data where Android permits it;
- APK/device comparison is read-only except for a temporary local copy that is removed afterward;
- ambiguous APK/device/Git states are surfaced rather than guessed;
- saved projects and preferences live under the Windows user's local application-data directory, outside Git repositories;
- build/install diagnostics are preserved as timestamped reports.

## Developer validation

Run the lightweight integration check from this directory with Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-AndroidBuildInstall.ps1
```

It uses an isolated temporary project and state directory; no Android device,
real JDK, Gradle download, or additional test framework is required. The check
covers PowerShell parsing, taskbar identity and Start menu shortcut creation,
loading the multi-size app/tray icon, a configured `JAVA_HOME`, paths containing
spaces, a successful up-to-date build becoming fresh, scanner parameter binding,
dashboard and settings UI creation/resizing, asynchronous dashboard operation
completion, cancellation of an exact child process tree, bounded completion when
a persistent descendant inherits an output handle, progressive status refresh,
and a non-destructive expected failure path.

## Possible future improvements

- optional test/lint tasks in Sync & Run before installation;
- configurable status-refresh timeouts for unusually large repositories;
- richer Android App Bundle / split-install workflows;
- optional per-project launch activity override for apps without a conventional launcher activity.

Backend regression tests (also run by the Windows CI workflow):

```powershell
.\Test-AndroidBuildBackends.ps1
```

The Git column includes the checked-out branch alongside its status, for example
`main | Current` or `feature/camera-flip | Dirty`. Detached checkouts show
`detached @ <short SHA>`. Hover over the row/cell to read the full branch name
and status details if the column is truncated. Branch identity is local and
remains available when remote or build-configuration checks fail.
