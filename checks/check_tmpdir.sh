#!/usr/bin/env bash
# LaraWatch Check: Temp Directory Suspicious Files
# Scans /tmp, /var/tmp, and /dev/shm for PHP files and suspicious scripts.
# These directories are world-writable staging areas commonly used by attackers
# to drop webshells, reverse shells, or privilege escalation tools.
#
# NEW .php file in temp dirs = CRITICAL (baseline comparison)
# Suspicious script patterns (curl|wget piped to bash, base64 exec) = CRITICAL
#
# Standing PHP files that were present at baseline/update time are not re-alerted.
# Configure TMPDIR_EXCLUDE_PATHS to skip known agent/tool scratch trees
# (space-separated path prefixes or globs matched with [[ path == pattern ]]).

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

# Default exclusions: Claude/Cursor agent scratch trees under /tmp and /var/tmp
_TMPDIR_DEFAULT_EXCLUDES="/tmp/claude-* /var/tmp/claude-* /tmp/cursor-* /var/tmp/cursor-*"

check_tmpdir_run() {
    local bdir
    bdir=$(baseline_dir_for "system" "tmpdir")

    local scan_dirs=()
    for d in "/tmp" "/var/tmp" "/dev/shm"; do
        [[ -d "$d" ]] && scan_dirs+=("$d")
    done

    [[ ${#scan_dirs[@]} -eq 0 ]] && return 0

    # Build find exclusions for larawatch's own state/install dirs
    local exclude_args=()
    for own_dir in "${LARAWATCH_STATE:-}" "${LARAWATCH_DIR:-}"; do
        [[ -n "$own_dir" ]] && exclude_args+=(-not -path "${own_dir}/*")
    done

    # --- Snapshot current PHP + scripts ---
    local current_file="${bdir}/tmpdir.current"
    _tmpdir_snapshot "${exclude_args[@]}" > "$current_file"

    if ! baseline_exists "$bdir" "tmpdir"; then
        cp "$current_file" "${bdir}/tmpdir"
        return 0
    fi

    # Index baseline paths
    declare -A base_paths=()
    local hash path
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        path="${line#*  }"
        # sha256sum format: "hash  path" (two spaces)
        hash="${line%%  *}"
        [[ -z "$path" ]] && continue
        base_paths["$path"]="$hash"
    done < "${bdir}/tmpdir"

    # --- New PHP files (CRITICAL) ---
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        path="${line#*  }"
        hash="${line%%  *}"
        [[ -z "$path" ]] && continue
        _tmpdir_is_excluded "$path" && continue

        case "$path" in
            *.php)
                if [[ -z "${base_paths[$path]:-}" ]]; then
                    finding_add "CRITICAL" "tmpdir" "SYSTEM" "New PHP file in temp directory: ${path}"
                elif [[ "${base_paths[$path]}" != "$hash" ]]; then
                    finding_add "CRITICAL" "tmpdir" "SYSTEM" "Changed PHP file in temp directory: ${path}"
                fi
                ;;
        esac
    done < "$current_file"

    # --- Suspicious script patterns in non-PHP temp files (content scan, size-capped) ---
    local combined_pattern
    combined_pattern=$(printf '%s\n' "${_TMPDIR_SUSPICIOUS_PATTERNS[@]}" | paste -sd'|')

    for scan_dir in "${scan_dirs[@]}"; do
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            _tmpdir_is_excluded "$file" && continue
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

    # --- New non-PHP scripts/binaries ---
    local changes
    changes=$(baseline_compare "${bdir}/tmpdir" "$current_file")

    while IFS='|' read -r status path; do
        [[ -z "$status" ]] && continue
        _tmpdir_is_excluded "$path" && continue
        case "$status" in
            ADDED)
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

# Returns 0 if path matches a configured/default exclude pattern
_tmpdir_is_excluded() {
    local path="$1"
    local patterns="${TMPDIR_EXCLUDE_PATHS:-$_TMPDIR_DEFAULT_EXCLUDES}"
    local pat
    for pat in $patterns; do
        # shellcheck disable=SC2254
        case "$path" in
            $pat|$pat/*) return 0 ;;
        esac
    done
    return 1
}

# Accepts optional extra find args (e.g. exclusions) as positional parameters
_tmpdir_snapshot() {
    local scan_dir f hash
    for scan_dir in "/tmp" "/var/tmp" "/dev/shm"; do
        [[ -d "$scan_dir" ]] || continue
        find "$scan_dir" -type f "$@" 2>/dev/null | sort | while IFS= read -r f; do
            _tmpdir_is_excluded "$f" && continue
            hash=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
            echo "${hash}  ${f}"
        done
    done
}
