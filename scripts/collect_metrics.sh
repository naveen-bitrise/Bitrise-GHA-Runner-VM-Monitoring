#!/bin/bash
# collect_metrics.sh - Collects system metrics on macOS and Linux every N seconds

OUTPUT_FILE="${1:-/tmp/gha-monitoring/monitoring-data.csv}"
INTERVAL="${INTERVAL:-5}"
MAX_SAMPLES="${MAX_SAMPLES:-0}"   # 0 = run forever; >0 = stop after N samples

# Override /proc path for testing on macOS with mock data
PROC_DIR="${PROC_DIR:-/proc}"
# Inject pre-read /proc/stat snapshots for testing (skips sleep between reads)
PROC_STAT_BEFORE="${PROC_STAT_BEFORE:-}"
PROC_STAT_AFTER="${PROC_STAT_AFTER:-}"

# Create directory if it doesn't exist
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Write CSV header
echo "timestamp,cpu_user,cpu_system,cpu_idle,cpu_nice,memory_used_mb,memory_free_mb,memory_cached_mb,load1,load5,load15,swap_used_mb,swap_free_mb" > "$OUTPUT_FILE"

echo "Starting monitoring - writing to $OUTPUT_FILE"
echo "Press Ctrl+C to stop"

# Trap SIGTERM and SIGINT for graceful shutdown
trap 'echo "Monitoring stopped"; exit 0' SIGTERM SIGINT

SAMPLE_COUNT=0

