#!/usr/bin/env bash
# LaraWatch - Core library: logging, config, locking, notification dispatch

LARAWATCH_VERSION="0.1.0"

# Resolve LARAWATCH_DIR to the directory containing the main 'larawatch' script
if [[ -z "${LARAWATCH_DIR:-}" ]]; then
    LARAWATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

LARAWATCH_CONF="${LARAWATCH_DIR}/config/larawatch.conf"
LARAWATCH_STATE="${LARAWATCH_DIR}/state"
LARAWATCH_LOGS="${LARAWATCH_DIR}/logs"
LARAWATCH_LOG="${LARAWATCH_LOGS}/larawatch.log"
LARAWATCH_LOCK="${LARAWATCH_STATE}/.larawatch.lock"
LARAWATCH_FINDINGS="${LARAWATCH_STATE}/.findings.tmp"

# Source output helpers
source "${LARAWATCH_DIR}/lib/output.sh"

# --- Config ---

config_load() {
    if [[ ! -f "$LARAWATCH_CONF" ]]; then
        out_error "Config not found: $LARAWATCH_CONF"
        out_info "Run 'larawatch init' or copy config/larawatch.conf.example to config/larawatch.conf"
        return 1
    fi
    # shellcheck source=/dev/null
    source "$LARAWATCH_CONF"
}

config_set() {
    local key="$1" value="$2"
    if [[ ! -f "$LARAWATCH_CONF" ]]; then
        cp "${LARAWATCH_DIR}/config/larawatch.conf.example" "$LARAWATCH_CONF"
    fi
    if grep -q "^${key}=" "$LARAWATCH_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$LARAWATCH_CONF"
    else
        echo "${key}=\"${value}\"" >> "$LARAWATCH_CONF"
    fi
}

config_get() {
    local key="$1" default="${2:-}"
    if [[ -f "$LARAWATCH_CONF" ]]; then
        local val
        val=$(grep "^${key}=" "$LARAWATCH_CONF" 2>/dev/null | head -1 | cut -d'=' -f2- | sed 's/^"//;s/"$//')
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

# --- Logging ---

log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    mkdir -p "$LARAWATCH_LOGS"
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$*" >> "$LARAWATCH_LOG"
}

log_info()     { log "INFO" "$@"; }
log_warn()     { log "WARNING" "$@"; }
log_error()    { log "ERROR" "$@"; }
log_critical() { log "CRITICAL" "$@"; }

# --- Locking ---

