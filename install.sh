#!/usr/bin/env bash
# LaraWatch Installer
# Usage: bash <(curl -s https://raw.githubusercontent.com/tushargugnani/larawatch/main/install.sh)
#    or: git clone ... ~/.larawatch && ~/.larawatch/install.sh
set -euo pipefail

LARAWATCH_REPO="https://github.com/tushargugnani/larawatch.git"
LARAWATCH_INSTALL_DIR="${HOME}/.larawatch"

# If running from curl (not inside the repo), clone first
if [[ ! -f "$(dirname "${BASH_SOURCE[0]}")/lib/output.sh" ]]; then
    if [[ -d "$LARAWATCH_INSTALL_DIR/.git" ]]; then
        echo "Updating existing installation..."
        git -C "$LARAWATCH_INSTALL_DIR" pull --ff-only 2>/dev/null || true
    elif [[ -d "$LARAWATCH_INSTALL_DIR" ]]; then
        echo "Removing stale directory and cloning fresh..."
        rm -rf "$LARAWATCH_INSTALL_DIR"
        git clone "$LARAWATCH_REPO" "$LARAWATCH_INSTALL_DIR"
    else
        git clone "$LARAWATCH_REPO" "$LARAWATCH_INSTALL_DIR"
    fi
    exec "$LARAWATCH_INSTALL_DIR/install.sh"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output.sh"

LARAWATCH_VERSION="0.1.0"

out_banner

# --- Step 1: Check prerequisites ---
out_header "Checking Prerequisites"

check_cmd() {
    local cmd="$1" purpose="$2"
    if command -v "$cmd" &>/dev/null; then
        out_ok "${cmd} found"
        return 0
    else
        out_error "${cmd} not found (needed for: ${purpose})"
        return 1
    fi
}

missing=0
check_cmd "bash" "shell (4.0+)" || missing=1
check_cmd "curl" "notifications" || missing=1
check_cmd "sha256sum" "file integrity" || missing=1
check_cmd "ss" "port monitoring" || missing=1
check_cmd "find" "file discovery" || missing=1
check_cmd "grep" "pattern matching" || missing=1

# Check bash version
bash_version="${BASH_VERSINFO[0]}"
if (( bash_version < 4 )); then
    out_error "Bash 4.0+ required (found ${BASH_VERSION})"
    missing=1
else
    out_ok "Bash ${BASH_VERSION}"
fi

if [[ "$missing" -eq 1 ]]; then
    out_error "Missing prerequisites. Install them and try again."
    exit 1
fi

# --- Step 2: Create directories ---
out_header "Setting Up Directories"
mkdir -p "${SCRIPT_DIR}/state" "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/config"
out_ok "Created state/, logs/, config/"

# --- Step 3: Create config ---
if [[ ! -f "${SCRIPT_DIR}/config/larawatch.conf" ]]; then
    cp "${SCRIPT_DIR}/config/larawatch.conf.example" "${SCRIPT_DIR}/config/larawatch.conf"
    out_ok "Created config/larawatch.conf"
else
    out_info "Config already exists, keeping current"
fi

# --- Step 4: Make executable ---
chmod +x "${SCRIPT_DIR}/larawatch"
out_ok "Made larawatch executable"

# --- Step 5: Add to PATH ---
out_header "Adding to PATH"
local_bin="${HOME}/.local/bin"
mkdir -p "$local_bin"

if [[ -L "${local_bin}/larawatch" ]]; then
    rm "${local_bin}/larawatch"
fi
ln -sf "${SCRIPT_DIR}/larawatch" "${local_bin}/larawatch"
out_ok "Symlinked to ${local_bin}/larawatch"

# Ensure ~/.local/bin is in PATH
if ! echo "$PATH" | grep -q "${local_bin}"; then
    # Add to shell profile
    for profile in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        if [[ -f "$profile" ]]; then
            if ! grep -q '\.local/bin' "$profile" 2>/dev/null; then
                echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "$profile"
                out_info "Added ~/.local/bin to PATH in $(basename "$profile")"
            fi
        fi
    done
    export PATH="${local_bin}:${PATH}"
fi

# --- Step 6: Initialize (discover sites, create baselines, interactive setup) ---
"${SCRIPT_DIR}/larawatch" init

echo
out_dim "All findings logged to: ${SCRIPT_DIR}/logs/larawatch.log"
out_dim "Run 'larawatch help' for all available commands."
echo
