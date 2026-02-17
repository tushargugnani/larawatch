#!/usr/bin/env bash
# LaraWatch - Telegram notification via Bot API

telegram_send() {
    local message="$1"
    local token="${TELEGRAM_BOT_TOKEN:-}"
    local chat_id="${TELEGRAM_CHAT_ID:-}"

    if [[ -z "$token" ]] || [[ -z "$chat_id" ]]; then
        log_error "Telegram not configured: missing BOT_TOKEN or CHAT_ID"
        return 1
    fi

    local api_url="https://api.telegram.org/bot${token}/sendMessage"

    # Convert \n to actual newlines for the message
    local formatted
    formatted=$(printf '%b' "$message")

    # Telegram has a 4096 character limit
    if [[ ${#formatted} -gt 4000 ]]; then
        formatted="${formatted:0:3950}

... (truncated, see larawatch.log for full details)"
    fi

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "$api_url" \
        -d "chat_id=${chat_id}" \
        -d "text=${formatted}" \
        -d "parse_mode=" \
        --max-time 10 2>&1)

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        log_info "Telegram notification sent successfully"
        return 0
    else
        log_error "Telegram send failed (HTTP ${http_code}): ${body}"
        return 1
    fi
}

telegram_test() {
    local token="${TELEGRAM_BOT_TOKEN:-}"
    local chat_id="${TELEGRAM_CHAT_ID:-}"

    if [[ -z "$token" ]] || [[ -z "$chat_id" ]]; then
        out_error "Telegram not configured. Run:"
        out_info "  larawatch config --telegram-token YOUR_TOKEN --telegram-chat YOUR_CHAT_ID"
        return 1
    fi

    local hostname_str
    hostname_str="$(hostname 2>/dev/null || echo 'unknown')"
    local test_msg="LaraWatch Test Notification\n\nHost: ${hostname_str}\nTime: $(date -u '+%Y-%m-%d %H:%M:%S UTC')\n\nIf you see this, Telegram notifications are working."

    if telegram_send "$test_msg"; then
        out_ok "Telegram test notification sent"
        return 0
    else
        out_error "Telegram test notification failed"
        return 1
    fi
}