lock_acquire() {
    mkdir -p "$LARAWATCH_STATE"
    if [[ -f "$LARAWATCH_LOCK" ]]; then
        local lock_pid
        lock_pid=$(cat "$LARAWATCH_LOCK" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            out_error "Another LaraWatch scan is running (PID $lock_pid)"
            return 1
        fi
        rm -f "$LARAWATCH_LOCK"
    fi
    echo $$ > "$LARAWATCH_LOCK"
}

lock_release() {
    rm -f "$LARAWATCH_LOCK"
}

# --- Findings ---

findings_init() {
    mkdir -p "$LARAWATCH_STATE"
    : > "$LARAWATCH_FINDINGS"
}

finding_add() {
    local severity="$1" check="$2" site="$3" message="$4"
    printf "%s|%s|%s|%s\n" "$severity" "$check" "$site" "$message" >> "$LARAWATCH_FINDINGS"
    log "$severity" "[$check] [$site] $message"
}

findings_count() {
    local severity="${1:-}"
    local count=0
    if [[ -z "$severity" ]]; then
        count=$(wc -l < "$LARAWATCH_FINDINGS" 2>/dev/null) || count=0
    else
        count=$(grep -c "^${severity}|" "$LARAWATCH_FINDINGS" 2>/dev/null) || count=0
    fi
    echo "$count"
}

findings_get() {
    cat "$LARAWATCH_FINDINGS" 2>/dev/null
}

# --- Notification Dispatch ---

notify_dispatch() {
    local total
    total=$(findings_count)
    if [[ "$total" -eq 0 ]]; then
        return 0
    fi

    local critical_count warning_count info_count
    critical_count=$(findings_count "CRITICAL")
    warning_count=$(findings_count "WARNING")
    info_count=$(findings_count "INFO")

    # Check minimum severity
    local min_sev="${NOTIFY_MIN_SEVERITY:-WARNING}"
    case "$min_sev" in
        CRITICAL)
            [[ "$critical_count" -eq 0 ]] && return 0
            ;;
        WARNING)
            [[ "$critical_count" -eq 0 ]] && [[ "$warning_count" -eq 0 ]] && return 0
            ;;
        INFO) ;; # always send
    esac

    # Build message
    local hostname_str ip_str timestamp_str
    hostname_str="$(hostname 2>/dev/null || echo 'unknown')"
    ip_str="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'unknown')"
    timestamp_str="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    local message=""
    message+="LaraWatch Alert\n"
    message+="Host: ${hostname_str} (${ip_str})\n"
    message+="Time: ${timestamp_str}\n\n"

    local summary_parts=()
    [[ "$critical_count" -gt 0 ]] && summary_parts+=("CRITICAL x${critical_count}")
    [[ "$warning_count" -gt 0 ]] && summary_parts+=("WARNING x${warning_count}")
    [[ "$info_count" -gt 0 ]] && summary_parts+=("INFO x${info_count}")
    message+="$(IFS=', '; echo "${summary_parts[*]}")\n\n"

    while IFS='|' read -r severity check site msg; do
        # Apply min severity filter per finding
        case "$min_sev" in
            CRITICAL) [[ "$severity" != "CRITICAL" ]] && continue ;;
            WARNING)  [[ "$severity" == "INFO" ]] && continue ;;
        esac
        message+="[${severity}] ${check} | ${site}\n"
        message+="  ${msg}\n\n"
    done < "$LARAWATCH_FINDINGS"

    # Check cooldown (hash-based dedup)
    local findings_hash
    findings_hash=$(sha256sum "$LARAWATCH_FINDINGS" 2>/dev/null | awk '{print $1}')
    local cooldown_file="${LARAWATCH_STATE}/.cooldown_${findings_hash}"
    local cooldown_secs="${NOTIFY_COOLDOWN:-3600}"

    if [[ -f "$cooldown_file" ]] && [[ "$critical_count" -eq 0 ]]; then
        local last_sent
        last_sent=$(cat "$cooldown_file" 2>/dev/null)
        local now
        now=$(date +%s)
        if (( now - last_sent < cooldown_secs )); then
            log_info "Notification suppressed (cooldown). Hash: $findings_hash"
            return 0
        fi
    fi

    # Send via configured channels
    local sent=0
    if [[ "${NOTIFY_TELEGRAM:-false}" == "true" ]]; then
        if source "${LARAWATCH_DIR}/notify/telegram.sh" && telegram_send "$message"; then
            sent=1
        fi
    fi
    if [[ "${NOTIFY_EMAIL:-false}" == "true" ]]; then
        if source "${LARAWATCH_DIR}/notify/email.sh" && email_send "$message"; then
            sent=1
        fi
    fi

    if [[ "$sent" -eq 1 ]]; then
        date +%s > "$cooldown_file"
    fi

    # Clean old cooldown files (older than 24h)
    find "$LARAWATCH_STATE" -name '.cooldown_*' -mmin +1440 -delete 2>/dev/null
}

# --- Helpers ---

require_init() {
    if [[ ! -f "${LARAWATCH_STATE}/sites.list" ]]; then
        out_error "LaraWatch not initialized. Run 'larawatch init' first."
        return 1
    fi
}

get_site_name() {
    local path="$1"
    basename "$(dirname "$path")" 2>/dev/null || basename "$path"
}

ensure_dirs() {
    mkdir -p "$LARAWATCH_STATE" "$LARAWATCH_LOGS"
}
