# Drive Folder Backup

Windows 11 GUI for backing up **multiple arbitrary local directories** to **Google Drive**, without moving the originals into Drive's desktop sync folder. Stores a persistent folder list and an individual remote destination for each selected directory. No Python packages or Google Cloud project are required.

## Prerequisites

- Windows 11 with **Python 3.11+** installed (including `tkinter` and the `pyw` launcher).
- [rclone](https://rclone.org/install/) on `PATH`, or `rclone.exe` in the same directory as `drive_backup.py`.
- An rclone Google Drive remote configured interactively (`rclone config`: `n` for new remote, storage `drive`, complete browser login). The GUI's **Configure...** button opens the same configuration flow in a separate console. **Refresh** discovers only remotes of type `drive`.

Google authentication and credentials are entirely managed by rclone; this app does not request or store passwords or OAuth tokens. The ChatGPT Google Drive connection is **not** shared with locally running applications.

## Run

Double-click `Launch.vbs`, or run this from PowerShell for visible error messages:

```powershell
py -3 .\drive_backup.py
```

Add one or more folders, select the Drive remote and destination root (default `Workstation Backups`), then use **Preview (no changes)** or **Back Up Now**. A console-free GUI requires `pyw.exe` to be available; if the silent launcher appears not to start, use the PowerShell command to see the error.

Optional single-file executable, built on Windows (not required to use the tool):

```powershell
py -3 -m pip install pyinstaller
py -3 -m PyInstaller --noconfirm --onefile --windowed --name DriveFolderBackup drive_backup.py
```

Keep `rclone.exe` on `PATH` (or next to the built `.exe`). This project does not ship an executable or a copy of rclone.

## Backup layout and semantics

For a configured `gdrive:` remote, computer name `CHAINSWORD`, root `Workstation Backups`, and a source `C:\Users\Example\Project A`, the destination is:

```text
gdrive:Workstation Backups/CHAINSWORD/Project A--<12-character-path-hash>/
```

The source directory's contents appear *inside* that destination. The path hash separates otherwise identically named directories, and a repeated run targets the same folder. The computer name is captured in local settings when the tool is first run.

- Uses **`rclone copy`**, never `sync`, `move`, or `delete`. Source files stay untouched, and files already present only on Drive are **not deleted**. Unchanged files are skipped; changed local files update their matching remote files. This is an incremental **copy**, **not** an append-only snapshot: remote revisions are subject to Google Drive retention policy. Keep independent backups of critical data.
- A missing source is reported as an error and skipped; it is never interpreted as a request to delete the remote copy. Other selected directories are still attempted.
- Each run can be previewed without writes using rclone's `--dry-run`. Symlinks are skipped by rclone by default. Files accessible to the user are copied, including hidden files unless rclone configuration excludes them.
- Backups execute in a background thread, showing transfer log lines and supporting Cancel. Cancel terminates the active rclone process, leaving completed uploads in Drive; subsequent Back Up retries incrementally.
- Google Drive storage limits, network interruptions, API quotas, and file changes during a transfer can cause partial results. Check status/log; a zero exit code means rclone completed without reporting an error, **not** a separately verified restore. Test a restore before relying on this as your only backup.

Settings (no secrets) live under `%LOCALAPPDATA%\DeveloperTools\DriveFolderBackup\settings.json`; run logs are in its `logs` directory. If settings are corrupt, the tool reports the problem instead of overwriting them. Sensitive filenames and local source paths may appear in the logs. Do not publish them or rclone's configuration file.

## Tests

```powershell
py -3 -m unittest discover -s tests -v
```

The tests cover stable source mapping, collision separation, remote-root validation, argument safety with spaces, corrupt settings, atomic save, Drive-only remote discovery, and copy behavior with a fake local destination. Live Windows GUI interaction and real Google Drive upload still need acceptance testing on a Windows workstation.
