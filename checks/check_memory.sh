#!/usr/bin/env bash
# LaraWatch Check: Memory Usage
# Alerts when memory usage exceeds configured thresholds (no baseline needed)
# Uses "available" memory (includes buffers/cache) for accurate measurement
# WARNING at MEMORY_WARN_THRESHOLD%, CRITICAL at MEMORY_CRITICAL_THRESHOLD%

check_memory_run() {
    local warn_threshold="${MEMORY_WARN_THRESHOLD:-80}"
    local critical_threshold="${MEMORY_CRITICAL_THRESHOLD:-90}"

    if [[ ! -f /proc/meminfo ]]; then
        return 0
    fi

    local total_kb available_kb
    total_kb=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
    available_kb=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')

    if [[ -z "$total_kb" || -z "$available_kb" || "$total_kb" -eq 0 ]]; then
        return 0
    fi

    local used_kb usage_pct
    used_kb=$((total_kb - available_kb))
    usage_pct=$((used_kb * 100 / total_kb))

    local total_mb used_mb avail_mb
    total_mb=$((total_kb / 1024))
    used_mb=$((used_kb / 1024))
    avail_mb=$((available_kb / 1024))

    if (( usage_pct >= critical_threshold )); then
        local top_procs
        top_procs=$(ps -eo pmem,comm --sort=-pmem 2>/dev/null | head -4 | tail -3 | awk '{printf "%s(%s%%) ", $2, $1}')
        finding_add "CRITICAL" "memory" "SYSTEM" "Memory usage at ${usage_pct}% (${used_mb}MB/${total_mb}MB, ${avail_mb}MB available) — top: ${top_procs}"
    elif (( usage_pct >= warn_threshold )); then
        local top_procs
        top_procs=$(ps -eo pmem,comm --sort=-pmem 2>/dev/null | head -4 | tail -3 | awk '{printf "%s(%s%%) ", $2, $1}')
        finding_add "WARNING" "memory" "SYSTEM" "Memory usage at ${usage_pct}% (${used_mb}MB/${total_mb}MB, ${avail_mb}MB available) — top: ${top_procs}"
    fi
}

check_memory_update() {
    out_ok "Memory check has no baseline (threshold-based detection)"
}
