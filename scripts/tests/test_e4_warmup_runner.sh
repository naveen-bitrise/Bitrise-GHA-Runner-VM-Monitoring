#!/bin/bash
# test_e4_warmup_runner.sh — checks warmup_runner.sh uses OS-appropriate runner path

PASS=0
FAIL=0
WARMUP="$(cd "$(dirname "$0")/.." && pwd)/warmup_runner.sh"

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# warmup_runner.sh must not hardcode the macOS vagrant path
if grep -q 'RUNNER_HOME' "$WARMUP"; then
  pass "warmup_runner.sh uses RUNNER_HOME variable"
else
  fail "warmup_runner.sh hardcodes runner path (missing RUNNER_HOME)"
fi

# Must default to /Users/vagrant on macOS
if grep -q '/Users/vagrant' "$WARMUP"; then
  pass "macOS default /Users/vagrant present"
else
  fail "macOS default /Users/vagrant missing"
fi

# Must have a Linux default (/home/runner)
if grep -q '/home/runner' "$WARMUP"; then
  pass "Linux default /home/runner present"
else
  fail "Linux default /home/runner missing"
fi

# Must have a uname check for OS detection
if grep -q 'uname' "$WARMUP"; then
  pass "warmup_runner.sh has uname OS detection"
else
  fail "warmup_runner.sh missing uname OS detection"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
