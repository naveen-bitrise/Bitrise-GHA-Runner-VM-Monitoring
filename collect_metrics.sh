#!/bin/bash
# collect_metrics.sh - Collects system metrics on macOS every 5 seconds

OUTPUT_FILE="${1:-/tmp/gha-monitoring/monitoring-data.csv}"
INTERVAL=5

# Create directory if it doesn't exist
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Write CSV header
echo "timestamp,cpu_user,cpu_system,cpu_idle,cpu_nice,memory_used_mb,memory_free_mb,memory_cached_mb,load1,load5,load15,swap_used_mb,swap_free_mb" > "$OUTPUT_FILE"

echo "Starting monitoring - writing to $OUTPUT_FILE"
echo "Press Ctrl+C to stop"

# Trap SIGTERM and SIGINT for graceful shutdown
trap 'echo "Monitoring stopped"; exit 0' SIGTERM SIGINT

while true; do
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

    # Get CPU usage using iostat (user, system, idle)
    # macOS iostat -c reports CPU percentages already normalized to 0-100%
    # CPU fields are at positions $10 (user), $11 (system), $12 (idle)
    CPU_DATA=$(iostat -c 2 -w 1 | tail -n 1)
    CPU_USER=$(echo "$CPU_DATA" | awk '{printf "%.2f", $10}')
    CPU_SYSTEM=$(echo "$CPU_DATA" | awk '{printf "%.2f", $11}')
    CPU_IDLE=$(echo "$CPU_DATA" | awk '{printf "%.2f", $12}')
    CPU_NICE=0  # Not easily available on macOS

    # Get memory usage using vm_stat
    VM_STAT=$(vm_stat)
    PAGE_SIZE=$(pagesize)

    # Extract memory values (in pages) and convert to MB
    PAGES_FREE=$(echo "$VM_STAT" | grep "Pages free" | awk '{print $3}' | tr -d '.')
    PAGES_ACTIVE=$(echo "$VM_STAT" | grep "Pages active" | awk '{print $3}' | tr -d '.')
    PAGES_INACTIVE=$(echo "$VM_STAT" | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
    PAGES_WIRED=$(echo "$VM_STAT" | grep "Pages wired down" | awk '{print $4}' | tr -d '.')
    PAGES_CACHED=$(echo "$VM_STAT" | grep "File-backed pages" | awk '{print $3}' | tr -d '.')

    MEMORY_FREE_MB=$((PAGES_FREE * PAGE_SIZE / 1024 / 1024))
    MEMORY_USED_MB=$(((PAGES_ACTIVE + PAGES_WIRED) * PAGE_SIZE / 1024 / 1024))
    MEMORY_CACHED_MB=$((PAGES_INACTIVE * PAGE_SIZE / 1024 / 1024))

    # Get load average
    LOAD_AVG=$(sysctl -n vm.loadavg | awk '{print $2","$3","$4}')

    # Get swap usage
    SWAP_INFO=$(sysctl vm.swapusage | awk '{print $4,$7}')
    SWAP_USED=$(echo "$SWAP_INFO" | awk '{print $1}' | tr -d 'M')
    SWAP_FREE=$(echo "$SWAP_INFO" | awk '{print $2}' | tr -d 'M')

    # Handle empty values
    SWAP_USED=${SWAP_USED:-0}
    SWAP_FREE=${SWAP_FREE:-0}

    # Write to CSV
    echo "$TIMESTAMP,$CPU_USER,$CPU_SYSTEM,$CPU_IDLE,$CPU_NICE,$MEMORY_USED_MB,$MEMORY_FREE_MB,$MEMORY_CACHED_MB,$LOAD_AVG,$SWAP_USED,$SWAP_FREE" >> "$OUTPUT_FILE"

    sleep $INTERVAL
done
