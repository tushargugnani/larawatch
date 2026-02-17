#!/usr/bin/env bash
# LaraWatch Check: User Accounts
# Monitors /etc/passwd, sudo group, /etc/sudoers
# New user = CRITICAL, New sudo member = CRITICAL

check_users_run() {
    local bdir
    bdir=$(baseline_dir_for "system" "users")

    local current_file="${bdir}/users.current"
    _users_snapshot > "$current_file"

    if ! baseline_exists "$bdir" "users"; then
        cp "$current_file" "${bdir}/users"
        return 0
    fi

    local changes
    changes=$(baseline_compare_lines "${bdir}/users" "$current_file")

    while IFS='|' read -r status entry; do
        [[ -z "$status" ]] && continue
        local type detail
        type=$(echo "$entry" | cut -d':' -f1)
        detail=$(echo "$entry" | cut -d':' -f2-)

        case "$status" in
            ADDED)
                case "$type" in
                    user)
                        finding_add "CRITICAL" "users" "SYSTEM" "New user account: ${detail}"
                        ;;
                    sudo)
                        finding_add "CRITICAL" "users" "SYSTEM" "New sudo member: ${detail}"
                        ;;
                    sudoers_hash)
                        finding_add "CRITICAL" "users" "SYSTEM" "sudoers file modified"
                        ;;
                esac
                ;;
            REMOVED)
                case "$type" in
                    user)
                        finding_add "WARNING" "users" "SYSTEM" "User account removed: ${detail}"
                        ;;
                    sudo)
                        finding_add "INFO" "users" "SYSTEM" "Sudo member removed: ${detail}"
                        ;;
                esac
                ;;
        esac
    done <<< "$changes"
}

check_users_update() {
    local bdir
    bdir=$(baseline_dir_for "system" "users")
    _users_snapshot > "${bdir}/users"
    out_ok "Updated users baseline"
}

_users_snapshot() {
    # List all user accounts (with shell, excluding nologin/false for noise reduction... actually include all for security)
    while IFS=: read -r username _ uid _ _ _ shell; do
        echo "user:${username}:${uid}:${shell}"
    done < /etc/passwd

    # Sudo group members
    if getent group sudo &>/dev/null; then
        local sudo_members
        sudo_members=$(getent group sudo | cut -d: -f4)
        for member in ${sudo_members//,/ }; do
            echo "sudo:${member}"
        done
    fi

    # Also check wheel group (RHEL/CentOS)
    if getent group wheel &>/dev/null; then
        local wheel_members
        wheel_members=$(getent group wheel | cut -d: -f4)
        for member in ${wheel_members//,/ }; do
            echo "sudo:${member}"
        done
    fi

    # Hash of sudoers files
    if [[ -f /etc/sudoers ]]; then
        local sudoers_hash
        sudoers_hash=$(sha256sum /etc/sudoers 2>/dev/null | awk '{print $1}')
        echo "sudoers_hash:${sudoers_hash}"
    fi
    if [[ -d /etc/sudoers.d ]]; then
        for f in /etc/sudoers.d/*; do
            [[ ! -f "$f" ]] && continue
            local h
            h=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
            echo "sudoers_hash:${f}:${h}"
        done
    fi
}
