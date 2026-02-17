#!/usr/bin/env bash
# LaraWatch Check: Log Anomalies
# Sliding window over nginx access/error logs since last scan
# .env probes > threshold = WARNING, High 5xx rate = WARNING

check_log_anomalies_run() {
    local bdir
    bdir=$(baseline_dir_for "system" "log_anomalies")

    # Auto-detect or use configured log paths
    local access_log="${NGINX_ACCESS_LOG:-}"

    if [[ -z "$access_log" ]]; then
        access_log=$(_find_nginx_log "access")
    fi

    local env_threshold="${ENV_PROBE_THRESHOLD:-5}"
    local error_threshold="${ERROR_RATE_THRESHOLD:-10}"

    # Check access log for anomalies
    if [[ -n "$access_log" ]] && [[ -f "$access_log" ]]; then
        local offset_file="${bdir}/access_offset"
        local current_size
        current_size=$(wc -c < "$access_log" 2>/dev/null || echo 0)
        local last_offset=0
        if [[ -f "$offset_file" ]]; then
            last_offset=$(cat "$offset_file" 2>/dev/null || echo 0)
        fi

        if (( current_size > last_offset )); then
            local new_lines
            new_lines=$(tail -c +"$((last_offset + 1))" "$access_log" 2>/dev/null)

            if [[ -n "$new_lines" ]]; then
                # Count .env probes (using extended regex, portable)
                local env_probes=0
                env_probes=$(echo "$new_lines" | grep -ciE '(GET|POST|HEAD)[[:space:]]+.*\.env') || env_probes=0
                if (( env_probes > env_threshold )); then
                    finding_add "WARNING" "log_anomalies" "SYSTEM" ".env probe attempts detected: ${env_probes} requests since last scan"
                fi

                # Count 5xx errors
                local total_requests=0 five_xx_count=0
                total_requests=$(echo "$new_lines" | wc -l) || total_requests=0
                five_xx_count=$(echo "$new_lines" | grep -cE '" 5[0-9]{2} ') || five_xx_count=0

                if (( total_requests > 0 )); then
                    local error_rate=$(( five_xx_count * 100 / total_requests ))
                    if (( error_rate > error_threshold )) && (( five_xx_count > 10 )); then
                        finding_add "WARNING" "log_anomalies" "SYSTEM" "High 5xx error rate: ${error_rate}% (${five_xx_count}/${total_requests} requests)"
                    fi
                fi

                # Shell script probes
                local shell_probes=0
                shell_probes=$(echo "$new_lines" | grep -ciE '(shell|cmd|eval|exec|system)\.(php|asp|jsp)') || shell_probes=0
                if (( shell_probes > 0 )); then
                    finding_add "WARNING" "log_anomalies" "SYSTEM" "Shell script probe attempts: ${shell_probes} requests"
                fi

                # WordPress scanning (noise but worth noting)
                local wp_probes=0
                wp_probes=$(echo "$new_lines" | grep -ciE 'wp-(login|admin|content|includes)') || wp_probes=0
                if (( wp_probes > 20 )); then
                    finding_add "INFO" "log_anomalies" "SYSTEM" "WordPress scanning detected: ${wp_probes} requests (likely automated bot)"
                fi
            fi
        fi

        echo "$current_size" > "$offset_file"
    fi

    baseline_set_last_run "log_anomalies"
}

check_log_anomalies_update() {
    local bdir
    bdir=$(baseline_dir_for "system" "log_anomalies")

    # Reset log offsets
    local access_log="${NGINX_ACCESS_LOG:-}"
    if [[ -z "$access_log" ]]; then
        access_log=$(_find_nginx_log "access")
    fi
    if [[ -n "$access_log" ]] && [[ -f "$access_log" ]]; then
        wc -c < "$access_log" > "${bdir}/access_offset" 2>/dev/null
    fi

    baseline_set_last_run "log_anomalies"
    out_ok "Updated log anomalies baseline (reset offsets)"
}

_find_nginx_log() {
    local type="$1"  # "access" or "error"
    local candidates=(
        "/var/log/nginx/${type}.log"
        "/var/log/${type}.log"
        "/var/log/nginx/default-${type}.log"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    # Try to find from nginx config
    if [[ -f /etc/nginx/nginx.conf ]]; then
        local log_path
        log_path=$(grep -oE "${type}_log[[:space:]]+[^;]+" /etc/nginx/nginx.conf 2>/dev/null | head -1 | awk '{print $2}' || true)
        if [[ -n "$log_path" ]] && [[ -f "$log_path" ]]; then
            echo "$log_path"
            return 0
        fi
    fi
}
