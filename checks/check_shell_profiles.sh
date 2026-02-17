#!/usr/bin/env bash
# LaraWatch Check: Shell Profile Integrity
# Hashes shell startup files for all users with login shells and system-wide profiles.
# An attacker who plants a backdoor in .bashrc/.profile gets code execution on every
# SSH login without touching the application at all.
#
# Monitored files:
#   /etc/profile, /etc/bash.bashrc, /etc/profile.d/*
#   ~/.bashrc, ~/.profile, ~/.bash_profile, ~/.bash_login, ~/.zshrc  (per login-shell user)
#
# New file in /etc/profile.d/ = WARNING, Modified profile = WARNING
# New profile file for a user   = CRITICAL (unexpected new startup file)

check_shell_profiles_run() {
    local bdir
    bdir=$(baseline_dir_for "system" "shell_profiles")

    local current_file="${bdir}/shell_profiles.current"
    _shell_profiles_snapshot > "$current_file"

    if [[ ! -s "$current_file" ]]; then
        return 0
    fi

    if ! baseline_exists "$bdir" "shell_profiles"; then
        cp "$current_file" "${bdir}/shell_profiles"
        return 0
    fi

    local changes
    changes=$(baseline_compare "${bdir}/shell_profiles" "$current_file")

    while IFS='|' read -r status path; do
        [[ -z "$status" ]] && continue
        case "$status" in
            ADDED)
                # New file in a user home = very suspicious
                if [[ "$path" == /root/* ]] || [[ "$path" == /home/* ]]; then
                    finding_add "CRITICAL" "shell_profiles" "SYSTEM" "New shell profile: ${path}"
                else
                    finding_add "WARNING" "shell_profiles" "SYSTEM" "New shell profile: ${path}"
                fi
                ;;
            MODIFIED)
                finding_add "WARNING" "shell_profiles" "SYSTEM" "Modified shell profile: ${path}"
                ;;
            REMOVED)
                finding_add "INFO" "shell_profiles" "SYSTEM" "Shell profile removed: ${path}"
                ;;
        esac
    done <<< "$changes"
}

check_shell_profiles_update() {
    local bdir
    bdir=$(baseline_dir_for "system" "shell_profiles")
    _shell_profiles_snapshot > "${bdir}/shell_profiles"
    out_ok "Updated shell profiles baseline"
}

_shell_profiles_snapshot() {
    # System-wide startup files
    local system_files=(
        "/etc/profile"
        "/etc/bash.bashrc"
        "/etc/zsh/zshrc"
        "/etc/zsh/zshenv"
        "/etc/zsh/zprofile"
    )

    for f in "${system_files[@]}"; do
        [[ -f "$f" ]] || continue
        local hash
        hash=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
        echo "${hash}  ${f}"
    done

    # System-wide profile drop-in directory
    if [[ -d /etc/profile.d ]]; then
        find /etc/profile.d -maxdepth 1 -type f 2>/dev/null | sort | while IFS= read -r f; do
            local hash
            hash=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
            echo "${hash}  ${f}"
        done
    fi

    # Per-user startup files for users with real login shells
    local no_login_re='(nologin|false|sync|halt|shutdown)$'
    while IFS=: read -r username _ uid _ _ home shell; do
        # Skip system accounts (uid < 1000) except root (uid 0)
        [[ "$uid" -ge 1000 || "$uid" -eq 0 ]] || continue
        [[ -d "$home" ]] || continue
        [[ "$shell" =~ $no_login_re ]] && continue

        for profile in ".bashrc" ".profile" ".bash_profile" ".bash_login" ".zshrc" ".zshenv" ".zprofile"; do
            local f="${home}/${profile}"
            [[ -f "$f" ]] || continue
            local hash
            hash=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
            echo "${hash}  ${f}"
        done
    done < /etc/passwd
}
