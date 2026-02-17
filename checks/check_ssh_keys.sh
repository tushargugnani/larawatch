#!/usr/bin/env bash
# LaraWatch Check: SSH Keys
# Fingerprints each key in authorized_keys files
# New key = CRITICAL, Removed key = WARNING

# Collect SSH key fingerprints from all authorized_keys files
_ssh_keys_snapshot() {
    local output_file="$1"
    : > "$output_file"

    # Search common home directory locations + root
    local search_dirs=(/home /root)
    # Add other common locations if they exist
    for d in /var/home /usr/home /export/home; do
        [[ -d "$d" ]] && search_dirs+=("$d")
    done

    for search_dir in "${search_dirs[@]}"; do
        [[ ! -d "$search_dir" ]] && continue
        while IFS= read -r auth_file; do
            [[ ! -f "$auth_file" ]] && continue
            local user_dir
            user_dir=$(echo "$auth_file" | sed 's|/\.ssh/authorized_keys$||')
            local username
            username=$(basename "$user_dir")

            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                [[ "$line" =~ ^# ]] && continue

                local fingerprint
                fingerprint=$(echo "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
                if [[ -n "$fingerprint" ]]; then
                    local comment
                    comment=$(echo "$line" | awk '{print $NF}')
                    echo "${username}|${fingerprint}|${comment}" >> "$output_file"
                fi
            done < "$auth_file"
        done < <(find "$search_dir" -maxdepth 3 -name "authorized_keys" -type f 2>/dev/null)
    done
}

check_ssh_keys_run() {
    local bdir
    bdir=$(baseline_dir_for "system" "ssh_keys")

    local current_file="${bdir}/keys.current"
    _ssh_keys_snapshot "$current_file"

    if ! baseline_exists "$bdir" "keys"; then
        cp "$current_file" "${bdir}/keys"
        return 0
    fi

    # Compare
    local changes
    changes=$(baseline_compare_lines "${bdir}/keys" "$current_file")

    [[ -z "$changes" ]] && return 0

    while IFS='|' read -r status entry; do
        [[ -z "$status" ]] && continue
        local user fp comment
        user=$(echo "$entry" | cut -d'|' -f1)
        fp=$(echo "$entry" | cut -d'|' -f2)
        comment=$(echo "$entry" | cut -d'|' -f3)
        case "$status" in
            ADDED)
                finding_add "CRITICAL" "ssh_keys" "SYSTEM" "New SSH key for ${user}: ${fp} (${comment})"
                ;;
            REMOVED)
                finding_add "WARNING" "ssh_keys" "SYSTEM" "SSH key removed for ${user}: ${fp} (${comment})"
                ;;
        esac
    done <<< "$changes"
}

check_ssh_keys_update() {
    local bdir
    bdir=$(baseline_dir_for "system" "ssh_keys")
    _ssh_keys_snapshot "${bdir}/keys"
    out_ok "Updated SSH keys baseline"
}
