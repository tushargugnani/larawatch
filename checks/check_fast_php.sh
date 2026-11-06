#!/usr/bin/env bash
# LaraWatch Check: Fast PHP path watch
# Lightweight scan for new/changed .php files in high-risk Laravel paths.
# Designed to run every minute via `larawatch watch`.
#
# Watched (per site):
#   storage/            (excl. framework/views, logs, framework/cache)
#   public/
#   bootstrap/cache/
# livewire-tmp PHP is always treated as CRITICAL.

# Default relative roots if FAST_PHP_PATHS is unset
_FAST_PHP_DEFAULT_PATHS="storage public bootstrap/cache"

check_fast_php_run() {
    local site_dir="$1" site_name="$2"
    [[ -d "$site_dir" ]] || return 0

    local bdir
    bdir=$(baseline_dir_for "$site_name" "fast_php")
    local current_file="${bdir}/fast_php.current"
    local baseline_file="${bdir}/fast_php"

    _fast_php_snapshot "$site_dir" > "$current_file"

    if ! baseline_exists "$bdir" "fast_php"; then
        cp "$current_file" "$baseline_file"
        log_info "fast_php: created baseline for ${site_name} ($(wc -l < "$baseline_file" | tr -d ' ') files)"
        return 0
    fi

    # Index baseline: path -> mtime|size|hash
    declare -A base_meta=()
    local path meta
    while IFS='|' read -r path meta; do
        [[ -z "$path" ]] && continue
        base_meta["$path"]="$meta"
    done < "$baseline_file"

    while IFS='|' read -r path meta; do
        [[ -z "$path" ]] && continue
        local prev="${base_meta[$path]:-}"
        local severity="CRITICAL"
        local kind="New"

        if [[ -n "$prev" ]]; then
            [[ "$prev" == "$meta" ]] && continue
            kind="Changed"
            # bootstrap/cache churns on artisan optimize — downgrade unless suspicious
            if [[ "$path" == bootstrap/cache/* ]]; then
                if _fast_php_content_suspicious "${site_dir}/${path}"; then
                    severity="CRITICAL"
                    kind="Suspicious change"
                else
                    severity="INFO"
                    kind="Cache rewrite"
                fi
            fi
        else
            # New file
            if [[ "$path" == storage/app/livewire-tmp/* ]] || [[ "$path" == */livewire-tmp/* ]]; then
                severity="CRITICAL"
                kind="New livewire-tmp"
            elif [[ "$path" == bootstrap/cache/* ]]; then
                if _fast_php_content_suspicious "${site_dir}/${path}"; then
                    severity="CRITICAL"
                    kind="Suspicious new cache"
                else
                    severity="INFO"
                    kind="New cache"
                fi
            elif [[ "$path" == public/* ]]; then
                severity="CRITICAL"
            elif [[ "$path" == storage/* ]]; then
                severity="CRITICAL"
            fi
        fi

        # Skip INFO unless min severity allows — still record for baseline update
        if [[ "$severity" == "INFO" ]]; then
            finding_add "INFO" "fast_php" "$site_name" "${kind} PHP: ${path}"
        else
            finding_add "$severity" "fast_php" "$site_name" "${kind} PHP: ${path}"
        fi
    done < "$current_file"

    # Detect deletions of previously seen livewire-tmp PHP (informational)
    # (no action — baseline will drop them on copy)

    cp "$current_file" "$baseline_file"
}

check_fast_php_update() {
    local site_dir="$1" site_name="$2"
    local bdir
    bdir=$(baseline_dir_for "$site_name" "fast_php")
    _fast_php_snapshot "$site_dir" > "${bdir}/fast_php"
    out_ok "Updated fast_php baseline for ${site_name}"
}

_fast_php_snapshot() {
    local site_dir="$1"
    local roots="${FAST_PHP_PATHS:-$_FAST_PHP_DEFAULT_PATHS}"
    local root

    for root in $roots; do
        local abs="${site_dir}/${root}"
        [[ -d "$abs" ]] || continue

        while IFS= read -r -d '' file; do
            [[ -z "$file" ]] && continue
            # Skip compiled Blade views and framework cache noise
            case "$file" in
                */storage/framework/views/*) continue ;;
                */storage/framework/cache/*) continue ;;
                */storage/logs/*) continue ;;
                */storage/framework/sessions/*) continue ;;
            esac

            local rel="${file#"${site_dir}/"}"
            local mtime size hash
            mtime=$(stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null || echo 0)
            size=$(stat -c '%s' "$file" 2>/dev/null || stat -f '%z' "$file" 2>/dev/null || echo 0)
            # Hash only small files for speed; large ones use mtime+size
            if (( size <= 1048576 )); then
                hash=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
            else
                hash="size:${size}"
            fi
            printf '%s|%s:%s:%s\n' "$rel" "$mtime" "$size" "$hash"
        done < <(find -L "$abs" -type f -name '*.php' -print0 2>/dev/null)
    done | sort
}

_fast_php_content_suspicious() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -qiE 'eval\s*\(|assert\s*\(|shell_exec\s*\(|system\s*\(|passthru\s*\(|base64_decode\s*\(|gzinflate\s*\(|\$_(POST|GET|REQUEST|COOKIE)\s*\[' "$file" 2>/dev/null
}
