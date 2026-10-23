# Local validation instead of GitHub Actions

- Linux/WSL: `bash scripts/check-linux.sh`. Runs DroidRun syntax, Python unit tests, desktop launcher path-with-spaces and symlink regressions, plus Qt offscreen smoke. Requires Python 3.12 and Qt's platform libraries (Ubuntu: `libegl1`).
- Windows PowerShell: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/check-windows.ps1`. Runs DroidRun backend/install checks, Node 22 Codex Usage Meter tests and meter selftest, Kindle Python 3.11 tests, and Windows launcher parsing.

The four hosted workflow YAML files are removed. Validate on each platform separately; no local execution has yet been verified. Record exact source SHA and output before approving a PR. The Linux script installs only into a repository-local venv; Windows assumes the relevant runtimes are already installed.
