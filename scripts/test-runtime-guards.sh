#!/usr/bin/env bash
# Fast, dependency-free regressions for the Linux validator's version gates.
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fixture="$scratch/checkout"
mkdir -p "$fixture/scripts" "$fixture/tools/DroidRun-Linux"
cp "$root/scripts/check-linux.sh" "$fixture/scripts/check-linux.sh"

# The selected interpreter is rejected before any venv or package installation.
if PYTHON=/bin/false bash "$fixture/scripts/check-linux.sh" >"$scratch/selected.log" 2>&1; then
  echo "A non-3.12 selected Python was accepted" >&2
  exit 1
fi
grep -Fq "Python 3.12 required" "$scratch/selected.log"
test ! -e "$fixture/tools/DroidRun-Linux/.venv"

# A preexisting incompatible venv must not silently override PYTHON.
mkdir -p "$fixture/tools/DroidRun-Linux/.venv/bin"
cat > "$fixture/tools/DroidRun-Linux/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
# Mimic an incompatible preexisting venv; pip must never be reached.
if [[ "${1:-}" == "-c" ]]; then exit 1; fi
echo "Validation ran with the incompatible venv" >&2
exit 87
EOF
chmod +x "$fixture/tools/DroidRun-Linux/.venv/bin/python"
if PYTHON=/bin/true bash "$fixture/scripts/check-linux.sh" >"$scratch/venv.log" 2>&1; then
  echo "An incompatible preexisting venv was accepted" >&2
  exit 1
fi
grep -Fq "Stale DroidRun Linux venv" "$scratch/venv.log"
if grep -Fq "Validation ran with the incompatible venv" "$scratch/venv.log"; then
  echo "Attempted package/test execution with incompatible venv" >&2
  exit 1
fi

echo "Linux interpreter rejection regressions passed"
