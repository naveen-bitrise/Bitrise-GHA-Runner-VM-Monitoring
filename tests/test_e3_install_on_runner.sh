#!/bin/bash
# test_e3_install_on_runner.sh — tests for Linux startup support in install_on_runner.sh

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install_on_runner.sh"

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMPDIR_TEST=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

# Create stub scripts the installer tries to copy
for stub in collect_metrics.sh monitor_daemon.sh; do
  echo "#!/bin/bash" > "$TMPDIR_TEST/$stub"
  chmod +x "$TMPDIR_TEST/$stub"
done
# Create a stub plist (only used on macOS)
echo "<plist/>" > "$TMPDIR_TEST/com.gha.monitor.plist"

FAKE_INSTALL_DIR="$TMPDIR_TEST/install"
FAKE_DATA_DIR="$TMPDIR_TEST/data"

# Run install as non-root with SKIP_STARTUP_HINT so it just copies scripts
INSTALL_DIR="$FAKE_INSTALL_DIR" \
  DATA_DIR="$FAKE_DATA_DIR" \
  SCRIPT_DIR="$TMPDIR_TEST" \
  SKIP_STARTUP_HINT=1 \
  bash "$INSTALL_SCRIPT" 2>/dev/null
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
  pass "install_on_runner.sh exits 0"
else
  fail "install_on_runner.sh exit code: expected 0, got $EXIT_CODE"
fi

# Scripts must be installed
for f in collect_metrics.sh monitor_daemon.sh; do
  if [[ -f "$FAKE_INSTALL_DIR/$f" ]]; then
    pass "Installed $f"
  else
    fail "$f not found in install dir"
  fi
done

# Verify the script contains a uname check (Linux path must exist)
if grep -q 'uname' "$INSTALL_SCRIPT" && grep -q -i 'linux\|systemd' "$INSTALL_SCRIPT"; then
  pass "install_on_runner.sh contains Linux/systemd branch"
else
  fail "install_on_runner.sh missing Linux startup branch"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
