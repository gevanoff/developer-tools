# AGENTS.md

## Repository purpose

This repository contains small, practical developer utilities intended to remove repetitive manual workflows across supported desktop platforms. Prefer tools that are easy to inspect, easy to run, and minimally dependent on third-party software.

## Platforms

- A utility must explicitly document its supported platform(s).
- Windows-specific tools should preserve Windows 11 compatibility and prefer Windows PowerShell 5.1 unless PowerShell 7+ is genuinely required.
- Linux-specific tools should follow normal Linux/XDG conventions and avoid requiring root unless the task genuinely needs it.
- Cross-platform tools should keep shared behavior platform-neutral and isolate platform-specific integration behind clear boundaries.
- Prefer functionality already provided by the target OS/runtime when it is adequate for the task.

## Structure

Each utility belongs under:

```text
tools/<tool-name>/
```

A utility directory should normally contain:

- its implementation;
- a thin launcher when double-click/application-menu/drag-and-drop operation is useful;
- a `README.md` explaining purpose, supported platforms, usage, behavior, and important safety characteristics.

Avoid coupling independent utilities to each other unless there is a clear reusable library boundary.

## Design principles

1. Optimize for a short path from recurring annoyance to reliable automation.
2. Keep behavior visible and understandable; do not hide destructive operations.
3. Preserve user data by default. Deletion, replacement, and cleanup should be explicit, confirmed, or otherwise strongly justified.
4. Prefer idempotent or safely repeatable behavior where practical.
5. Quote paths correctly and expect spaces in filenames and directory names.
6. Use nonzero exit codes for failures so launchers and future automation can detect them.
7. Validate inputs before changing files.
8. When processing archives or externally supplied paths, defend against path traversal.
9. Avoid administrator/root privileges unless the utility genuinely requires them.
10. Keep launchers thin; substantive logic belongs in the implementation.
11. When equivalent behavior exists on multiple platforms, preserve the behavioral contract and safety semantics rather than allowing platform implementations to drift silently.

## Changes and validation

For changes to a utility:

- exercise its successful path;
- exercise at least one expected failure path;
- check behavior with paths containing spaces;
- verify that failure does not trigger cleanup intended only after success;
- update the utility README when user-visible behavior changes;
- exercise platform-specific integration on the platform it targets when practical.

When automated tests are warranted, keep them close to the utility and document any additional test dependency. Do not introduce a large framework solely for a trivial script.

## Git workflow

Use focused branches and pull requests for substantive changes. Keep unrelated utilities out of the same change unless the change is intentionally repository-wide.
