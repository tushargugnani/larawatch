#!/usr/bin/env bash
# LaraWatch Check: .env Integrity
# SHA256 hash of .env file, permission monitoring
# Changed = CRITICAL, Missing = CRITICAL, Permissions changed = WARNING

check_env_integrity_run() {
    local site_dir="$1" site_name="$2"
    local bdir
    bdir=$(baseline_dir_for "sites" "$site_name")
    local env_file="${site_dir}/.env"

    if [[ ! -f "$env_file" ]]; then
        if baseline_exists "$bdir" "env_hash"; then
            finding_add "CRITICAL" "env_integrity" "$site_name" ".env file is missing!"
        fi
        return 0
    fi

    local current_hash current_perms
    current_hash=$(sha256sum "$env_file" 2>/dev/null | awk '{print $1}')
    current_perms=$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file" 2>/dev/null)

    if ! baseline_exists "$bdir" "env_hash"; then
        echo "$current_hash" | baseline_save "$bdir" "env_hash"
        echo "$current_perms" | baseline_save "$bdir" "env_perms"
        return 0
    fi

    local stored_hash stored_perms
    stored_hash=$(baseline_load "$bdir" "env_hash")
    stored_perms=$(baseline_load "$bdir" "env_perms")

    if [[ "$current_hash" != "$stored_hash" ]]; then
        finding_add "CRITICAL" "env_integrity" "$site_name" ".env file has been modified (hash changed)"
    fi

    if [[ -n "$stored_perms" ]] && [[ "$current_perms" != "$stored_perms" ]]; then
        finding_add "WARNING" "env_integrity" "$site_name" ".env permissions changed: ${stored_perms} -> ${current_perms}"
    fi
}

check_env_integrity_update() {
    local site_dir="$1" site_name="$2"
    local bdir
    bdir=$(baseline_dir_for "sites" "$site_name")
    local env_file="${site_dir}/.env"

    if [[ ! -f "$env_file" ]]; then
        out_warn "No .env file found for ${site_name}"
        return 0
    fi

    sha256sum "$env_file" 2>/dev/null | awk '{print $1}' | baseline_save "$bdir" "env_hash"
    (stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file" 2>/dev/null) | baseline_save "$bdir" "env_perms"
    out_ok "Updated .env integrity baseline for ${site_name}"
}
