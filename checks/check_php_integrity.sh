#!/usr/bin/env bash
# LaraWatch Check: PHP File Integrity
# Compares SHA256 hashes of all PHP files against baseline
# New file = CRITICAL, Modified = WARNING, Deleted = INFO

check_php_integrity_run() {
    local site_dir="$1" site_name="$2"
    local bdir
    bdir=$(baseline_dir_for "sites" "$site_name")

    # Generate current state
    local current_file="${bdir}/php_hashes.current"
    baseline_hash_php_files "$site_dir" > "$current_file"

    # Also check vendor state
    local current_vendor
    current_vendor=$(baseline_hash_vendor "$site_dir")
    local stored_vendor=""
    if baseline_exists "$bdir" "vendor_hash"; then
        stored_vendor=$(baseline_load "$bdir" "vendor_hash")
    fi

    if [[ -n "$current_vendor" ]] && [[ -n "$stored_vendor" ]] && [[ "$current_vendor" != "$stored_vendor" ]]; then
        finding_add "WARNING" "php_integrity" "$site_name" "vendor/composer/installed.json changed (packages may have been modified)"
    fi

    if ! baseline_exists "$bdir" "php_hashes"; then
        out_warn "No PHP baseline for ${site_name}, creating initial baseline"
        cp "$current_file" "${bdir}/php_hashes"
        echo "$current_vendor" | baseline_save "$bdir" "vendor_hash"
        return 0
    fi

    # Compare
    local changes
    changes=$(baseline_compare "${bdir}/php_hashes" "$current_file")

    if [[ -z "$changes" ]]; then
        return 0
    fi

    while IFS='|' read -r status path; do
        case "$status" in
            ADDED)
                finding_add "CRITICAL" "php_integrity" "$site_name" "New PHP file: ${path}"
                ;;
            MODIFIED)
                finding_add "WARNING" "php_integrity" "$site_name" "Modified PHP file: ${path}"
                ;;
            REMOVED)
                finding_add "INFO" "php_integrity" "$site_name" "Deleted PHP file: ${path}"
                ;;
        esac
    done <<< "$changes"
}

check_php_integrity_update() {
    local site_dir="$1" site_name="$2"
    local bdir
    bdir=$(baseline_dir_for "sites" "$site_name")

    baseline_hash_php_files "$site_dir" > "${bdir}/php_hashes"
    baseline_hash_vendor "$site_dir" | baseline_save "$bdir" "vendor_hash"
    out_ok "Updated PHP integrity baseline for ${site_name}"
}
