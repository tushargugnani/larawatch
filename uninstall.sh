#!/usr/bin/env bash
# LaraWatch Uninstaller
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output.sh"

LARAWATCH_VERSION="0.1.0"

out_header "LaraWatch Uninstaller"
echo

# Confirm
printf "This will remove LaraWatch from this system.\n"
printf "The LaraWatch directory (${SCRIPT_DIR}) will NOT be deleted.\n\n"
read -rp "Continue? [y/N] " confirm
if [[ "${confirm,,}" != "y" ]]; then
    out_info "Uninstall cancelled"
    exit 0
fi

echo

# Remove cron job
if crontab -l 2>/dev/null | grep -qF "larawatch"; then
    crontab -l 2>/dev/null | grep -vF "larawatch" | crontab -
    out_ok "Removed cron job"
else
    out_dim "No cron job found"
fi

# Remove symlink
local_bin="${HOME}/.local/bin"
if [[ -L "${local_bin}/larawatch" ]]; then
    rm "${local_bin}/larawatch"
    out_ok "Removed symlink: ${local_bin}/larawatch"
else
    out_dim "No symlink found"
fi

# Remove state
if [[ -d "${SCRIPT_DIR}/state" ]]; then
    rm -rf "${SCRIPT_DIR}/state"
    out_ok "Removed state directory"
fi

# Optionally remove logs
read -rp "Remove logs? [y/N] " remove_logs
if [[ "${remove_logs,,}" == "y" ]]; then
    rm -rf "${SCRIPT_DIR}/logs"
    out_ok "Removed logs directory"
fi

# Optionally remove config
read -rp "Remove config? [y/N] " remove_config
if [[ "${remove_config,,}" == "y" ]]; then
    rm -f "${SCRIPT_DIR}/config/larawatch.conf"
    out_ok "Removed config"
fi

echo
out_ok "LaraWatch uninstalled"
out_info "To fully remove, delete: ${SCRIPT_DIR}"
echo
