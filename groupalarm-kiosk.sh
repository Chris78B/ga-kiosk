#!/bin/bash
#
# GroupAlarm Monitor Kiosk Controller v5.6
# Openbox starts this script once with "start". The web interface uses the
# same commands to manage Chromium inside the active desktop session.

set -u

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-/home/groupalarm/.Xauthority}"
export HOME="${HOME:-/home/groupalarm}"

CONFIG_FILE="${HOME}/.groupalarm-monitor/config.json"
STATE_DIR="${HOME}/.groupalarm-monitor"
PID_FILE="${STATE_DIR}/kiosk.pid"
STOP_FILE="${STATE_DIR}/kiosk.stopped"
MAX_WAIT=30
WAIT_INTERVAL=1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

ensure_state_dir() {
    mkdir -p "${STATE_DIR}"
}

detect_chromium_binary() {
    if command -v chromium-browser >/dev/null 2>&1; then
        echo "chromium-browser"
        return 0
    fi

    if command -v chromium >/dev/null 2>&1; then
        echo "chromium"
        return 0
    fi

    return 1
}

wait_for_x11() {
    local count=0
    while [ "${count}" -lt "${MAX_WAIT}" ]; do
        if xset q >/dev/null 2>&1; then
            return 0
        fi

        sleep "${WAIT_INTERVAL}"
        count=$((count + 1))
    done

    return 1
}

read_config_value() {
    local key="$1"
    local default_value="$2"

    if [ ! -f "${CONFIG_FILE}" ] || ! command -v jq >/dev/null 2>&1; then
        printf '%s' "${default_value}"
        return 0
    fi

    local value
    value=$(jq -r "${key} // empty" "${CONFIG_FILE}" 2>/dev/null || true)
    if [ -z "${value}" ] || [ "${value}" = "null" ]; then
        printf '%s' "${default_value}"
    else
        printf '%s' "${value}"
    fi
}

build_groupalarm_url() {
    local base_url token dark_theme separator
    base_url=$(read_config_value '.groupalarm_url' 'https://app.groupalarm.com/de/monitor')
    token=$(read_config_value '.groupalarm_token' '')
    dark_theme=$(read_config_value '.dark_theme' 'false')

    if [ -n "${token}" ] && [[ "${base_url}" != *"view_token="* ]]; then
        if [[ "${base_url}" == *"?"* ]]; then
            separator="&"
        else
            separator="?"
        fi
        base_url="${base_url}${separator}view_token=${token}"
    fi

    if [ "${dark_theme}" = "true" ] && [[ "${base_url}" != *"theme=dark-theme"* ]]; then
        if [[ "${base_url}" == *"?"* ]]; then
            separator="&"
        else
            separator="?"
        fi
        base_url="${base_url}${separator}theme=dark-theme"
    fi

    printf '%s' "${base_url}"
}

is_pid_running() {
    local pid="$1"
    [ -n "${pid}" ] && kill -0 "${pid}" >/dev/null 2>&1
}

find_chromium_pid() {
    local pid=""

    if [ -f "${PID_FILE}" ]; then
        pid=$(cat "${PID_FILE}" 2>/dev/null || true)
        if is_pid_running "${pid}"; then
            printf '%s' "${pid}"
            return 0
        fi
        rm -f "${PID_FILE}"
    fi

    pid=$(pgrep -n -f 'chromium(|-browser).*(--kiosk|--start-maximized)' 2>/dev/null || true)
    if [ -n "${pid}" ]; then
        printf '%s' "${pid}"
        return 0
    fi

    return 1
}

apply_x11_settings() {
    xset s off >/dev/null 2>&1 || true
    xset -dpms >/dev/null 2>&1 || true
    xset s noblank >/dev/null 2>&1 || true
}

ensure_unclutter() {
    if command -v unclutter >/dev/null 2>&1 && ! pgrep -x unclutter >/dev/null 2>&1; then
        unclutter -idle 0.5 -root >/dev/null 2>&1 &
    fi
}

