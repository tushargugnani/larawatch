#!/usr/bin/env bash
# LaraWatch Check: Log Anomalies
# Sliding window over nginx/cPanel access logs since last scan
# .env probes > threshold = WARNING, High 5xx rate = WARNING
# Livewire upload abuse / PHP-in-upload patterns = CRITICAL

check_log_anomalies_run() {
    local bdir
    bdir=$(baseline_dir_for "system" "log_anomalies")

    local access_logs=()
    local configured="${NGINX_ACCESS_LOG:-}"

    if [[ -n "$configured" ]]; then
        for p in $configured; do
            [[ -f "$p" ]] && access_logs+=("$p")
        done
    else
        while IFS= read -r p; do
            [[ -n "$p" ]] && access_logs+=("$p")
        done < <(_find_all_access_logs)
    fi

    local env_threshold="${ENV_PROBE_THRESHOLD:-5}"
    local error_threshold="${ERROR_RATE_THRESHOLD:-10}"
    local livewire_php_threshold="${LIVEWIRE_PHP_UPLOAD_THRESHOLD:-1}"
    local livewire_burst_threshold="${LIVEWIRE_UPLOAD_BURST_THRESHOLD:-30}"

    local access_log
    for access_log in "${access_logs[@]}"; do
        _log_anomalies_scan_file "$access_log" "$bdir" \
            "$env_threshold" "$error_threshold" \
            "$livewire_php_threshold" "$livewire_burst_threshold"
    done

    baseline_set_last_run "log_anomalies"
}

_log_anomalies_scan_file() {
    local access_log="$1" bdir="$2"
    local env_threshold="$3" error_threshold="$4"
    local livewire_php_threshold="$5" livewire_burst_threshold="$6"

    [[ -f "$access_log" ]] || return 0

    local safe_name
    safe_name=$(echo "$access_log" | tr '/' '_' | tr ' ' '_')
    local offset_file="${bdir}/access_offset_${safe_name}"
    # Migrate legacy single-offset file for the first discovered log
    if [[ ! -f "$offset_file" ]] && [[ -f "${bdir}/access_offset" ]]; then
        offset_file="${bdir}/access_offset"
    fi

    local current_size
    current_size=$(wc -c < "$access_log" 2>/dev/null || echo 0)
    current_size=$(echo "$current_size" | tr -d ' ')
    local last_offset=0
    if [[ -f "$offset_file" ]]; then
        last_offset=$(cat "$offset_file" 2>/dev/null || echo 0)
        last_offset=$(echo "$last_offset" | tr -d ' ')
    fi

    # Log rotated / truncated
    if (( current_size < last_offset )); then
        last_offset=0
    fi

    if (( current_size > last_offset )); then
        local new_lines
        new_lines=$(tail -c +"$((last_offset + 1))" "$access_log" 2>/dev/null)

        if [[ -n "$new_lines" ]]; then
            local log_label
            log_label=$(basename "$access_log")

            # Count .env probes
            local env_probes=0
            env_probes=$(printf '%s\n' "$new_lines" | grep -ciE '(GET|POST|HEAD)[[:space:]]+.*\.env') || env_probes=0
            if (( env_probes > env_threshold )); then
                finding_add "WARNING" "log_anomalies" "SYSTEM" ".env probe attempts detected: ${env_probes} requests in ${log_label}"
            fi

            # Count 5xx errors
            local total_requests=0 five_xx_count=0
            total_requests=$(printf '%s\n' "$new_lines" | wc -l) || total_requests=0
            total_requests=$(echo "$total_requests" | tr -d ' ')
            five_xx_count=$(printf '%s\n' "$new_lines" | grep -cE '" 5[0-9]{2} ') || five_xx_count=0
            five_xx_count=$(echo "$five_xx_count" | tr -d ' ')

            if (( total_requests > 0 )); then
                local error_rate=$(( five_xx_count * 100 / total_requests ))
                if (( error_rate > error_threshold )) && (( five_xx_count > 10 )); then
                    finding_add "WARNING" "log_anomalies" "SYSTEM" "High 5xx error rate: ${error_rate}% (${five_xx_count}/${total_requests}) in ${log_label}"
                fi
            fi

            # Shell script probes
            local shell_probes=0
            shell_probes=$(printf '%s\n' "$new_lines" | grep -ciE '(shell|cmd|eval|exec|system)\.(php|asp|jsp)') || shell_probes=0
            if (( shell_probes > 0 )); then
                finding_add "WARNING" "log_anomalies" "SYSTEM" "Shell script probe attempts: ${shell_probes} requests in ${log_label}"
            fi

            # WordPress scanning
            local wp_probes=0
            wp_probes=$(printf '%s\n' "$new_lines" | grep -ciE 'wp-(login|admin|content|includes)') || wp_probes=0
            if (( wp_probes > 20 )); then
                finding_add "INFO" "log_anomalies" "SYSTEM" "WordPress scanning detected: ${wp_probes} requests in ${log_label}"
            fi

            # --- Livewire / PHP upload abuse ---
            # CRITICAL: request line mentions livewire and .php together
            # (preview-file of a .php upload, or path traversal into livewire-tmp)
            local livewire_php=0
            livewire_php=$(printf '%s\n' "$new_lines" | grep -ciE 'livewire.*\.php|\.php.*livewire|livewire-tmp.*\.php|storage/app/livewire.*\.php') || livewire_php=0
            if (( livewire_php >= livewire_php_threshold )); then
                local sample
                sample=$(printf '%s\n' "$new_lines" | grep -iE 'livewire.*\.php|\.php.*livewire|livewire-tmp.*\.php' | head -3 | tr '\n' ' ' | cut -c1-240)
                finding_add "CRITICAL" "log_anomalies" "SYSTEM" "Livewire/PHP upload or access attempts: ${livewire_php} in ${log_label} — ${sample}"
            fi

            # CRITICAL: attempts to fetch any .php under storage/ (should never be web-served)
            local storage_php=0
            storage_php=$(printf '%s\n' "$new_lines" | grep -ciE '(GET|POST|HEAD)[[:space:]]+[^ ]*storage/[^ ]*\.php') || storage_php=0
            if (( storage_php > 0 )); then
                finding_add "CRITICAL" "log_anomalies" "SYSTEM" "Direct .php access under storage/: ${storage_php} requests in ${log_label}"
            fi

            # WARNING: burst of Livewire upload-file POSTs from a single IP
            local upload_lines
            upload_lines=$(printf '%s\n' "$new_lines" | grep -iE 'POST[[:space:]]+[^ ]*livewire/(upload-file|upload)[[:space:]]' || true)
            if [[ -n "$upload_lines" ]]; then
                local upload_count
                upload_count=$(printf '%s\n' "$upload_lines" | wc -l | tr -d ' ')
                if (( upload_count >= livewire_burst_threshold )); then
                    local top_ip
                    top_ip=$(printf '%s\n' "$upload_lines" | awk '{print $1}' | sort | uniq -c | sort -rn | head -1)
                    finding_add "WARNING" "log_anomalies" "SYSTEM" "Livewire upload burst: ${upload_count} POSTs in ${log_label} (top ${top_ip})"
                fi
            fi
        fi
    fi

    # Always write per-log offset under the safe name going forward
    local out_offset="${bdir}/access_offset_${safe_name}"
    echo "$current_size" > "$out_offset"
}

