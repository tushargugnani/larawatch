#!/usr/bin/env bash
# LaraWatch Check: Cron Jobs
# Snapshots user crontabs + /etc/cron.d/ + /etc/crontab
# New entry = CRITICAL, Modified = WARNING

check_cron_run() {
    local bdir
    bdir=$(baseline_dir_for "system" "cron")

    local current_file="${bdir}/cron.current"
    _cron_snapshot > "$current_file"

    if ! baseline_exists "$bdir" "cron"; then
        cp "$current_file" "${bdir}/cron"
        return 0
    fi

    local changes
    changes=$(baseline_compare_lines "${bdir}/cron" "$current_file")

    while IFS='|' read -r status entry; do
        [[ -z "$status" ]] && continue
        # Don't flag our own cron entry
        [[ "$entry" == *"larawatch"* ]] && continue
        case "$status" in
            ADDED)
                finding_add "CRITICAL" "cron" "SYSTEM" "New cron entry: ${entry}"
                ;;
            REMOVED)
                finding_add "INFO" "cron" "SYSTEM" "Cron entry removed: ${entry}"
                ;;
        esac
    done <<< "$changes"
}

check_cron_update() {
    local bdir
    bdir=$(baseline_dir_for "system" "cron")
    _cron_snapshot > "${bdir}/cron"
    out_ok "Updated cron baseline"
}

_cron_snapshot() {
    # User crontabs - check multiple possible spool locations
    local spool_dir=""
    for candidate in /var/spool/cron/crontabs /var/spool/cron /var/cron/tabs; do
        if [[ -d "$candidate" ]]; then
            spool_dir="$candidate"
            break
        fi
    done
    if [[ -n "$spool_dir" ]]; then
        for f in "$spool_dir"/*; do
            [[ ! -f "$f" ]] && continue
            local user
            user=$(basename "$f")
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                [[ "$line" =~ ^# ]] && continue
                echo "user:${user}|${line}"
            done < "$f"
        done
    fi

    # Also try crontab -l for current user
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null)
    if [[ -n "$current_crontab" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            echo "user:$(whoami)|${line}"
        done <<< "$current_crontab"
    fi

    # System crontab
    if [[ -f /etc/crontab ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            [[ "$line" =~ ^[A-Z_]+= ]] && continue
            echo "system:/etc/crontab|${line}"
        done < /etc/crontab
    fi

    # /etc/cron.d/
    if [[ -d /etc/cron.d ]]; then
        for f in /etc/cron.d/*; do
            [[ ! -f "$f" ]] && continue
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                [[ "$line" =~ ^# ]] && continue
                [[ "$line" =~ ^[A-Z_]+= ]] && continue
                echo "system:${f}|${line}"
            done < "$f"
        done
    fi
}
