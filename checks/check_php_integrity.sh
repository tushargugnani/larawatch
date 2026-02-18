#!/usr/bin/env bash
# LaraWatch Check: PHP File Integrity
# Compares SHA256 hashes of all PHP files against baseline
#
# New file severity is tiered by location AND content:
#   public/, storage/  → CRITICAL (always — web-accessible / should never have new PHP)
#   safe paths (migrations, seeders, factories) → INFO if clean, CRITICAL if suspicious
#   all other paths (app/, routes/, config/, etc.) → WARNING if clean, CRITICAL if suspicious
# Modified = WARNING, Deleted = INFO

# Patterns that should never appear in a legitimate migration/seeder/factory
_PHP_INTEGRITY_DANGEROUS_PATTERNS=(
    'eval[[:space:]]*\('
    'assert[[:space:]]*\([[:space:]]*\$'
    'system[[:space:]]*\([[:space:]]*\$'
    'exec[[:space:]]*\([[:space:]]*\$'
    'passthru[[:space:]]*\('
    'shell_exec[[:space:]]*\('
    'proc_open[[:space:]]*\('
    'popen[[:space:]]*\('
    'base64_decode[[:space:]]*\('
    'gzinflate[[:space:]]*\('
    '\$_(POST|GET|REQUEST|COOKIE)\['
    'file_put_contents[[:space:]]*\(.*\$_'
    'create_function[[:space:]]*\('
    'curl_exec[[:space:]]*\('
    'fsockopen[[:space:]]*\('
)

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
                local severity
                severity=$(_php_integrity_classify_new_file "$path" "${site_dir}/${path}")
                case "$severity" in
                    CRITICAL)
                        finding_add "CRITICAL" "php_integrity" "$site_name" "New PHP file: ${path}" ;;
                    CRITICAL_CONTENT)
                        finding_add "CRITICAL" "php_integrity" "$site_name" "New PHP file with suspicious content: ${path}" ;;
                    WARNING)
                        finding_add "WARNING" "php_integrity" "$site_name" "New PHP file: ${path}" ;;
                    INFO)
                        finding_add "INFO" "php_integrity" "$site_name" "New PHP file (expected path): ${path}" ;;
                esac
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

# Classify a new PHP file by location + content.
# Returns: CRITICAL | CRITICAL_CONTENT | WARNING | INFO
_php_integrity_classify_new_file() {
    local path="$1" full_path="$2"

    # Tier 1: High-risk paths — always CRITICAL regardless of content.
    # public/ is web-accessible; storage/ should never have new PHP files.
    if _php_integrity_is_high_risk_path "$path"; then
        echo "CRITICAL"
        return
    fi

    # Tier 2: Safe paths (migrations, seeders, factories) — INFO unless
    # content contains dangerous patterns.
    if _php_integrity_is_safe_path "$path"; then
        if _php_integrity_has_dangerous_content "$full_path"; then
            echo "CRITICAL_CONTENT"
        else
            echo "INFO"
        fi
        return
    fi

    # Tier 3: Everything else (app/, routes/, config/, bootstrap/, etc.)
    # — WARNING for clean files, CRITICAL if suspicious content.
    if _php_integrity_has_dangerous_content "$full_path"; then
        echo "CRITICAL_CONTENT"
    else
        echo "WARNING"
    fi
}

# Paths where new PHP files are always suspicious (web-accessible or non-code dirs)
_php_integrity_is_high_risk_path() {
    local path="$1"
    case "$path" in
        public/*|storage/*) return 0 ;;
    esac
    return 1
}

# Paths where new PHP files are expected during deployments
_php_integrity_is_safe_path() {
    local path="$1"
    local safe_paths="${PHP_INTEGRITY_SAFE_PATHS:-database/migrations database/seeders database/factories}"
    for sp in $safe_paths; do
        case "$path" in
            "${sp}"/*) return 0 ;;
        esac
    done
    return 1
}

# Check if a file contains dangerous patterns
_php_integrity_has_dangerous_content() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local combined
    combined=$(printf '%s\n' "${_PHP_INTEGRITY_DANGEROUS_PATTERNS[@]}" | paste -sd'|')
    grep -qEi "$combined" "$file" 2>/dev/null
}
