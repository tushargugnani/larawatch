#!/usr/bin/env bash
# LaraWatch - Terminal formatting and output helpers

# Colors (disabled when not a terminal or NO_COLOR is set)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' RESET=''
fi

out_info()     { printf "${BLUE}[INFO]${RESET} %s\n" "$*"; }
out_ok()       { printf "${GREEN}[OK]${RESET} %s\n" "$*"; }
out_warn()     { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
out_error()    { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
out_critical() { printf "${RED}${BOLD}[CRITICAL]${RESET} %s\n" "$*" >&2; }

out_header() {
    printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n" "$*"
}

out_subheader() {
    printf "%b%s%b\n" "${BOLD}--- " "$*" " ---${RESET}"
}

out_dim() {
    printf "${DIM}%s${RESET}\n" "$*"
}

out_status_line() {
    local label="$1" value="$2" color="${3:-$RESET}"
    printf "  ${BOLD}%-20s${RESET} ${color}%s${RESET}\n" "$label" "$value"
}

out_table_row() {
    local severity="$1" check="$2" site="$3" message="$4"
    local color="$RESET"
    case "$severity" in
        CRITICAL) color="$RED" ;;
        WARNING)  color="$YELLOW" ;;
        INFO)     color="$BLUE" ;;
    esac
    printf "${color}%-10s${RESET} %-20s %-25s %s\n" "[$severity]" "$check" "$site" "$message"
}

out_banner() {
    printf "${BOLD}${CYAN}"
    printf "  _                __        __    _       _     \n"
    printf " | |    __ _ _ __ __ \\ \\      / /_ _| |_ ___| |__  \n"
    printf " | |   / _\` | '__/ _\` \\ \\ /\\ / / _\` | __/ __| '_ \\ \n"
    printf " | |__| (_| | | | (_| |\\ V  V / (_| | || (__| | | |\n"
    printf " |_____\\__,_|_|  \\__,_| \\_/\\_/ \\__,_|\\__\\___|_| |_|\n"
    printf "${RESET}\n"
    printf " ${DIM}Laravel Server Security Monitor v%s${RESET}\n\n" "${LARAWATCH_VERSION:-0.1.0}"
}

# Spinner for long operations
_spinner_pid=""

spinner_start() {
    local msg="${1:-Working...}"
    if [[ ! -t 1 ]]; then
        printf "%s\n" "$msg"
        return
    fi
    (
        local chars='|/-\'
        local i=0
        while true; do
            printf "\r${DIM}%s %s${RESET}" "${chars:i++%4:1}" "$msg"
            sleep 0.1
        done
    ) &
    _spinner_pid=$!
    disown "$_spinner_pid" 2>/dev/null
}

spinner_stop() {
    if [[ -n "$_spinner_pid" ]]; then
        kill "$_spinner_pid" 2>/dev/null
        wait "$_spinner_pid" 2>/dev/null
        _spinner_pid=""
        printf "\r\033[K"
    fi
}
