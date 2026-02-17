#!/usr/bin/env bash
# LaraWatch Check: Webshell Pattern Scanning
# Scans entire site directory for malicious patterns including:
#   public/, app/, routes/, resources/views/, storage/, bootstrap/, config/, database/
# Excludes vendor/, node_modules/, storage/framework/views/, storage/logs/, bootstrap/cache/
# Only scans files modified since last run (full rescan daily)
# Any match = CRITICAL

# Patterns use extended regex (grep -E) for portability across GNU/BSD
WEBSHELL_PATTERNS=(
    # eval with deobfuscation
    'eval[[:space:]]*\([[:space:]]*base64_decode[[:space:]]*\('
    'eval[[:space:]]*\([[:space:]]*gzinflate[[:space:]]*\('
    'eval[[:space:]]*\([[:space:]]*gzuncompress[[:space:]]*\('
    'eval[[:space:]]*\([[:space:]]*str_rot13[[:space:]]*\('
    # eval/assert with user input
    'eval[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE)\['
    'assert[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    # Command execution with user input (direct)
    'system[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'exec[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'passthru[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'shell_exec[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'proc_open[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'popen[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    # Command execution standalone (outside vendor/) — caught by path filter
    'shell_exec[[:space:]]*\([[:space:]]*\$'
    'passthru[[:space:]]*\([[:space:]]*\$'
    # Dangerous functions with dynamic args
    'preg_replace[[:space:]]*\(.*/e[^"]*"?[[:space:]]*,'
    'create_function[[:space:]]*\('
    # Obfuscation indicators
    'chr[[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\)[[:space:]]*\.[[:space:]]*chr[[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\)'
    '\\x[0-9a-fA-F]{2}\\x[0-9a-fA-F]{2}\\x[0-9a-fA-F]{2}'
    # File upload to arbitrary paths
    'file_put_contents[[:space:]]*\(.*\$_(POST|GET|REQUEST)\['
    'move_uploaded_file[[:space:]]*\(.*\$_(POST|GET|REQUEST)\['
)

check_webshell_run() {
    local site_dir="$1" site_name="$2"

    if [[ ! -d "$site_dir" ]]; then
        return 0
    fi

    # Determine if we do incremental or full scan
    local last_run
    last_run=$(baseline_get_last_run "webshell_${site_name}")
    local now
    now=$(date +%s)
    local daily_seconds=86400

    local find_time_args=()
    if [[ "$last_run" -gt 0 ]] && (( now - last_run < daily_seconds )); then
        # Incremental: only files modified since last run
        local mins_ago=$(( (now - last_run) / 60 + 1 ))
        find_time_args=(-mmin "-${mins_ago}")
    fi

    # Build combined grep pattern
    local combined_pattern
    combined_pattern=$(printf '%s\n' "${WEBSHELL_PATTERNS[@]}" | paste -sd'|')

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local matches
        matches=$(grep -nEi "$combined_pattern" "$file" 2>/dev/null | head -3 || true)
        if [[ -n "$matches" ]]; then
            local rel_path="${file#"${site_dir}/"}"
            while IFS= read -r match_line; do
                finding_add "CRITICAL" "webshell" "$site_name" "Pattern found: ${rel_path} - ${match_line}"
            done <<< "$matches"
        fi
    done < <(find -L "$site_dir" -type f -name "*.php" \
        -not -path "*/vendor/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/storage/framework/views/*" \
        -not -path "*/storage/logs/*" \
        -not -path "*/bootstrap/cache/*" \
        "${find_time_args[@]}" 2>/dev/null)

    baseline_set_last_run "webshell_${site_name}"
}

check_webshell_update() {
    local site_dir="$1" site_name="$2"
    baseline_set_last_run "webshell_${site_name}"
    out_ok "Reset webshell scan timer for ${site_name}"
}
