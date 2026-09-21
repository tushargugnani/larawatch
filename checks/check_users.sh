#!/usr/bin/env bash
# LaraWatch Check: User Accounts
# Monitors /etc/passwd, sudo group, /etc/sudoers
# New login-shell user = CRITICAL, New sudo member = CRITICAL
# Service accounts with non-login shells are ignored (see IGNORE_USER_SHELLS)

# Default non-login shells. Matching is exact path or basename, so
# /usr/sbin/nologin matches /sbin/nologin and vice versa.
_USERS_DEFAULT_IGNORE_SHELLS="/sbin/nologin /usr/sbin/nologin /bin/false /bin/true /usr/bin/nologin"

# Return 0 if this user ADDED/REMOVED entry should not generate an alert.
# detail format: username:uid:shell
_users_should_ignore() {
    local detail="$1"
    local username shell
    username="${detail%%:*}"
    shell="${detail#*:*:}"

    local ignore_users="${IGNORE_USERS:-}"
    local u
    for u in $ignore_users; do
        [[ "$username" == "$u" ]] && return 0
    done

    local ignore_shells="${IGNORE_USER_SHELLS:-$_USERS_DEFAULT_IGNORE_SHELLS}"
    local shell_base="${shell##*/}"
    local s s_base
    for s in $ignore_shells; do
        s_base="${s##*/}"
        [[ "$shell" == "$s" || ( -n "$shell_base" && "$shell_base" == "$s_base" ) ]] && return 0
    done
    return 1
}

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
                        _users_should_ignore "$detail" && continue
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
                        _users_should_ignore "$detail" && continue
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
    # Include every passwd entry so a later shell change (nologin → bash)
    # still appears as a new login-shell user. Alerts are filtered in check_users_run.
    while IFS=: read -r username _ uid _ _ _ shell; do
        echo "user:${username}:${uid}:${shell}"
    done < "${USERS_PASSWD_FILE:-/etc/passwd}"

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