check_log_anomalies_update() {
    local bdir
    bdir=$(baseline_dir_for "system" "log_anomalies")

    local access_logs=()
    local configured="${NGINX_ACCESS_LOG:-}"
    if [[ -n "$configured" ]]; then
        for p in $configured; do
            [[ -f "$p" ]] && access_logs+=("$p")
        done
    else
        while IFS= read -r p; do
            [[ -n "$p" ]] && access_logs+=("$p")
        done < <(_find_all_access_logs)
    fi

    local access_log
    for access_log in "${access_logs[@]}"; do
        local safe_name
        safe_name=$(echo "$access_log" | tr '/' '_' | tr ' ' '_')
        wc -c < "$access_log" | tr -d ' ' > "${bdir}/access_offset_${safe_name}" 2>/dev/null
    done

    baseline_set_last_run "log_anomalies"
    out_ok "Updated log anomalies baseline (reset offsets for ${#access_logs[@]} log(s))"
}

_find_nginx_log() {
    local type="$1"  # "access" or "error"
    _find_all_access_logs | head -1
}

# Discover access logs across nginx + cPanel layouts
_find_all_access_logs() {
    {
        local candidates=(
            "/var/log/nginx/access.log"
            "/var/log/access.log"
            "/var/log/nginx/default-access.log"
            "${HOME}/access-logs"
            "/usr/local/apache/domlogs"
        )

        local c
        for c in "${candidates[@]}"; do
            if [[ -f "$c" ]]; then
                echo "$c"
            elif [[ -d "$c" ]]; then
                local f
                for f in "$c"/*-ssl_log "$c"/*.ssl_log "$c"/*access* "$c"/*; do
                    [[ -f "$f" ]] || continue
                    [[ -s "$f" ]] || continue
                    echo "$f"
                done
            fi
        done

        if [[ -f /etc/nginx/nginx.conf ]]; then
            local log_path
            log_path=$(grep -oE "access_log[[:space:]]+[^;]+" /etc/nginx/nginx.conf 2>/dev/null | head -1 | awk '{print $2}' || true)
            if [[ -n "$log_path" ]] && [[ -f "$log_path" ]]; then
                echo "$log_path"
            fi
        fi
    } | awk 'NF && !seen[$0]++'
}
