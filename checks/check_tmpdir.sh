#!/usr/bin/env bash
# LaraWatch Check: Temp Directory Suspicious Files
# Scans /tmp, /var/tmp, and /dev/shm for PHP files and suspicious scripts.
# These directories are world-writable staging areas commonly used by attackers
# to drop webshells, reverse shells, or privilege escalation tools.
#
# Any .php file in temp dirs = CRITICAL
# Suspicious script patterns (curl|wget piped to bash, base64 exec) = CRITICAL

_TMPDIR_SUSPICIOUS_PATTERNS=(
    # curl/wget piped to bash/sh — dropper one-liners
    'curl[[:space:]].*\|[[:space:]]*(bash|sh)'
    'wget[[:space:]].*\|[[:space:]]*(bash|sh)'
    'curl[[:space:]].*-o[[:space:]].*\.(sh|py|pl|php)'
    # base64 decode piped to shell
    'base64[[:space:]]+(-d|--decode)[[:space:]]*\|[[:space:]]*(bash|sh|perl|python)'
    # Python/Perl reverse shells
    'import[[:space:]]+socket.*subprocess'
    'use[[:space:]]+Socket.*exec.*STDIN'
    # Common reverse shell patterns
    '/dev/(tcp|udp)/[0-9]'
    'bash[[:space:]]+-i[[:space:]]+>&'
)

check_tmpdir_run() {
    local bdir
    bdir=$(baseline_dir_for "system" "tmpdir")

    local scan_dirs=()
    for d in "/tmp" "/var/tmp" "/dev/shm"; do
        [[ -d "$d" ]] && scan_dirs+=("$d")
    done

    [[ ${#scan_dirs[@]} -eq 0 ]] && return 0

    # Build exclusions for larawatch's own state/install dirs so we don't
    # flag our own working files (e.g. when installed under /tmp/larawatch/).
    local exclude_args=()
    for own_dir in "${LARAWATCH_STATE:-}" "${LARAWATCH_DIR:-}"; do
        [[ -n "$own_dir" ]] && exclude_args+=(-not -path "${own_dir}/*")
    done

    # --- PHP files in temp dirs (always CRITICAL, no baseline needed) ---
    for scan_dir in "${scan_dirs[@]}"; do
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            finding_add "CRITICAL" "tmpdir" "SYSTEM" "PHP file in temp directory: ${file}"
        done < <(find "$scan_dir" -type f -name "*.php" "${exclude_args[@]}" 2>/dev/null)
    done

    # --- Suspicious script patterns in all temp files ---
    local combined_pattern
    combined_pattern=$(printf '%s\n' "${_TMPDIR_SUSPICIOUS_PATTERNS[@]}" | paste -sd'|')

    for scan_dir in "${scan_dirs[@]}"; do
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            # Skip binary files
            file --mime "$file" 2>/dev/null | grep -q "charset=binary" && continue
            local matches
            matches=$(grep -nEi "$combined_pattern" "$file" 2>/dev/null | head -3 || true)
            if [[ -n "$matches" ]]; then
                while IFS= read -r match_line; do
                    finding_add "CRITICAL" "tmpdir" "SYSTEM" "Suspicious pattern in ${file}: ${match_line}"
                done <<< "$matches"
            fi
        done < <(find "$scan_dir" -type f \
            -not -name "*.php" \
            -size -512k \
            "${exclude_args[@]}" \
            2>/dev/null)
    done

    # --- Track new files appearing in temp dirs (baseline comparison) ---
    local current_file="${bdir}/tmpdir.current"
    _tmpdir_snapshot "${exclude_args[@]}" > "$current_file"

    if ! baseline_exists "$bdir" "tmpdir"; then
        cp "$current_file" "${bdir}/tmpdir"
        return 0
    fi

    local changes
    changes=$(baseline_compare "${bdir}/tmpdir" "$current_file")

    while IFS='|' read -r status path; do
        [[ -z "$status" ]] && continue
        case "$status" in
            ADDED)
                # Only report newly appearing executables/scripts (not .php, already flagged above)
                case "$path" in
                    *.sh|*.py|*.pl|*.rb|*.elf|*.out)
                        finding_add "WARNING" "tmpdir" "SYSTEM" "New script/binary in temp dir: ${path}"
                        ;;
                esac
                ;;
        esac
    done <<< "$changes"

    cp "$current_file" "${bdir}/tmpdir"
}

check_tmpdir_update() {
    local bdir
    bdir=$(baseline_dir_for "system" "tmpdir")
    local exclude_args=()
    for own_dir in "${LARAWATCH_STATE:-}" "${LARAWATCH_DIR:-}"; do
        [[ -n "$own_dir" ]] && exclude_args+=(-not -path "${own_dir}/*")
    done
    _tmpdir_snapshot "${exclude_args[@]}" > "${bdir}/tmpdir"
    out_ok "Updated tmpdir baseline"
}

# Accepts optional extra find args (e.g. exclusions) as positional parameters
_tmpdir_snapshot() {
    for scan_dir in "/tmp" "/var/tmp" "/dev/shm"; do
        [[ -d "$scan_dir" ]] || continue
        find "$scan_dir" -type f "$@" 2>/dev/null | sort | while IFS= read -r f; do
            local hash
            hash=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
            echo "${hash}  ${f}"
        done
    done
}
