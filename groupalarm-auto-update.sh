#!/bin/bash
#
# GroupAlarm Monitor Auto-Update v5.6
# - triggered by groupalarm-auto-update.timer (weekly, Persistent catch-up)
# - the timer owns the schedule; this script no longer gates on the hour
# - pauses the kiosk via groupalarm-kiosk.sh instead of systemd browser control

set -euo pipefail

CONFIG_FILE="/home/groupalarm/.groupalarm-monitor/config.json"
CONFIG_DIR="/home/groupalarm/.groupalarm-monitor"
LOG_FILE="${CONFIG_DIR}/groupalarm-auto-update.log"
LOCK_FILE="/tmp/groupalarm-update.lock"
KIOSK_SCRIPT="/usr/local/bin/groupalarm-kiosk.sh"

log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "${CONFIG_DIR}"
    echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

read_config() {
    local key="$1"
    local default_value="$2"

    if [ ! -f "${CONFIG_FILE}" ] || ! command -v jq >/dev/null 2>&1; then
        printf '%s' "${default_value}"
        return 0
    fi

    local value
    value="$(jq -r "${key} // empty" "${CONFIG_FILE}" 2>/dev/null || true)"
    if [ -z "${value}" ] || [ "${value}" = "null" ]; then
        printf '%s' "${default_value}"
    else
        printf '%s' "${value}"
    fi
}

send_notification() {
    local email="$1"
    local subject="$2"
    local message="$3"

    if [ -z "${email}" ]; then
        return 0
    fi

    if command -v mail >/dev/null 2>&1; then
        if echo "${message}" | mail -s "${subject}" "${email}" 2>/dev/null; then
            log "Benachrichtigung gesendet an ${email}"
        else
            log "Benachrichtigung konnte nicht gesendet werden. Lokale Mail-Konfiguration pruefen."
        fi
    else
        log "Benachrichtigung nicht gesendet: mail-Befehl nicht installiert."
    fi
}

if [ -f "${LOCK_FILE}" ]; then
    log "Update laeuft bereits, Abbruch."
    exit 0
fi

touch "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

if [ ! -f "${CONFIG_FILE}" ]; then
    log "Config-Datei nicht gefunden: ${CONFIG_FILE}"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    log "jq ist nicht installiert. Der 5.6-Installer muss jq bereitstellen."
    exit 1
fi

if ! jq empty "${CONFIG_FILE}" >/dev/null 2>&1; then
    log "Config-Datei ist kein gueltiges JSON."
    exit 1
fi

AUTO_UPDATE_ENABLED="$(read_config '.auto_update_enabled' 'false')"
if [ "${AUTO_UPDATE_ENABLED}" != "true" ]; then
    log "Auto-Update ist deaktiviert."
    exit 0
fi

# The weekly systemd timer decides WHEN to run. This script just executes the
# update whenever it is invoked (and honours the enabled flag above).
NOTIFY_EMAIL="$(read_config '.notify_email' '')"
AUTO_REBOOT="$(read_config '.auto_update_reboot' 'false')"

log "Auto-Update gestartet."

if [ -x "${KIOSK_SCRIPT}" ]; then
    "${KIOSK_SCRIPT}" stop >/dev/null 2>&1 || true
    log "Kiosk ueber ${KIOSK_SCRIPT} gestoppt."
else
    log "Kiosk-Skript nicht gefunden, Chromium wird nur indirekt beeinflusst."
fi

UPDATE_START="$(date +%s)"

if sudo apt-get update -qq >> "${LOG_FILE}" 2>&1; then
    log "apt-get update erfolgreich"
else
    log "apt-get update hatte Fehler"
fi

if sudo apt-get upgrade -y -qq >> "${LOG_FILE}" 2>&1; then
    log "apt-get upgrade erfolgreich"
else
    log "apt-get upgrade hatte Fehler"
fi

UPDATE_END="$(date +%s)"
UPDATE_DURATION="$((UPDATE_END - UPDATE_START))"
log "System-Update abgeschlossen (${UPDATE_DURATION} Sekunden)."

sudo systemctl restart groupalarm-webinterface.service >/dev/null 2>&1 || true
log "Webinterface neu gestartet."

if [ -x "${KIOSK_SCRIPT}" ]; then
    "${KIOSK_SCRIPT}" start >/dev/null 2>&1 || true
    log "Kiosk ueber ${KIOSK_SCRIPT} wieder gestartet."
fi

if [ "${AUTO_REBOOT}" = "true" ]; then
    send_notification "${NOTIFY_EMAIL}" "GroupAlarm Auto-Update" "System-Update erfolgreich. Neustart in Kuerze."
    sudo shutdown -r +1 "GroupAlarm Auto-Update abgeschlossen"
    log "Reboot in 1 Minute geplant."
else
    send_notification "${NOTIFY_EMAIL}" "GroupAlarm Auto-Update" "System-Update erfolgreich abgeschlossen."
    log "Auto-Reboot deaktiviert."
fi

log "Auto-Update erfolgreich beendet."
