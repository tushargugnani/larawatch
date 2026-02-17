#!/usr/bin/env bash
# LaraWatch Check: CPU Usage
# Alerts when CPU usage exceeds configured thresholds (no baseline needed)
# Uses 5-second average to avoid false positives from momentary spikes
# WARNING at CPU_WARN_THRESHOLD%, CRITICAL at CPU_CRITICAL_THRESHOLD%

check_cpu_run() {
    local warn_threshold="${CPU_WARN_THRESHOLD:-90}"
    local critical_threshold="${CPU_CRITICAL_THRESHOLD:-95}"

    # Use /proc/stat to calculate CPU usage over a short interval
    if [[ ! -f /proc/stat ]]; then
        return 0
    fi

    local cpu1 cpu2
    cpu1=$(grep '^cpu ' /proc/stat)
    sleep 2
    cpu2=$(grep '^cpu ' /proc/stat)

    # Parse idle and total from both samples
    local idle1 total1 idle2 total2
    idle1=$(echo "$cpu1" | awk '{print $5}')
    total1=$(echo "$cpu1" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')
    idle2=$(echo "$cpu2" | awk '{print $5}')
    total2=$(echo "$cpu2" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')

    local idle_delta total_delta usage_pct
    idle_delta=$((idle2 - idle1))
    total_delta=$((total2 - total1))

    if (( total_delta == 0 )); then
        return 0
    fi

    usage_pct=$(( (total_delta - idle_delta) * 100 / total_delta ))

    if (( usage_pct >= critical_threshold )); then
        local top_procs
        top_procs=$(ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | head -4 | tail -3 | awk '{printf "%s(%s%%) ", $2, $1}')
        finding_add "CRITICAL" "cpu" "SYSTEM" "CPU usage at ${usage_pct}% — top: ${top_procs}"
    elif (( usage_pct >= warn_threshold )); then
        local top_procs
        top_procs=$(ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | head -4 | tail -3 | awk '{printf "%s(%s%%) ", $2, $1}')
        finding_add "WARNING" "cpu" "SYSTEM" "CPU usage at ${usage_pct}% — top: ${top_procs}"
    fi
}

check_cpu_update() {
    out_ok "CPU check has no baseline (threshold-based detection)"
}
