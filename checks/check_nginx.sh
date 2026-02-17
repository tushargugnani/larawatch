#!/usr/bin/env bash
# LaraWatch Check: Nginx + PHP-FPM Configuration
# Hashes nginx configs (sites-enabled/, sites-available/, conf.d/, forge-conf/ includes)
# and PHP-FPM pool configs. Scans FPM pools for auto_prepend_file injection.
# Modified = WARNING, New file = WARNING, auto_prepend_file in FPM pool = CRITICAL

check_nginx_run() {
    local bdir
    bdir=$(baseline_dir_for "system" "nginx")

    local current_file="${bdir}/nginx.current"
    _nginx_snapshot > "$current_file"

    if [[ ! -s "$current_file" ]]; then
        return 0
    fi

    if ! baseline_exists "$bdir" "nginx"; then
        cp "$current_file" "${bdir}/nginx"
        _nginx_scan_fpm_injection
        return 0
    fi

    local changes
    changes=$(baseline_compare "${bdir}/nginx" "$current_file")

    while IFS='|' read -r status path; do
        [[ -z "$status" ]] && continue
        case "$status" in
            ADDED)
                finding_add "WARNING" "nginx" "SYSTEM" "New nginx/fpm config file: ${path}"
                ;;
            MODIFIED)
                finding_add "WARNING" "nginx" "SYSTEM" "Modified nginx/fpm config: ${path}"
                ;;
            REMOVED)
                finding_add "INFO" "nginx" "SYSTEM" "Nginx/fpm config removed: ${path}"
                ;;
        esac
    done <<< "$changes"

    _nginx_scan_fpm_injection
}

check_nginx_update() {
    local bdir
    bdir=$(baseline_dir_for "system" "nginx")
    _nginx_snapshot > "${bdir}/nginx"
    out_ok "Updated nginx/fpm config baseline"
}

_nginx_snapshot() {
    local nginx_dirs=(
        "/etc/nginx/nginx.conf"
        "/etc/nginx/sites-enabled"
        "/etc/nginx/sites-available"
        "/etc/nginx/conf.d"
        "/etc/nginx/forge-conf"
    )

    for item in "${nginx_dirs[@]}"; do
        if [[ -f "$item" ]]; then
            local hash
            hash=$(sha256sum "$item" 2>/dev/null | awk '{print $1}')
            echo "${hash}  ${item}"
        elif [[ -d "$item" ]]; then
            find -L "$item" -type f 2>/dev/null | sort | while IFS= read -r f; do
                local hash
                hash=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
                echo "${hash}  ${f}"
            done
        fi
    done

    # PHP-FPM pool configs
    local fpm_dirs=()
    # Debian/Ubuntu style: /etc/php/X.Y/fpm/pool.d/
    while IFS= read -r d; do
        fpm_dirs+=("$d")
    done < <(find /etc/php -maxdepth 3 -type d -name "pool.d" 2>/dev/null | sort)
    # RHEL/CentOS style: /etc/php-fpm.d/
    [[ -d /etc/php-fpm.d ]] && fpm_dirs+=("/etc/php-fpm.d")

    for fpm_dir in "${fpm_dirs[@]}"; do
        find "$fpm_dir" -type f 2>/dev/null | sort | while IFS= read -r f; do
            local hash
            hash=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
            echo "${hash}  ${f}"
        done
    done
}

# Scan all PHP-FPM pool configs for auto_prepend_file injection
_nginx_scan_fpm_injection() {
    local fpm_configs=()

    while IFS= read -r f; do
        fpm_configs+=("$f")
    done < <(find /etc/php -maxdepth 4 -path "*/pool.d/*.conf" -type f 2>/dev/null)
    while IFS= read -r f; do
        fpm_configs+=("$f")
    done < <(find /etc/php-fpm.d -maxdepth 1 -name "*.conf" -type f 2>/dev/null)

    for conf in "${fpm_configs[@]}"; do
        local hit
        hit=$(grep -nEi 'auto_prepend_file[[:space:]]*=' "$conf" 2>/dev/null | grep -v '^[[:space:]]*;' || true)
        if [[ -n "$hit" ]]; then
            while IFS= read -r line; do
                finding_add "CRITICAL" "nginx" "SYSTEM" "PHP-FPM auto_prepend_file set in ${conf}: ${line}"
            done <<< "$hit"
        fi
    done
}
