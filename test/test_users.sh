#!/usr/bin/env bash
# Unit + local integration tests for check_users ignore rules.
# Run: ./test/test_users.sh
# Also invoked from ./test.sh users (inside Docker).
# No -e: check_users_run uses pipelines (sha256sum | awk) that can fail
# on unreadable /etc/sudoers; the main larawatch script is also set +e.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

check() {
    local description="$1"
    shift
    if "$@"; then
        echo "  PASS: ${description}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${description}"
        FAIL=$((FAIL + 1))
    fi
}

assert_ignored() {
    _users_should_ignore "$1"
}

assert_not_ignored() {
    if _users_should_ignore "$1"; then
        return 1
    fi
    return 0
}

finding_absent() {
    if grep -q "$1" "$LARAWATCH_FINDINGS"; then
        return 1
    fi
    return 0
}

finding_present() {
    grep -q "$1" "$LARAWATCH_FINDINGS"
}

# Source just the ignore helper (no libs required)
# shellcheck source=/dev/null
source "${REPO_DIR}/checks/check_users.sh"

echo "=== Unit: _users_should_ignore ==="

unset IGNORE_USER_SHELLS IGNORE_USERS

check "ignore /sbin/nologin" assert_ignored "dnsmasq:977:/sbin/nologin"
check "ignore /usr/sbin/nologin" assert_ignored "nobody:65534:/usr/sbin/nologin"
check "ignore /bin/false" assert_ignored "bin:2:/bin/false"
check "ignore /bin/true" assert_ignored "sync:4:/bin/true"
check "ignore /usr/bin/nologin" assert_ignored "sshd:105:/usr/bin/nologin"
check "ignore similar path /bin/nologin (basename)" assert_ignored "pkg:200:/bin/nologin"
check "ignore similar path /usr/bin/false (basename)" assert_ignored "daemon:1:/usr/bin/false"

check "alert /bin/bash" assert_not_ignored "alice:1000:/bin/bash"
check "alert /bin/sh" assert_not_ignored "bob:1001:/bin/sh"
check "alert /usr/bin/zsh" assert_not_ignored "carol:1002:/usr/bin/zsh"

IGNORE_USERS="ciuser deploybot"
check "ignore explicit username with bash" assert_ignored "ciuser:2003:/bin/bash"
check "ignore second IGNORE_USERS name" assert_ignored "deploybot:2004:/bin/sh"
check "do not ignore unrelated username" assert_not_ignored "other:2005:/bin/bash"
unset IGNORE_USERS

IGNORE_USER_SHELLS="/sbin/nologin"
check "custom IGNORE_USER_SHELLS still matches nologin" assert_ignored "dnsmasq:977:/usr/sbin/nologin"
check "custom IGNORE_USER_SHELLS does not match omitted /bin/false" assert_not_ignored "sys:3:/bin/false"
unset IGNORE_USER_SHELLS

echo ""
echo "=== Integration: check_users_run ==="

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "${WORKDIR}"/{lib,checks,config,state,logs,notify}
cp "${REPO_DIR}"/lib/*.sh "${WORKDIR}/lib/"
cp "${REPO_DIR}/checks/check_users.sh" "${WORKDIR}/checks/"
cp "${REPO_DIR}/config/larawatch.conf.example" "${WORKDIR}/config/larawatch.conf"

export LARAWATCH_DIR="$WORKDIR"
# shellcheck source=/dev/null
source "${WORKDIR}/lib/core.sh"
# shellcheck source=/dev/null
source "${WORKDIR}/lib/baseline.sh"
# shellcheck source=/dev/null
source "${WORKDIR}/checks/check_users.sh"
config_load
findings_init

PASSWD_FILE="${WORKDIR}/passwd"
cat > "$PASSWD_FILE" << 'EOF'
root:x:0:0:root:/root:/bin/bash
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
EOF
export USERS_PASSWD_FILE="$PASSWD_FILE"

# First run creates the baseline
check_users_run

# 1. New nologin service account — no CRITICAL
echo "dnsmasq:x:977:977:dnsmasq:/var/lib/misc:/sbin/nologin" >> "$PASSWD_FILE"
findings_init
check_users_run
check "new /sbin/nologin user is not a finding" finding_absent "New user account: dnsmasq"

# 2. New /bin/false user — no CRITICAL
echo "sysfalse:x:978:978::/:/bin/false" >> "$PASSWD_FILE"
findings_init
check_users_run
check "new /bin/false user is not a finding" finding_absent "New user account: sysfalse"

# 3. New login-shell user — CRITICAL
echo "hacker:x:2001:2001::/home/hacker:/bin/bash" >> "$PASSWD_FILE"
findings_init
check_users_run
check "new /bin/bash user is CRITICAL" finding_present "CRITICAL|users|SYSTEM|New user account: hacker:2001:/bin/bash"

# 4. New /bin/sh user — CRITICAL
echo "shelluser:x:2002:2002::/home/shelluser:/bin/sh" >> "$PASSWD_FILE"
findings_init
check_users_run
check "new /bin/sh user is CRITICAL" finding_present "CRITICAL|users|SYSTEM|New user account: shelluser:2002:/bin/sh"

# 5. IGNORE_USERS with a real login shell — no CRITICAL
echo 'IGNORE_USERS="ciuser"' >> "${WORKDIR}/config/larawatch.conf"
# shellcheck source=/dev/null
source "${WORKDIR}/config/larawatch.conf"
echo "ciuser:x:2003:2003::/home/ciuser:/bin/bash" >> "$PASSWD_FILE"
findings_init
check_users_run
check "IGNORE_USERS login-shell user is not a finding" finding_absent "New user account: ciuser"

# 6. Baseline the current passwd, then remove nologin vs login users
check_users_update >/dev/null
grep -v '^dnsmasq:' "$PASSWD_FILE" | grep -v '^hacker:' > "${PASSWD_FILE}.tmp"
mv "${PASSWD_FILE}.tmp" "$PASSWD_FILE"
findings_init
check_users_run
check "removed nologin user is not a finding" finding_absent "User account removed: dnsmasq"
check "removed login-shell user is WARNING" finding_present "WARNING|users|SYSTEM|User account removed: hacker:2001:/bin/bash"

# 7. nologin → bash is still CRITICAL (new login-shell line)
echo "dnsmasq:x:977:977:dnsmasq:/var/lib/misc:/bin/bash" >> "$PASSWD_FILE"
findings_init
check_users_run
check "nologin upgraded to bash is CRITICAL" finding_present "CRITICAL|users|SYSTEM|New user account: dnsmasq:977:/bin/bash"

echo ""
echo "================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "================================"
[[ "$FAIL" -eq 0 ]]
