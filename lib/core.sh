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
LARAWATCH_NOTIFIED="${LARAWATCH_STATE}/.notified"

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

# Build a stable dedup key for a finding. Volatile detail is stripped so that a
# fluctuating value (cpu %, memory %, PIDs, request counts, the "top: ..." tail)
# still maps to the same key across scans -- otherwise every scan would look new.
notify_finding_key() {
    local severity="$1" check="$2" site="$3" msg="$4"
    msg="${msg%%—*}"
    msg="$(printf '%s' "$msg" | sed 's/[0-9][0-9.,:]*/#/g; s/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')"
    printf '%s|%s|%s|%s' "$severity" "$check" "$site" "$msg" | sha256sum | awk '{print $1}'
}

notify_dispatch() {
    local total
    total=$(findings_count)
    if [[ "$total" -eq 0 ]]; then
        return 0
    fi

    local min_sev="${NOTIFY_MIN_SEVERITY:-CRITICAL}"
    # 0 = never repeat while a finding keeps being seen
    local repeat_after="${NOTIFY_REPEAT_AFTER:-0}"
    # Forget a finding this long after it stops appearing; it then alerts as new
    local forget_after="${NOTIFY_FORGET_AFTER:-86400}"

    local now
    now=$(date +%s)

    # Previously notified findings: key -> first_notified
    declare -gA notified_at=()
    if [[ -f "$LARAWATCH_NOTIFIED" ]]; then
        local k first last
        while IFS='|' read -r k first last; do
            [[ -z "$k" ]] && continue
            (( now - ${last:-0} > forget_after )) && continue
            notified_at["$k"]="${first:-$last}"
        done < "$LARAWATCH_NOTIFIED"
    fi

    # Split the eligible findings into new (notify now) and already-reported
    local new_lines=() new_keys=() seen_keys=()
    local critical_count=0 warning_count=0 info_count=0
    local severity check site msg key
    while IFS='|' read -r severity check site msg; do
        [[ -z "$severity" ]] && continue
        case "$min_sev" in
            CRITICAL) [[ "$severity" != "CRITICAL" ]] && continue ;;
            WARNING)  [[ "$severity" == "INFO" ]] && continue ;;
        esac

        key=$(notify_finding_key "$severity" "$check" "$site" "$msg")
        seen_keys+=("$key")

        if [[ -n "${notified_at[$key]:-}" ]]; then
            if [[ "$repeat_after" -le 0 ]] || (( now - notified_at[$key] < repeat_after )); then
                continue
            fi
        fi

        new_lines+=("${severity}|${check}|${site}|${msg}")
        new_keys+=("$key")
        case "$severity" in
            CRITICAL) critical_count=$((critical_count + 1)) ;;
            WARNING)  warning_count=$((warning_count + 1)) ;;
            INFO)     info_count=$((info_count + 1)) ;;
        esac
    done < "$LARAWATCH_FINDINGS"

    if [[ "${#new_lines[@]}" -eq 0 ]]; then
        log_info "Notification suppressed: no new findings (${#seen_keys[@]} already reported)"
        notify_state_write "$now" "$forget_after" "${seen_keys[@]}"
        return 0
    fi

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
    message+="New: $(IFS=', '; echo "${summary_parts[*]}")\n\n"

    local line
    for line in "${new_lines[@]}"; do
        IFS='|' read -r severity check site msg <<< "$line"
        message+="[${severity}] ${check} | ${site}\n"
        message+="  ${msg}\n\n"
    done

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
        log_info "Notified ${#new_lines[@]} new finding(s)"
        # Mark the new keys as notified now; refresh last-seen for the rest
        local nk
        for nk in "${new_keys[@]}"; do
            notified_at["$nk"]="$now"
        done
    else
        log_warn "No notification channel delivered; new findings stay pending"
    fi
    notify_state_write "$now" "$forget_after" "${seen_keys[@]}"

    # Drop cooldown files from the pre-0.2 whole-scan dedup scheme
    find "$LARAWATCH_STATE" -maxdepth 1 -name '.cooldown_*' -delete 2>/dev/null
}

# notify_state_write <now> <forget_after> <seen keys...>
# Rewrites the notified-state file from the global `notified_at` map: every key
# seen this scan gets last_seen=now, keys not seen this scan are carried over
# until they age past forget_after. Keys seen but never delivered are skipped so
# they are still treated as new on the next scan.
notify_state_write() {
    local now="$1" forget_after="$2"
    shift 2

    declare -A first_at=()
    local k
    for k in "${!notified_at[@]}"; do first_at["$k"]="${notified_at[$k]}"; done

    declare -A is_seen=()
    for k in "$@"; do is_seen["$k"]=1; done

    declare -A prev_last=()
    if [[ -f "$LARAWATCH_NOTIFIED" ]]; then
        local pk pf pl
        while IFS='|' read -r pk pf pl; do
            [[ -z "$pk" ]] && continue
            prev_last["$pk"]="${pl:-0}"
        done < "$LARAWATCH_NOTIFIED"
    fi

    local tmpfile="${LARAWATCH_NOTIFIED}.tmp"
    : > "$tmpfile"
    for k in "${!first_at[@]}"; do
        local last
        if [[ -n "${is_seen[$k]:-}" ]]; then
            last="$now"
        else
            last="${prev_last[$k]:-0}"
            (( now - last > forget_after )) && continue
        fi
        printf '%s|%s|%s\n' "$k" "${first_at[$k]}" "$last" >> "$tmpfile"
    done
    mv "$tmpfile" "$LARAWATCH_NOTIFIED"
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
