#!/usr/bin/env bash
# LaraWatch Check: Webshell Pattern Scanning
# Scans public/, app/, routes/, resources/views/ for malicious patterns
# Only scans files modified since last run (full rescan daily)
# Any match = CRITICAL

# Patterns use extended regex (grep -E) for portability across GNU/BSD
WEBSHELL_PATTERNS=(
    'eval[[:space:]]*\([[:space:]]*base64_decode[[:space:]]*\('
    'eval[[:space:]]*\([[:space:]]*gzinflate[[:space:]]*\('
    'eval[[:space:]]*\([[:space:]]*gzuncompress[[:space:]]*\('
    'eval[[:space:]]*\([[:space:]]*str_rot13[[:space:]]*\('
    'eval[[:space:]]*\([[:space:]]*\$_POST\['
    'eval[[:space:]]*\([[:space:]]*\$_GET\['
    'eval[[:space:]]*\([[:space:]]*\$_REQUEST\['
    'eval[[:space:]]*\([[:space:]]*\$_COOKIE\['
    'system[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'exec[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'passthru[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'shell_exec[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'proc_open[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'popen[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'assert[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)\['
    'preg_replace[[:space:]]*\(.*/e[^"]*"?[[:space:]]*,'
    'create_function[[:space:]]*\('
    'chr[[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\)[[:space:]]*\.[[:space:]]*chr[[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\)'
    'file_put_contents[[:space:]]*\(.*\$_(POST|GET|REQUEST)\['
)

check_webshell_run() {
    local site_dir="$1" site_name="$2"

    local scan_dirs=()
    for d in "public" "app" "routes" "resources/views"; do
        [[ -d "${site_dir}/${d}" ]] && scan_dirs+=("${site_dir}/${d}")
    done

    if [[ ${#scan_dirs[@]} -eq 0 ]]; then
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

    for scan_dir in "${scan_dirs[@]}"; do
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
        done < <(find "$scan_dir" -type f -name "*.php" "${find_time_args[@]}" 2>/dev/null)
    done

    baseline_set_last_run "webshell_${site_name}"
}

check_webshell_update() {
    local site_dir="$1" site_name="$2"
    baseline_set_last_run "webshell_${site_name}"
    out_ok "Reset webshell scan timer for ${site_name}"
}
