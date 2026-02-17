#!/usr/bin/env bash
# LaraWatch Check: Service Exposure
# Checks if Redis, Memcached, or MySQL are bound to 0.0.0.0 (no baseline needed)
# Redis/Memcached = WARNING (common default), MySQL/PostgreSQL = WARNING

_check_exposed_port() {
    local ss_output="$1" port="$2"
    echo "$ss_output" | grep -qE "0\.0\.0\.0:${port}[[:space:]]|:::${port}[[:space:]]|\*:${port}[[:space:]]"
}

check_service_exposure_run() {
    local ss_output
    ss_output=$(ss -tlnp 2>/dev/null)

    if [[ -z "$ss_output" ]]; then
        return 0
    fi

    # Redis (default port 6379)
    if _check_exposed_port "$ss_output" 6379; then
        local redis_auth="no password"
        if command -v redis-cli &>/dev/null; then
            if redis-cli ping 2>/dev/null | grep -q "PONG"; then
                redis_auth="no password"
            else
                redis_auth="password may be set"
            fi
        fi
        finding_add "WARNING" "service_exposure" "SYSTEM" "Redis bound to 0.0.0.0:6379 (${redis_auth})"
    fi

    # Memcached (default port 11211)
    if _check_exposed_port "$ss_output" 11211; then
        finding_add "WARNING" "service_exposure" "SYSTEM" "Memcached bound to 0.0.0.0:11211 (no authentication by default)"
    fi

    # MySQL (default port 3306)
    if _check_exposed_port "$ss_output" 3306; then
        finding_add "WARNING" "service_exposure" "SYSTEM" "MySQL bound to 0.0.0.0:3306 (ensure firewall restricts access)"
    fi

    # PostgreSQL (default port 5432)
    if _check_exposed_port "$ss_output" 5432; then
        finding_add "WARNING" "service_exposure" "SYSTEM" "PostgreSQL bound to 0.0.0.0:5432 (ensure firewall restricts access)"
    fi
}

check_service_exposure_update() {
    out_ok "Service exposure check has no baseline (real-time detection)"
}
