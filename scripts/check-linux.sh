#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/tools/DroidRun-Linux"
PYTHON="${PYTHON:-python3}"
if [[ ! -x .venv/bin/python ]]; then "$PYTHON" -m venv .venv; fi
.venv/bin/python -m pip install -e .
.venv/bin/python -m py_compile android_build_install_linux/*.py
bash -n droidrun install-desktop.sh
.venv/bin/python -m unittest discover -s tests -v
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
test_home="$scratch/home with spaces"
mkdir -p "$test_home"
HOME="$test_home" XDG_DATA_HOME="$test_home/.local/share" ./install-desktop.sh
desktop="$test_home/.local/share/applications/droidrun.desktop"
grep -F 'Exec="' "$desktop"
test -L "$test_home/.local/bin/droidrun"
test_home="$scratch/symlink home"
data="$test_home/data"
venv="$data/android-build-install/venv"
mkdir -p "$venv/bin" "$test_home/.local/bin"
ln -s "$PWD/droidrun" "$test_home/.local/bin/droidrun"
cat > "$venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-c" ]]; then exit 1; fi
if [[ "$1 $2 $3" == "-m pip install" && "$4" == "--upgrade" ]]; then exit 0; fi
if [[ "$1 $2 $3 $4" == "-m pip install -e" ]]; then
  printf '%s\n' "$5" > "$CAPTURE"
  exit 0
fi
exit 0
EOF
chmod +x "$venv/bin/python"
CAPTURE="$scratch/root-capture.txt" HOME="$test_home" XDG_DATA_HOME="$data" "$test_home/.local/bin/droidrun"
grep -Fx "$PWD" "$scratch/root-capture.txt"
QT_QPA_PLATFORM=offscreen .venv/bin/python -c "from PySide6.QtWidgets import QApplication; from android_build_install_linux.app import MainWindow; app=QApplication([]); w=MainWindow(); w.close()"
temp_project="$scratch/project path"
temp_config="$scratch/config path"
mkdir -p "$temp_project" "$temp_config"
QT_QPA_PLATFORM=offscreen XDG_CONFIG_HOME="$temp_config" PROJECT="$temp_project" .venv/bin/python - <<'PY'
import os
from PySide6.QtWidgets import QApplication
from android_build_install_linux.app import MainWindow
app = QApplication([])
window = MainWindow(initial_project=os.environ["PROJECT"])
assert not window.busy
assert window.selected_project() == os.path.realpath(os.environ["PROJECT"])
window.close()
PY
echo "DroidRun Linux validation passed"
