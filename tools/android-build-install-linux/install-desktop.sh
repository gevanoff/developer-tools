#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
BIN_DIR="$HOME/.local/bin"

mkdir -p "$APP_DIR" "$BIN_DIR"
ln -sfn "$ROOT/android-build-install" "$BIN_DIR/android-build-install"

cat > "$APP_DIR/android-build-install.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DroidRun
Icon=$ROOT/../android-build-install/assets/droidrun-icon.png
Comment=Build, sync, install, and launch Android projects
Exec="$BIN_DIR/android-build-install" %f
Terminal=false
Categories=Development;
StartupNotify=true
EOF

chmod 0644 "$APP_DIR/android-build-install.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" || true
printf 'Installed %s\n' "$APP_DIR/android-build-install.desktop"
