#!/bin/bash
# test_e1_collect_metrics.sh — tests for Linux support in collect_metrics.sh
# Runs on macOS too (checks structure); checks metric values on Linux.

PASS=0
FAIL=0
COLLECT="$(cd "$(dirname "$0")/.." && pwd)/collect_metrics.sh"

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMPDIR_TEST=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

# --- Mock /proc files ---
MOCK_PROC="$TMPDIR_TEST/proc"
mkdir -p "$MOCK_PROC"

echo "0.52 0.58 0.59 1/234 12345" > "$MOCK_PROC/loadavg"

# MemFree=8000 MB, Used=5375 MB, Cached=2625 MB, SwapUsed=1024 MB, SwapFree=1024 MB
cat > "$MOCK_PROC/meminfo" <<'MEMEOF'
MemTotal:       16384000 kB
MemFree:         8192000 kB
Buffers:          512000 kB
Cached:          2048000 kB
SReclaimable:     128000 kB
SwapTotal:       2097152 kB
SwapFree:        1048576 kB
MEMEOF

# /proc/stat before and after — delta: user=100 nice=20 sys=50 idle=100 iowait=10 → total=280
# cpu_user ≈ 35.71%  cpu_system ≈ 17.86%  cpu_idle ≈ 35.71%  cpu_nice ≈ 7.14%
echo "cpu  1000 200 500 8000 100 0 0 0 0 0" > "$TMPDIR_TEST/stat_before"
echo "cpu  1100 220 550 8100 110 0 0 0 0 0" > "$TMPDIR_TEST/stat_after"

# --- Run 1 sample (MAX_SAMPLES=1 terminates the loop after 1 row) ---
OUT="$TMPDIR_TEST/output.csv"

# Run with a portable background-kill timeout (no GNU timeout needed on macOS)
MAX_SAMPLES=1 INTERVAL=0 \
  PROC_DIR="$MOCK_PROC" \
  PROC_STAT_BEFORE="$TMPDIR_TEST/stat_before" \
  PROC_STAT_AFTER="$TMPDIR_TEST/stat_after" \
  bash "$COLLECT" "$OUT" 2>/dev/null &
SCRIPT_PID=$!
# Wait up to 8 seconds; a working MAX_SAMPLES=1 with INTERVAL=0 exits in < 1s
for _i in 1 2 3 4 5 6 7 8; do
  sleep 1
  kill -0 "$SCRIPT_PID" 2>/dev/null || break
done
kill "$SCRIPT_PID" 2>/dev/null || true
wait "$SCRIPT_PID" 2>/dev/null; EXIT_CODE=$?
# exit 143 = killed by us (SIGTERM) = timed out = MAX_SAMPLES not supported
[[ $EXIT_CODE -eq 143 ]] && EXIT_CODE=124

if [[ $EXIT_CODE -eq 0 ]]; then
  pass "Script exits 0 with MAX_SAMPLES=1"
else
  fail "Script exit code: expected 0, got $EXIT_CODE (124 = timed out = MAX_SAMPLES not supported yet)"
fi

# --- CSV structure checks (macOS and Linux) ---
if [[ -f "$OUT" ]]; then
  line_count=$(wc -l < "$OUT" | tr -d ' ')
  if [[ "$line_count" -eq 2 ]]; then
    pass "CSV has header + 1 data row"
  else
    fail "CSV line count: expected 2, got $line_count"
  fi

  expected_header="timestamp,cpu_user,cpu_system,cpu_idle,cpu_nice,memory_used_mb,memory_free_mb,memory_cached_mb,load1,load5,load15,swap_used_mb,swap_free_mb"
  header=$(head -1 "$OUT")
  if [[ "$header" == "$expected_header" ]]; then
    pass "CSV header matches expected columns"
  else
    fail "CSV header mismatch: '$header'"
  fi

  data_col_count=$(tail -1 "$OUT" | tr ',' '\n' | wc -l | tr -d ' ')
  if [[ "$data_col_count" -eq 13 ]]; then
    pass "Data row has 13 fields"
  else
    fail "Data row field count: expected 13, got $data_col_count"
  fi

  # All fields after timestamp must be numeric
  data_row=$(tail -1 "$OUT")
  bad_fields=0
  idx=0
  IFS=',' read -ra fields <<< "$data_row"
  for field in "${fields[@]}"; do
    idx=$((idx+1))
    [[ $idx -eq 1 ]] && continue  # skip timestamp
    if ! echo "$field" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
      fail "Field $idx is not numeric: '$field'"; bad_fields=$((bad_fields+1))
    fi
  done
  [[ $bad_fields -eq 0 ]] && pass "All numeric fields are valid numbers"

else
  fail "Output CSV was not created"
fi

# --- Linux-only value checks ---
if [[ "$(uname)" != "Darwin" && -f "$OUT" ]]; then
  data=$(tail -1 "$OUT")
  cpu_user=$(echo  "$data" | cut -d',' -f2)
  cpu_system=$(echo "$data" | cut -d',' -f3)
  cpu_idle=$(echo  "$data" | cut -d',' -f4)
  mem_free=$(echo  "$data" | cut -d',' -f7)
  load1=$(echo     "$data" | cut -d',' -f9)
  swap_free=$(echo "$data" | cut -d',' -f13)

  echo "$cpu_user" | grep -qE '^3[45]\.' \
    && pass "Linux cpu_user ≈ 35.71% (got $cpu_user)" \
    || fail "Linux cpu_user: expected ~35.71, got '$cpu_user'"

  echo "$cpu_system" | grep -qE '^1[78]\.' \
    && pass "Linux cpu_system ≈ 17.86% (got $cpu_system)" \
    || fail "Linux cpu_system: expected ~17.86, got '$cpu_system'"

  echo "$cpu_idle" | grep -qE '^3[45]\.' \
    && pass "Linux cpu_idle ≈ 35.71% (got $cpu_idle)" \
    || fail "Linux cpu_idle: expected ~35.71, got '$cpu_idle'"

  [[ "$mem_free" == "8000" ]] \
    && pass "Linux memory_free_mb = 8000 MB" \
    || fail "Linux memory_free_mb: expected 8000, got '$mem_free'"

  [[ "$load1" == "0.52" ]] \
    && pass "Linux load1 = 0.52" \
    || fail "Linux load1: expected 0.52, got '$load1'"

  [[ "$swap_free" == "1024" ]] \
    && pass "Linux swap_free_mb = 1024 MB" \
    || fail "Linux swap_free_mb: expected 1024, got '$swap_free'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
