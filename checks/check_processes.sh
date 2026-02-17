#!/usr/bin/env bash
# LaraWatch Check: Suspicious Processes
# Pattern match against running processes (no baseline needed)
# Miners, reverse shells, suspicious PHP, processes from /tmp/ or /dev/shm/
# Any match = CRITICAL

SUSPICIOUS_PROCESS_PATTERNS=(
    'xmrig'
    'minerd'
    'kdevtmpfsi'
    'kinsing'
    'cryptonight'
    'stratum\+tcp'
    '/dev/tcp/'
    'nc -e'
    'ncat -e'
    'nc\.traditional -e'
    'bash -i >& /dev/tcp/'
    'php -r.*eval'
    'php -r.*base64_decode'
    'php -r.*system\('
    'php -r.*exec\('
    '/tmp/[^[:space:]]+[[:space:]]'
    '/dev/shm/[^[:space:]]+[[:space:]]'
    'perl -e.*socket'
    'python.*socket.*connect'
    'ruby -rsocket'
)

check_processes_run() {
    local ps_output
    ps_output=$(ps auxww 2>/dev/null)

    if [[ -z "$ps_output" ]]; then
        return 0
    fi

    local combined_pattern
    combined_pattern=$(printf '%s\n' "${SUSPICIOUS_PROCESS_PATTERNS[@]}" | paste -sd'|')

    local matches
    matches=$(echo "$ps_output" | grep -iEv "grep|larawatch" | grep -iE "$combined_pattern" 2>/dev/null || true)

    if [[ -n "$matches" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local user pid cmd
            user=$(echo "$line" | awk '{print $1}')
            pid=$(echo "$line" | awk '{print $2}')
            cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
            finding_add "CRITICAL" "processes" "SYSTEM" "Suspicious process (PID ${pid}, user ${user}): ${cmd}"
        done <<< "$matches"
    fi
}

check_processes_update() {
    out_ok "Process check has no baseline (real-time detection)"
}
