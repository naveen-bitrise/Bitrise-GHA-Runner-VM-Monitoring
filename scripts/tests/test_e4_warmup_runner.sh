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

# Must use $HOME as the default (works on any OS/user)
if grep -q 'RUNNER_HOME="$HOME"' "$WARMUP"; then
  pass "RUNNER_HOME defaults to \$HOME (portable)"
else
  fail "RUNNER_HOME does not default to \$HOME"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
