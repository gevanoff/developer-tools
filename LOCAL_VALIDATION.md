# Local validation instead of GitHub Actions

- Linux/WSL: `bash scripts/check-linux.sh`. Runs DroidRun syntax, Python unit tests, desktop launcher path-with-spaces and symlink regressions, plus Qt offscreen smoke. Requires Python 3.12 and Qt's platform libraries (Ubuntu: `libegl1`).
- Windows PowerShell: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/check-windows.ps1`. Runs DroidRun backend/install checks, Node 22 Codex Usage Meter tests and meter selftest, Kindle Python 3.11 tests, and Windows launcher parsing.

The four hosted workflow YAML files are removed. Validate on each platform separately; no complete local Linux/Windows execution has yet been verified. Record exact source SHA, tool versions and output before approving a PR. The Linux script installs only into a repository-local venv and rejects both a selected interpreter and a reused venv unless each is Python 3.12. If a stale venv is reported, remove it deliberately and rerun. Windows checks reject Node versions other than 22 and Python versions other than 3.11 *before* running utility tests. Neither script automatically downloads another runtime.

A lightweight, dependency-free Linux regression harness is available via `bash scripts/test-runtime-guards.sh`. It checks rejection of a wrong selected interpreter and a stale venv in a disposable fixture, without installing packages. The full Linux validator also invokes it before dependency installation. This harness is not a substitute for the full Linux/Windows suites and real desktop/device acceptance.
