#!/bin/bash
#
# GroupAlarm Monitor Heartbeat v5.6
# Sends a small heartbeat to the external ga-mon/watcher.php endpoint.

set -euo pipefail

CONFIG_FILE="/home/groupalarm/.groupalarm-monitor/config.json"
LOG_FILE="/home/groupalarm/.groupalarm-monitor/groupalarm-heartbeat.log"
VERSION="5.6"

log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "[${timestamp}] $*" >> "${LOG_FILE}"
}

read_config() {
    local key="$1"
    local default_value="$2"

    if [[ ! -f "${CONFIG_FILE}" ]] || ! command -v jq >/dev/null 2>&1; then
        printf '%s' "${default_value}"
        return 0
    fi

    local value
    value="$(jq -r "${key} // empty" "${CONFIG_FILE}" 2>/dev/null || true)"
    if [[ -z "${value}" || "${value}" == "null" ]]; then
        printf '%s' "${default_value}"
    else
        printf '%s' "${value}"
    fi
}

urlencode() {
    local value="$1"
    jq -nr --arg v "${value}" '$v|@uri'
}

enabled="$(read_config '.watcher_enabled' 'false')"
if [[ "${enabled}" != "true" ]]; then
    exit 0
fi

watcher_url="$(read_config '.watcher_url' '')"
watcher_token="$(read_config '.watcher_token' '')"
monitor_id="$(read_config '.watcher_monitor_id' 'groupalarm-monitor')"

if [[ -z "${watcher_url}" || -z "${watcher_token}" ]]; then
    log "Watcher-Heartbeat nicht gesendet: watcher_url oder watcher_token fehlt."
    exit 0
fi

separator='?'
if [[ "${watcher_url}" == *'?'* ]]; then
    separator='&'
fi

heartbeat_url="${watcher_url}${separator}api=heartbeat&monitor_id=$(urlencode "${monitor_id}")&token=$(urlencode "${watcher_token}")&state=alive&version=${VERSION}"

if curl --fail --silent --show-error --max-time 15 "${heartbeat_url}" >/dev/null 2>&1; then
    log "Heartbeat erfolgreich gesendet an ${watcher_url}"
else
    log "Heartbeat fehlgeschlagen an ${watcher_url}"
    exit 1
fi
