#!/usr/bin/env bash
# LaraWatch Check: Listening Ports
# Compares ss -tlnp output against baseline
# New port = CRITICAL, Closed port = INFO

check_ports_run() {
    local bdir
    bdir=$(baseline_dir_for "system" "ports")

    local current_file="${bdir}/ports.current"
    _ports_snapshot > "$current_file"

    if ! baseline_exists "$bdir" "ports"; then
        cp "$current_file" "${bdir}/ports"
        return 0
    fi

    local changes
    changes=$(baseline_compare_lines "${bdir}/ports" "$current_file")

    while IFS='|' read -r status entry; do
        [[ -z "$status" ]] && continue
        case "$status" in
            ADDED)
                finding_add "CRITICAL" "ports" "SYSTEM" "New listening port: ${entry}"
                ;;
            REMOVED)
                finding_add "INFO" "ports" "SYSTEM" "Port no longer listening: ${entry}"
                ;;
        esac
    done <<< "$changes"
}

check_ports_update() {
    local bdir
    bdir=$(baseline_dir_for "system" "ports")
    _ports_snapshot > "${bdir}/ports"
    out_ok "Updated ports baseline"
}

_ports_snapshot() {
    # Get listening TCP ports with process info
    ss -tlnp 2>/dev/null | tail -n +2 | while IFS= read -r line; do
        local addr port process
        addr=$(echo "$line" | awk '{print $4}')
        process=$(echo "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
        [[ -z "$process" ]] && process="unknown"
        echo "${addr}|${process}"
    done | sort -u
}
