#!/usr/bin/env bash
# LaraWatch Check: Disk Usage
# Alerts when disk usage exceeds configured thresholds (no baseline needed)
# WARNING at DISK_WARN_THRESHOLD%, CRITICAL at DISK_CRITICAL_THRESHOLD%

check_disk_run() {
    local warn_threshold="${DISK_WARN_THRESHOLD:-80}"
    local critical_threshold="${DISK_CRITICAL_THRESHOLD:-90}"

    while IFS= read -r line; do
        local mount usage_pct
        mount=$(echo "$line" | awk '{print $6}')
        usage_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')

        [[ -z "$usage_pct" ]] && continue

        if (( usage_pct >= critical_threshold )); then
            local size used avail
            size=$(echo "$line" | awk '{print $2}')
            used=$(echo "$line" | awk '{print $3}')
            avail=$(echo "$line" | awk '{print $4}')
            finding_add "CRITICAL" "disk" "SYSTEM" "Disk ${usage_pct}% full on ${mount} (${avail} available of ${size})"
        elif (( usage_pct >= warn_threshold )); then
            local size used avail
            size=$(echo "$line" | awk '{print $2}')
            used=$(echo "$line" | awk '{print $3}')
            avail=$(echo "$line" | awk '{print $4}')
            finding_add "WARNING" "disk" "SYSTEM" "Disk ${usage_pct}% full on ${mount} (${avail} available of ${size})"
        fi
    done < <(df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2)
}

check_disk_update() {
    out_ok "Disk check has no baseline (threshold-based detection)"
}
