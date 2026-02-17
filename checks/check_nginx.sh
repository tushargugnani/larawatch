#!/usr/bin/env bash
# LaraWatch Check: Nginx Configuration
# Hashes all files in sites-enabled/, sites-available/, nginx.conf
# Modified = WARNING, New file = WARNING

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
        return 0
    fi

    local changes
    changes=$(baseline_compare "${bdir}/nginx" "$current_file")

    while IFS='|' read -r status path; do
        [[ -z "$status" ]] && continue
        case "$status" in
            ADDED)
                finding_add "WARNING" "nginx" "SYSTEM" "New nginx config file: ${path}"
                ;;
            MODIFIED)
                finding_add "WARNING" "nginx" "SYSTEM" "Modified nginx config: ${path}"
                ;;
            REMOVED)
                finding_add "INFO" "nginx" "SYSTEM" "Nginx config removed: ${path}"
                ;;
        esac
    done <<< "$changes"
}

check_nginx_update() {
    local bdir
    bdir=$(baseline_dir_for "system" "nginx")
    _nginx_snapshot > "${bdir}/nginx"
    out_ok "Updated nginx config baseline"
}

_nginx_snapshot() {
    local nginx_dirs=(
        "/etc/nginx/nginx.conf"
        "/etc/nginx/sites-enabled"
        "/etc/nginx/sites-available"
        "/etc/nginx/conf.d"
    )

    for item in "${nginx_dirs[@]}"; do
        if [[ -f "$item" ]]; then
            local hash
            hash=$(sha256sum "$item" 2>/dev/null | awk '{print $1}')
            echo "${hash}  ${item}"
        elif [[ -d "$item" ]]; then
            find "$item" -type f 2>/dev/null | sort | while IFS= read -r f; do
                local hash
                hash=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
                echo "${hash}  ${f}"
            done
        fi
    done
}
