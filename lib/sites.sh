#!/usr/bin/env bash
# LaraWatch - Flexible site discovery

# Discover Laravel sites by scanning for artisan + laravel/framework in composer.json
sites_discover() {
    local scan_dirs="${SCAN_DIRS:-/home}"
    local scan_depth="${SCAN_DEPTH:-4}"
    local exclude_sites="${EXCLUDE_SITES:-}"
    local discovered=()

    for scan_dir in $scan_dirs; do
        [[ ! -d "$scan_dir" ]] && continue

        while IFS= read -r artisan_path; do
            # Skip larawatch's own directory
            [[ "$artisan_path" == *"/larawatch/"* ]] && continue
            local site_dir
            site_dir="$(dirname "$artisan_path")"

            # Verify composer.json exists and contains laravel/framework
            local composer_file="${site_dir}/composer.json"
            if [[ ! -f "$composer_file" ]]; then
                continue
            fi
            if ! grep -q '"laravel/framework"' "$composer_file" 2>/dev/null; then
                continue
            fi

            # Skip excluded sites
            local site_name
            site_name=$(sites_get_name "$site_dir")
            if [[ -n "$exclude_sites" ]]; then
                local excluded=false
                for ex in $exclude_sites; do
                    if [[ "$site_name" == "$ex" ]] || [[ "$site_dir" == "$ex" ]]; then
                        excluded=true
                        break
                    fi
                done
                [[ "$excluded" == "true" ]] && continue
            fi

            # Resolve symlinks to get the real path
            local real_dir
            real_dir="$(readlink -f "$site_dir")"

            # Check if this path is behind a symlink (Forge/Envoyer style)
            local symlink_target=""
            local parent_dir
            parent_dir="$(dirname "$site_dir")"
            if [[ -L "${parent_dir}/current" ]]; then
                symlink_target="$(readlink -f "${parent_dir}/current")"
            elif [[ -L "$site_dir" ]]; then
                symlink_target="$real_dir"
            fi

            # Deduplicate by site name, preferring 'current' symlink paths
            local already_found=false
            if [[ ${#discovered[@]} -gt 0 ]]; then
                local idx=0
                for d in "${discovered[@]}"; do
                    local existing_name existing_path
                    existing_path="$(echo "$d" | cut -d'|' -f1)"
                    existing_name=$(sites_get_name "$existing_path")
                    if [[ "$existing_name" == "$site_name" ]]; then
                        already_found=true
                        # Prefer the 'current' symlink path over release paths
                        if [[ "$(basename "$site_dir")" == "current" ]] && [[ "$(basename "$existing_path")" != "current" ]]; then
                            discovered[$idx]="${site_dir}|${real_dir}|${symlink_target}"
                        fi
                        break
                    fi
                    idx=$((idx + 1))
                done
            fi
            [[ "$already_found" == "true" ]] && continue

            discovered+=("${site_dir}|${real_dir}|${symlink_target}")
        done < <(find -L "$scan_dir" -maxdepth "$scan_depth" -name "artisan" -type f 2>/dev/null)
    done

    printf '%s\n' "${discovered[@]}"
}

# Get a human-readable name for a site
sites_get_name() {
    local site_dir="$1"
    # Resolve through 'current' symlinks
    local dir="$site_dir"
    if [[ "$(basename "$dir")" == "current" ]]; then
        dir="$(dirname "$dir")"
    fi
    # For release-style paths, go up
    if [[ "$(basename "$(dirname "$dir")")" == "releases" ]]; then
        dir="$(dirname "$(dirname "$dir")")"
    fi
    basename "$dir"
}

# Save discovered sites to state
sites_save() {
    local sites_file="${LARAWATCH_STATE}/sites.list"
    : > "$sites_file"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "$line" >> "$sites_file"
    done
}

# Load sites from state
sites_load() {
    local sites_file="${LARAWATCH_STATE}/sites.list"
    if [[ ! -f "$sites_file" ]]; then
        return 1
    fi
    cat "$sites_file"
}

# Add a manual site
sites_add() {
    local path="$1"
    path="$(readlink -f "$path" 2>/dev/null || echo "$path")"

    if [[ ! -f "${path}/artisan" ]]; then
        out_error "No artisan file found at ${path}"
        return 1
    fi
    if [[ ! -f "${path}/composer.json" ]]; then
        out_error "No composer.json found at ${path}"
        return 1
    fi

    local sites_file="${LARAWATCH_STATE}/sites.list"
    local site_name
    site_name=$(sites_get_name "$path")

    # Check for duplicates
    if grep -q "|${path}|" "$sites_file" 2>/dev/null || grep -q "^${path}|" "$sites_file" 2>/dev/null; then
        out_warn "Site already tracked: ${path}"
        return 0
    fi

    local symlink_target=""
    local parent_dir
    parent_dir="$(dirname "$path")"
    if [[ -L "${parent_dir}/current" ]]; then
        symlink_target="$(readlink -f "${parent_dir}/current")"
    fi

    echo "${path}|${path}|${symlink_target}" >> "$sites_file"

    # Also add to MANUAL_SITES in config
    local current_manual
    current_manual=$(config_get "MANUAL_SITES" "")
    if [[ -z "$current_manual" ]]; then
        config_set "MANUAL_SITES" "$path"
    else
        config_set "MANUAL_SITES" "${current_manual} ${path}"
    fi

    out_ok "Added site: ${site_name} (${path})"
}

# Remove a site
sites_remove() {
    local identifier="$1"
    local sites_file="${LARAWATCH_STATE}/sites.list"

    if [[ ! -f "$sites_file" ]]; then
        out_error "No sites tracked"
        return 1
    fi

    local found=false
    local tmpfile="${sites_file}.tmp"
    : > "$tmpfile"

    while IFS='|' read -r path real_path symlink; do
        local name
        name=$(sites_get_name "$path")
        if [[ "$name" == "$identifier" ]] || [[ "$path" == "$identifier" ]] || [[ "$real_path" == "$identifier" ]]; then
            found=true
            # Remove baseline data
            local safe_name
            safe_name=$(echo "$name" | tr '/' '_' | tr ' ' '_')
            rm -rf "${LARAWATCH_STATE}/baselines/${safe_name}" 2>/dev/null
            out_ok "Removed site: ${name}"
        else
            echo "${path}|${real_path}|${symlink}" >> "$tmpfile"
        fi
    done < "$sites_file"

    mv "$tmpfile" "$sites_file"

    if [[ "$found" == "false" ]]; then
        out_error "Site not found: ${identifier}"
        return 1
    fi
}

# List all tracked sites with status
sites_list() {
    local sites_file="${LARAWATCH_STATE}/sites.list"
    if [[ ! -f "$sites_file" ]] || [[ ! -s "$sites_file" ]]; then
        out_warn "No sites tracked. Run 'larawatch init' to discover sites."
        return 1
    fi

    while IFS='|' read -r path real_path symlink; do
        [[ -z "$path" ]] && continue
        local name
        name=$(sites_get_name "$path")
        echo "${name}|${path}|${real_path}|${symlink}"
    done < "$sites_file"
}

# Check for deployment (symlink target changed)
sites_check_deployment() {
    local path="$1" stored_symlink="$2"
    [[ -z "$stored_symlink" ]] && return 1

    # If path ends with /current, check it directly
    if [[ "$(basename "$path")" == "current" ]] && [[ -L "$path" ]]; then
        local current_target
        current_target="$(readlink -f "$path")"
        if [[ "$current_target" != "$stored_symlink" ]]; then
            return 0 # deployment detected
        fi
        return 1
    fi

    local parent_dir
    parent_dir="$(dirname "$path")"
    if [[ -L "${parent_dir}/current" ]]; then
        local current_target
        current_target="$(readlink -f "${parent_dir}/current")"
        if [[ "$current_target" != "$stored_symlink" ]]; then
            return 0 # deployment detected
        fi
    fi
    return 1
}

# Get site path by name or path identifier
sites_get_path() {
    local identifier="$1"
    local sites_file="${LARAWATCH_STATE}/sites.list"

    [[ ! -f "$sites_file" ]] && return 1

    while IFS='|' read -r path real_path symlink; do
        local name
        name=$(sites_get_name "$path")
        if [[ "$name" == "$identifier" ]] || [[ "$path" == "$identifier" ]]; then
            echo "$path"
            return 0
        fi
    done < "$sites_file"
    return 1
}