while true; do
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

    if [[ "$(uname)" == "Darwin" ]]; then
        # ------------------------------------------------------------------ macOS

        # CPU — iostat two-sample (-c 2 -w 1) already normalized to 0-100%
        # fields: $10=user $11=system $12=idle
        CPU_DATA=$(iostat -c 2 -w 1 | tail -n 1)
        CPU_USER=$(echo "$CPU_DATA"   | awk '{printf "%.2f", $10}')
        CPU_SYSTEM=$(echo "$CPU_DATA" | awk '{printf "%.2f", $11}')
        CPU_IDLE=$(echo "$CPU_DATA"   | awk '{printf "%.2f", $12}')
        CPU_NICE=0  # not easily available on macOS

        # Memory — vm_stat + pagesize
        VM_STAT=$(vm_stat)
        PAGE_SIZE=$(pagesize)
        PAGES_FREE=$(echo "$VM_STAT"     | grep "Pages free"       | awk '{print $3}' | tr -d '.')
        PAGES_ACTIVE=$(echo "$VM_STAT"   | grep "Pages active"     | awk '{print $3}' | tr -d '.')
        PAGES_INACTIVE=$(echo "$VM_STAT" | grep "Pages inactive"   | awk '{print $3}' | tr -d '.')
        PAGES_WIRED=$(echo "$VM_STAT"    | grep "Pages wired down" | awk '{print $4}' | tr -d '.')

        MEMORY_FREE_MB=$((PAGES_FREE * PAGE_SIZE / 1024 / 1024))
        MEMORY_USED_MB=$(((PAGES_ACTIVE + PAGES_WIRED) * PAGE_SIZE / 1024 / 1024))
        MEMORY_CACHED_MB=$((PAGES_INACTIVE * PAGE_SIZE / 1024 / 1024))

        # Load average — sysctl
        LOAD_AVG=$(sysctl -n vm.loadavg | awk '{print $2","$3","$4}')

        # Swap — sysctl
        SWAP_INFO=$(sysctl vm.swapusage | awk '{print $4,$7}')
        SWAP_USED=$(echo "$SWAP_INFO" | awk '{print $1}' | tr -d 'M')
        SWAP_FREE=$(echo "$SWAP_INFO" | awk '{print $2}' | tr -d 'M')
        SWAP_USED=${SWAP_USED:-0}
        SWAP_FREE=${SWAP_FREE:-0}

        sleep "$INTERVAL"

    else
        # ------------------------------------------------------------------ Linux

        # CPU — two /proc/stat reads separated by INTERVAL seconds
        # Allow test injection via PROC_STAT_BEFORE / PROC_STAT_AFTER
        local_stat_file="${PROC_DIR}/stat"

        if [[ -n "$PROC_STAT_BEFORE" ]]; then
            stat1_line=$(head -1 "$PROC_STAT_BEFORE")
        else
            stat1_line=$(head -1 "$local_stat_file")
        fi

        # Memory, load, swap — fast reads, done during the sleep window
        # /proc/meminfo: values in kB
        mem_total=$(grep '^MemTotal:'     "${PROC_DIR}/meminfo" | awk '{print $2}')
        mem_free=$(grep  '^MemFree:'      "${PROC_DIR}/meminfo" | awk '{print $2}')
        buffers=$(grep   '^Buffers:'      "${PROC_DIR}/meminfo" | awk '{print $2}')
        cached=$(grep    '^Cached:'       "${PROC_DIR}/meminfo" | awk '{print $2}')
        sreclaimable=$(grep '^SReclaimable:' "${PROC_DIR}/meminfo" | awk '{print $2}')
        swap_total=$(grep '^SwapTotal:'   "${PROC_DIR}/meminfo" | awk '{print $2}')
        swap_free_kb=$(grep '^SwapFree:'  "${PROC_DIR}/meminfo" | awk '{print $2}')

        MEMORY_FREE_MB=$(( mem_free / 1024 ))
        MEMORY_USED_MB=$(( (mem_total - mem_free - buffers - cached - sreclaimable) / 1024 ))
        MEMORY_CACHED_MB=$(( (buffers + cached + sreclaimable) / 1024 ))
        SWAP_FREE=$(( swap_free_kb / 1024 ))
        SWAP_USED=$(( (swap_total - swap_free_kb) / 1024 ))

        # Load average — /proc/loadavg
        LOAD_AVG=$(awk '{print $1","$2","$3}' "${PROC_DIR}/loadavg")

        # Sleep between stat reads: 1s for CPU delta (matches macOS iostat -w 1),
        # then sleep the remainder to honour INTERVAL.
        if [[ -z "$PROC_STAT_AFTER" ]]; then
            sleep 1
            remaining=$(( INTERVAL - 1 ))
            [[ $remaining -gt 0 ]] && sleep "$remaining"
        fi

        if [[ -n "$PROC_STAT_AFTER" ]]; then
            stat2_line=$(head -1 "$PROC_STAT_AFTER")
        else
            stat2_line=$(head -1 "$local_stat_file")
        fi

        # Parse stat lines: cpu user nice system idle iowait irq softirq steal ...
        read -r _ u1 n1 s1 i1 w1 r1 x1 _ _ _ <<< "$stat1_line"
        read -r _ u2 n2 s2 i2 w2 r2 x2 _ _ _ <<< "$stat2_line"

        du=$(( u2-u1 )); dn=$(( n2-n1 )); ds=$(( s2-s1 ))
        di=$(( i2-i1 )); dw=$(( w2-w1 )); dr=$(( r2-r1 )); dx=$(( x2-x1 ))
        total=$(( du+dn+ds+di+dw+dr+dx ))

        if [[ $total -gt 0 ]]; then
            CPU_USER=$(awk   "BEGIN{printf \"%.2f\", $du*100/$total}")
            CPU_NICE=$(awk   "BEGIN{printf \"%.2f\", $dn*100/$total}")
            CPU_SYSTEM=$(awk "BEGIN{printf \"%.2f\", $ds*100/$total}")
            CPU_IDLE=$(awk   "BEGIN{printf \"%.2f\", $di*100/$total}")
        else
            CPU_USER=0.00; CPU_NICE=0.00; CPU_SYSTEM=0.00; CPU_IDLE=100.00
        fi
    fi

    # Write CSV row
    echo "$TIMESTAMP,$CPU_USER,$CPU_SYSTEM,$CPU_IDLE,$CPU_NICE,$MEMORY_USED_MB,$MEMORY_FREE_MB,$MEMORY_CACHED_MB,$LOAD_AVG,$SWAP_USED,$SWAP_FREE" >> "$OUTPUT_FILE"

    SAMPLE_COUNT=$(( SAMPLE_COUNT + 1 ))
    if [[ "$MAX_SAMPLES" -gt 0 && "$SAMPLE_COUNT" -ge "$MAX_SAMPLES" ]]; then
        break
    fi
done
