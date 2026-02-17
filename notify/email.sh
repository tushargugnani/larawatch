#!/usr/bin/env bash
# LaraWatch - Email notification via SMTP (curl) or sendmail fallback

email_send() {
    local message="$1"
    local to="${EMAIL_TO:-}"

    if [[ -z "$to" ]]; then
        log_error "Email not configured: missing EMAIL_TO"
        return 1
    fi

    local from="${EMAIL_FROM:-larawatch@localhost}"
    local subject="LaraWatch Alert - $(hostname 2>/dev/null || echo 'server')"

    # Convert \n to actual newlines
    local formatted
    formatted=$(printf '%b' "$message")

    # Try SMTP via curl first, then sendmail/mail fallback
    if [[ -n "${EMAIL_SMTP_HOST:-}" ]]; then
        email_send_smtp "$to" "$from" "$subject" "$formatted"
    elif command -v sendmail &>/dev/null; then
        email_send_sendmail "$to" "$from" "$subject" "$formatted"
    elif command -v mail &>/dev/null; then
        email_send_mail "$to" "$subject" "$formatted"
    else
        log_error "No email transport available (configure SMTP or install sendmail/mail)"
        return 1
    fi
}

email_send_smtp() {
    local to="$1" from="$2" subject="$3" body="$4"
    local host="${EMAIL_SMTP_HOST}"
    local port="${EMAIL_SMTP_PORT:-587}"
    local user="${EMAIL_SMTP_USER:-}"
    local pass="${EMAIL_SMTP_PASS:-}"

    local mail_data
    mail_data=$(cat <<MAILEOF
From: ${from}
To: ${to}
Subject: ${subject}
Content-Type: text/plain; charset=UTF-8

${body}
MAILEOF
)

    local curl_args=(
        -s --max-time 30
        --url "smtp://${host}:${port}"
        --mail-from "$from"
        --mail-rcpt "$to"
        --ssl-reqd
        -T -
    )

    if [[ -n "$user" ]] && [[ -n "$pass" ]]; then
        curl_args+=(--user "${user}:${pass}")
    fi

    local response
    if response=$(echo "$mail_data" | curl "${curl_args[@]}" 2>&1); then
        log_info "Email notification sent to ${to} via SMTP"
        return 0
    else
        log_error "Email send via SMTP failed: ${response}"
        return 1
    fi
}

email_send_sendmail() {
    local to="$1" from="$2" subject="$3" body="$4"

    local mail_data
    mail_data=$(cat <<MAILEOF
From: ${from}
To: ${to}
Subject: ${subject}
Content-Type: text/plain; charset=UTF-8

${body}
MAILEOF
)

    if echo "$mail_data" | sendmail -t 2>/dev/null; then
        log_info "Email notification sent to ${to} via sendmail"
        return 0
    else
        log_error "Email send via sendmail failed"
        return 1
    fi
}

email_send_mail() {
    local to="$1" subject="$2" body="$3"

    if echo "$body" | mail -s "$subject" "$to" 2>/dev/null; then
        log_info "Email notification sent to ${to} via mail"
        return 0
    else
        log_error "Email send via mail failed"
        return 1
    fi
}

email_test() {
    local to="${EMAIL_TO:-}"

    if [[ -z "$to" ]]; then
        out_error "Email not configured. Run:"
        out_info "  larawatch config --email-to you@example.com"
        return 1
    fi

    local hostname_str
    hostname_str="$(hostname 2>/dev/null || echo 'unknown')"
    local test_msg="LaraWatch Test Notification\n\nHost: ${hostname_str}\nTime: $(date -u '+%Y-%m-%d %H:%M:%S UTC')\n\nIf you see this, email notifications are working."

    if email_send "$test_msg"; then
        out_ok "Email test notification sent to ${to}"
        return 0
    else
        out_error "Email test notification failed"
        return 1
    fi
}
