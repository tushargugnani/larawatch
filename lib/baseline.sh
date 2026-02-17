#!/usr/bin/env bash
# LaraWatch - Baseline create/compare/update

BASELINE_DIR="${LARAWATCH_STATE}/baselines"

# Create baseline directory for a site or system check
baseline_dir_for() {
    local type="$1" name="$2"
    local safe_name
    safe_name=$(echo "$name" | tr '/' '_' | tr ' ' '_' | tr '.' '_')
    local dir="${BASELINE_DIR}/${type}/${safe_name}"
    mkdir -p "$dir"
    echo "$dir"
}

# Store a baseline file (key-value pairs or raw content)
baseline_save() {
    local baseline_dir="$1" filename="$2"
    local target="${baseline_dir}/${filename}"
    cat > "$target"
}

# Load a baseline file
baseline_load() {
    local baseline_dir="$1" filename="$2"
    local target="${baseline_dir}/${filename}"
    if [[ -f "$target" ]]; then
        cat "$target"
        return 0
    fi
    return 1
}

# Check if baseline exists
baseline_exists() {
    local baseline_dir="$1" filename="$2"
    [[ -f "${baseline_dir}/${filename}" ]]
}

# Hash a single file
baseline_hash_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    fi
}

# Hash all PHP files in a site, excluding specified directories
baseline_hash_php_files() {
    local site_dir="$1"
    local exclude_patterns=(
        "*/storage/framework/views/*"
        "*/vendor/*"
        "*/bootstrap/cache/*"
        "*/node_modules/*"
    )

    local find_args=()
    find_args+=("$site_dir" -type f -name "*.php")
    for pattern in "${exclude_patterns[@]}"; do
        find_args+=(-not -path "$pattern")
    done

    find -L "${find_args[@]}" 2>/dev/null | sort | while IFS= read -r file; do
        local rel_path="${file#${site_dir}/}"
        local hash
        hash=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
        echo "${hash}  ${rel_path}"
    done
}

# Hash vendor state via installed.json
baseline_hash_vendor() {
    local site_dir="$1"
    local installed="${site_dir}/vendor/composer/installed.json"
    if [[ -f "$installed" ]]; then
        sha256sum "$installed" 2>/dev/null | awk '{print $1}'
    fi
}

# Compare two baseline files, return differences
# Output: STATUS|PATH (ADDED, REMOVED, MODIFIED)
baseline_compare() {
    local old_file="$1" new_file="$2"

    if [[ ! -f "$old_file" ]]; then
        # No old baseline, everything is new
        while IFS= read -r line; do
            local path
            path=$(echo "$line" | sed 's/^[a-f0-9]*  //')
            echo "ADDED|${path}"
        done < "$new_file"
        return
    fi

    # Find added and modified
    while IFS= read -r line; do
        local hash path
        hash=$(echo "$line" | awk '{print $1}')
        path=$(echo "$line" | sed 's/^[a-f0-9]*  //')
        local old_hash
        old_hash=$(grep "  ${path}$" "$old_file" 2>/dev/null | awk '{print $1}')
        if [[ -z "$old_hash" ]]; then
            echo "ADDED|${path}"
        elif [[ "$hash" != "$old_hash" ]]; then
            echo "MODIFIED|${path}"
        fi
    done < "$new_file"

    # Find removed
    while IFS= read -r line; do
        local path
        path=$(echo "$line" | sed 's/^[a-f0-9]*  //')
        if ! grep -q "  ${path}$" "$new_file" 2>/dev/null; then
            echo "REMOVED|${path}"
        fi
    done < "$old_file"
}

# Compare simple single-value baselines (hashes, port lists, etc.)
baseline_compare_lines() {
    local old_file="$1" new_file="$2"

    if [[ ! -f "$old_file" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            echo "ADDED|${line}"
        done < "$new_file"
        return
    fi

    # Added lines
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! grep -qFx "$line" "$old_file" 2>/dev/null; then
            echo "ADDED|${line}"
        fi
    done < "$new_file"

    # Removed lines
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! grep -qFx "$line" "$new_file" 2>/dev/null; then
            echo "REMOVED|${line}"
        fi
    done < "$old_file"
}

# Store last run timestamp for a check
baseline_set_last_run() {
    local check_name="$1"
    local ts_file="${LARAWATCH_STATE}/.lastrun_${check_name}"
    date +%s > "$ts_file"
}

# Get last run timestamp for a check
baseline_get_last_run() {
    local check_name="$1"
    local ts_file="${LARAWATCH_STATE}/.lastrun_${check_name}"
    if [[ -f "$ts_file" ]]; then
        cat "$ts_file"
        return 0
    fi
    echo "0"
}

# Update baseline (replace old with new)
baseline_update() {
    local baseline_dir="$1" filename="$2" new_file="$3"
    cp "$new_file" "${baseline_dir}/${filename}"
}
