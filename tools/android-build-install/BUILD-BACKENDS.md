# Godot and custom Android builds

Both the Windows and Ubuntu/Linux dashboards support the same build contract.

| Backend | Discovery | Build | APK selection |
| --- | --- | --- | --- |
| Gradle | `gradlew.bat` / executable `gradlew` | Existing task, default `assembleDebug` | Existing preferred/conventional output policy |
| Godot 4 | `project.godot` | Headless debug export using an Android preset | Exact configured path; default `build/android/app-debug.apk` |
| Custom | `android-build-install.json` with `backend: custom` | Explicit executable plus argument array | Required exact `apk` path |

Discovery searches the selected directory and two levels below it. Select the
specific project when multiple roots exist. A recognized root owns its subtree:
Godot's generated Android Gradle project is not selected as a separate app.
No commands run during discovery, status refresh, or device scanning.

## Godot setup (including akhar-gurmukhi)

1. Install the Godot **4 editor** version required by the project and its matching
   export templates. Use the .NET editor/toolchain for C# projects.
2. In Godot's editor settings, configure the Android SDK and Java SDK paths and
   the debug keystore as required by that Godot version.
3. Open **Project → Export**, add an **Android** preset, and configure it for APK
   output. This creates `export_presets.cfg`. A fresh akhar-gurmukhi checkout
   currently needs this step; the helper reports it explicitly when missing.
4. Add that project folder to the dashboard. Put `godot`/`godot4` on PATH, or set
   the editor executable using **Settings → Godot / custom build**. Windows
   users should prefer the editor's `_console.exe` executable for complete logs.
5. Use **Build & Install**. If multiple Android presets exist, configure `preset`
   with the exact name. The helper never guesses between presets.

The helper invokes the editor with `--headless --path <root> --export-debug
<preset> <apk>`. It does not create export presets, install toolchains, change
signing settings, or enable Godot's optional Gradle build. Configure those in
Godot. Export errors appear in the existing operation log.

Official references:
[command-line exporting](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html#exporting)
and [Android export setup](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html).

## Shared configuration

The settings editor saves `android-build-install.json` in the detected build
root (or the selected folder when creating a custom project). It is also directly
editable. Saving in this dialog is independent of the outer Settings dialog.
Commit portable settings or explicitly ignore machine-local configuration so it
does not leave Git dirty and block Sync & Run. Do not store secrets in this file.

Example Godot configuration:

```json
{
  "version": 1,
  "backend": "godot",
  "preset": "Android",
  "apk": "build/android/app-debug.apk",
  "windows": {
    "executable": "C:/Tools/Godot/Godot_v4.5-stable_win64_console.exe"
  },
  "linux": {
    "executable": "/opt/godot/godot"
  }
}
```

Use your installed Godot version/path. Omit `executable` for PATH discovery and
`preset` when exactly one Android preset exists. Omit the entire configuration
file for default Godot discovery. `backend` accepts `auto`, `gradle`, `godot`, or
`custom`. `auto` prefers Godot when `project.godot` exists, otherwise Gradle.

Custom build example for Flutter:

```json
{
  "version": 1,
  "backend": "custom",
  "executable": "flutter",
  "arguments": ["build", "apk", "--debug"],
  "apk": "build/app/outputs/flutter-apk/app-debug.apk",
  "windows": {"executable": "flutter.bat"}
}
```

The same mechanism supports Unity export scripts, .NET Android, Make, or any
other installed builder that produces a single installable APK. This is a
command adapter, not automatic toolchain installation or framework detection.

| Field | Meaning |
| --- | --- |
| `version` | Required `1` when the configuration file exists |
| `backend` | Optional `auto`; explicit `custom` requires `executable` and `apk` |
| `executable` | Executable path/name; root-local files take precedence over PATH, relative paths resolve from the build root |
| `arguments` | Custom-build string array; one element per argument, no shell splitting |
| `preset` | Godot Android export preset name, case-sensitive |
| `apk` | One exact `.apk` path; relative paths resolve from the build root, absolute paths also work |
| `windows`, `linux` | Objects overriding common fields on that platform |

Commands run with the build root as their working directory and inherit the
environment. The per-project JDK override is applied when set; custom builds do
not otherwise require Java. A build script can be used via `python`, `bash`, or
`powershell.exe` with the script path in `arguments`. The Linux executable must
have its execute bit set. Arguments are not interpreted as a shell command:
pipelines, environment expansion, and multiple commands require an explicit
shell/script. Review project build instructions just as you would a Gradle
wrapper before executing them.

## Output and failure behavior

- Godot/custom builds use the declared APK only. Leave **Preferred APK** blank
  or make it match that output; a conflicting preference is an error.
- AABs and split-APK sets are unsupported by the single-APK `adb install -r`
  workflow. Configure the builder to produce a signed, installable APK.
- The helper creates the output parent directory. After a Godot/custom build,
  a nonempty APK must exist and its modification time or size must change from
  any preexisting output. A builder that intentionally validates/reuses an
  unchanged APK must explicitly update its output timestamp after validation.
- Nonzero build exits, missing/empty/unchanged outputs, and cancellation stop
  before installation. The helper does not delete old APKs on failure.
- Godot exports use the project-file timestamp freshness check, excluding
  generated `.godot/`, `.import/`, and build/cache directories. Newer scripts,
  assets, presets, or build configuration mark the APK **Stale**; a successful
  export marks it **Fresh**. This checks local inputs, not SDK/export-template
  or external dependency changes; use **Build & Install** after changing those.
- Sync & Run always invokes custom builders because their external dependencies
  cannot be inferred. APK hash comparison still skips identical installs.
- Git remains fast-forward-only. Device preferences, logs, cancellation,
  package inspection, launch, and the no-automatic-uninstall policy still apply.
