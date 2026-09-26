# Developer Tools

Small, inspectable utilities for recurring development and workstation workflows.

The repository is organized as a collection rather than around a single application. Each utility lives in its own directory under `tools/` and documents the platform(s) it supports.

## Tools

| Tool | Platform | Purpose |
| --- | --- | --- |
| `android-build-install` | Windows | Build, synchronize, install, compare, and launch Android development APKs from a Windows dashboard. |
| `android-build-install-linux` | Linux / Ubuntu | Linux counterpart to the Android build/install dashboard, using XDG paths and native Linux tooling conventions. |
| `google-drive-zip-merger` | Windows | Merge the multiple ZIP archives produced by large Google Drive folder downloads into one destination tree. |

## Repository conventions

- Each utility explicitly documents its supported platform(s).
- Keep utilities self-contained under `tools/<tool-name>/`.
- Preserve user data by default and make destructive operations explicit.
- Prefer thin launchers with substantive logic in inspectable implementation code.
- Avoid administrator/root requirements unless they are intrinsic to the task.
- For equivalent tools on multiple platforms, keep safety and workflow semantics aligned even when implementation details differ.
- Use platform-native integration where appropriate: PowerShell/.NET on Windows; XDG conventions and normal Unix process/path semantics on Linux.

See each tool's README for usage details.