enforce_fullscreen() {
    if ! command -v wmctrl >/dev/null 2>&1; then
        return 0
    fi

    local count=0
    while [ "${count}" -lt 20 ]; do
        if wmctrl -l | grep -i "chromium" >/dev/null 2>&1; then
            wmctrl -r "Chromium" -b add,maximized_vert,maximized_horz >/dev/null 2>&1 || true
            wmctrl -r "Chromium" -b add,fullscreen >/dev/null 2>&1 || true
            wmctrl -r "Chromium" -b add,sticky >/dev/null 2>&1 || true
            return 0
        fi

        sleep 0.5
        count=$((count + 1))
    done

    return 1
}

start_kiosk() {
    ensure_state_dir

    local existing_pid
    existing_pid=$(find_chromium_pid || true)
    if [ -n "${existing_pid}" ]; then
        log "Kiosk laeuft bereits (PID ${existing_pid})."
        return 0
    fi

    if ! wait_for_x11; then
        log "X11 ist nicht bereit, Chromium kann nicht gestartet werden."
        return 1
    fi

    local chromium_bin target_url
    chromium_bin=$(detect_chromium_binary) || {
        log "Kein Chromium-Binary gefunden."
        return 1
    }
    target_url=$(build_groupalarm_url)

    apply_x11_settings
    ensure_unclutter
    rm -f "${STOP_FILE}"

    "${chromium_bin}" \
        --kiosk \
        --start-maximized \
        --incognito \
        --no-first-run \
        --no-default-browser-check \
        --disable-infobars \
        --disable-translate \
        --disable-restore-session-state \
        --disable-popup-blocking \
        --disable-prompt-on-repost \
        --disable-print-preview \
        --disable-component-extensions-with-background-pages \
        --disable-background-networking \
        --disable-breakpad \
        --disable-client-side-phishing-detection \
        --disable-default-apps \
        --disable-extensions \
        --disable-hung-renderer-warning \
        --disable-preconnect \
        --disable-sync \
        "${target_url}" >/dev/null 2>&1 &

    local chromium_pid=$!
    echo "${chromium_pid}" > "${PID_FILE}"
    sleep 2

    if ! is_pid_running "${chromium_pid}"; then
        rm -f "${PID_FILE}"
        log "Chromium ist direkt nach dem Start wieder beendet worden."
        return 1
    fi

    enforce_fullscreen || true
    log "Kiosk gestartet (PID ${chromium_pid})."
    return 0
}

stop_kiosk() {
    ensure_state_dir
    : > "${STOP_FILE}"

    local pid
    pid=$(find_chromium_pid || true)
    if [ -z "${pid}" ]; then
        rm -f "${PID_FILE}"
        log "Kiosk laeuft nicht."
        return 0
    fi

    kill "${pid}" >/dev/null 2>&1 || true
    sleep 1

    if is_pid_running "${pid}"; then
        kill -9 "${pid}" >/dev/null 2>&1 || true
    fi

    pkill -f 'chromium(|-browser).*(--kiosk|--start-maximized)' >/dev/null 2>&1 || true
    rm -f "${PID_FILE}"
    log "Kiosk gestoppt."
    return 0
}

status_kiosk() {
    local pid
    pid=$(find_chromium_pid || true)
    if [ -n "${pid}" ]; then
        log "Kiosk aktiv (PID ${pid})."
        return 0
    fi

    log "Kiosk inaktiv."
    return 1
}

restart_kiosk() {
    stop_kiosk
    sleep 1
    start_kiosk
}

case "${1:-start}" in
    start)
        start_kiosk
        ;;
    stop)
        stop_kiosk
        ;;
    restart)
        restart_kiosk
        ;;
    status)
        status_kiosk
        ;;
    *)
        echo "Verwendung: $0 {start|stop|restart|status}"
        exit 2
        ;;
esac
