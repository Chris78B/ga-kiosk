#!/bin/bash
#
# GroupAlarm Network Watchdog v5.6
# - monitors connectivity
# - detects the active network stack (NetworkManager vs. ifupdown/wpa_supplicant)
#   and heals with matching commands instead of blindly restarting networking
# - auto-detects the wireless interface (wlan0 / wlpXsY / ...)
# - keeps WLAN power saving disabled (common cause of random drops)

set -euo pipefail

CONFIG_DIR="/home/groupalarm/.groupalarm-monitor"
LOGFILE="${CONFIG_DIR}/groupalarm-network-watchdog.log"
CONFIGFILE="${CONFIG_DIR}/config.json"
WIFI_CON_NAME="groupalarm-wifi"
CHECK_INTERVAL=30
MAX_FAILURES=3
FAILURE_COUNT=0
ALERT_SENT=0
RECOVERY_ATTEMPT=0

log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "${CONFIG_DIR}"
    echo "[${timestamp}] [WATCHDOG] $*" | tee -a "${LOGFILE}"
}

read_config() {
    local key="$1"
    local default_value="$2"

    if [ ! -f "${CONFIGFILE}" ] || ! command -v jq >/dev/null 2>&1; then
        printf '%s' "${default_value}"
        return 0
    fi

    local value
    value="$(jq -r "${key} // empty" "${CONFIGFILE}" 2>/dev/null || true)"
    if [ -z "${value}" ] || [ "${value}" = "null" ]; then
        printf '%s' "${default_value}"
    else
        printf '%s' "${value}"
    fi
}

# Determine the wireless interface. An explicit override always wins, otherwise
# probe the actual system so we do not hard-code wlan0.
detect_wifi_interface() {
    if [ -n "${GROUPALARM_NETWORK_INTERFACE:-}" ] && [ "${GROUPALARM_NETWORK_INTERFACE}" != "auto" ]; then
        printf '%s' "${GROUPALARM_NETWORK_INTERFACE}"
        return 0
    fi

    local iface=""
    if command -v nmcli >/dev/null 2>&1; then
        iface="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
    fi
    if [ -z "${iface}" ]; then
        local dev
        for dev in /sys/class/net/*; do
            if [ -d "${dev}/wireless" ] || [ -e "${dev}/phy80211" ]; then
                iface="$(basename "${dev}")"
                break
            fi
        done
    fi
    if [ -z "${iface}" ] && command -v iw >/dev/null 2>&1; then
        iface="$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')"
    fi

    printf '%s' "${iface:-wlan0}"
}

# True when NetworkManager is the managing stack.
using_networkmanager() {
    command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null
}

disable_powersave() {
    local iface="$1"
    if command -v iw >/dev/null 2>&1; then
        sudo iw dev "${iface}" set power_save off >/dev/null 2>&1 || true
    fi
}

check_connectivity() {
    local watcher_url
    watcher_url="$(read_config '.watcher_url' '')"

    if [ -n "${watcher_url}" ] && command -v curl >/dev/null 2>&1; then
        if curl --fail --silent --show-error --head --max-time 10 "${watcher_url}" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl --fail --silent --show-error --head --max-time 10 https://app.groupalarm.com/ >/dev/null 2>&1; then
            return 0
        elif curl --fail --silent --show-error --head --max-time 10 https://www.google.com/generate_204 >/dev/null 2>&1; then
            return 0
        fi
    fi

    if timeout 3 ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        return 0
    elif timeout 3 ping -c 1 1.1.1.1 >/dev/null 2>&1; then
        return 0
    elif timeout 3 ping -c 1 208.67.222.222 >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

get_wifi_signal() {
    if command -v iw >/dev/null 2>&1; then
        iw dev "${NETWORK_INTERFACE}" link 2>/dev/null | awk '/signal:/{print $2, $3; exit}' || echo "unknown"
    elif command -v iwconfig >/dev/null 2>&1; then
        iwconfig "${NETWORK_INTERFACE}" 2>/dev/null | grep "Signal level" | head -1 | awk -F'=' '{print $NF}' || echo "unknown"
    else
        echo "unknown"
    fi
}

recover_wifi_networkmanager() {
    log "Recovery ueber NetworkManager (Interface ${NETWORK_INTERFACE})."
    sudo nmcli radio wifi on >/dev/null 2>&1 || true
    sleep 1
    disable_powersave "${NETWORK_INTERFACE}"

    # Prefer bringing up our known system connection; fall back to a device reconnect.
    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "${WIFI_CON_NAME}"; then
        sudo nmcli connection up "${WIFI_CON_NAME}" >/dev/null 2>&1 || true
    fi
    sleep 2
    sudo nmcli device reconnect "${NETWORK_INTERFACE}" >/dev/null 2>&1 || \
        sudo nmcli device connect "${NETWORK_INTERFACE}" >/dev/null 2>&1 || true
    sleep 3
}

recover_wifi_ifupdown() {
    log "Recovery ueber ifupdown/wpa_supplicant (Interface ${NETWORK_INTERFACE})."
    sudo systemctl restart "wpa_supplicant@${NETWORK_INTERFACE}.service" >/dev/null 2>&1 || \
        sudo systemctl restart wpa_supplicant >/dev/null 2>&1 || true
    sleep 2
    sudo dhclient -r "${NETWORK_INTERFACE}" >/dev/null 2>&1 || true
    sleep 1
    sudo dhclient "${NETWORK_INTERFACE}" >/dev/null 2>&1 || true
    sleep 2
    sudo ip link set "${NETWORK_INTERFACE}" down >/dev/null 2>&1 || true
    sleep 1
    sudo ip link set "${NETWORK_INTERFACE}" up >/dev/null 2>&1 || true
    sleep 3
}

recover_wifi() {
    RECOVERY_ATTEMPT=$((RECOVERY_ATTEMPT + 1))
    log "Starte WLAN-Recovery (Versuch ${RECOVERY_ATTEMPT})..."

    # Re-detect in case the interface name changed (e.g. after a driver reload).
    NETWORK_INTERFACE="$(detect_wifi_interface)"

    if using_networkmanager; then
        recover_wifi_networkmanager
    else
        recover_wifi_ifupdown
    fi

    if check_connectivity; then
        log "WLAN-Recovery erfolgreich. Signal: $(get_wifi_signal)"
        FAILURE_COUNT=0
        RECOVERY_ATTEMPT=0
        ALERT_SENT=0
        return 0
    fi

    log "WLAN-Recovery fehlgeschlagen."
    return 1
}

if ! command -v jq >/dev/null 2>&1; then
    log "jq ist nicht installiert. Der 5.6-Installer muss jq bereitstellen."
    exit 1
fi

send_alert() {
    local subject="$1"
    local message="$2"
    local email

    email="$(read_config '.notify_email' '')"
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

NETWORK_INTERFACE="$(detect_wifi_interface)"

log "GroupAlarm Network Watchdog gestartet"
log "Interface: ${NETWORK_INTERFACE}"
if using_networkmanager; then
    log "Netzwerk-Stack: NetworkManager"
else
    log "Netzwerk-Stack: ifupdown/wpa_supplicant"
fi
log "Check-Intervall: ${CHECK_INTERVAL}s"
log "Max-Fehlversuche: ${MAX_FAILURES}"

# Keep power saving off from the start, not only after the first outage.
disable_powersave "${NETWORK_INTERFACE}"

while true; do
    if check_connectivity; then
        if [ "${FAILURE_COUNT}" -gt 0 ]; then
            log "Internet-Verbindung wiederhergestellt nach $((FAILURE_COUNT * CHECK_INTERVAL)) Sekunden."
            FAILURE_COUNT=0
        fi
        ALERT_SENT=0
        sleep "${CHECK_INTERVAL}"
        continue
    fi

    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    SIGNAL="$(get_wifi_signal)"

    if [ "${FAILURE_COUNT}" -eq 1 ]; then
        log "Keine Internet-Verbindung erkannt. Signal: ${SIGNAL}"
    else
        log "Fehler ${FAILURE_COUNT}/${MAX_FAILURES}: Keine Internet-Verbindung. Signal: ${SIGNAL}"
    fi

    if [ "${FAILURE_COUNT}" -ge "${MAX_FAILURES}" ]; then
        if [ "${ALERT_SENT}" -eq 0 ]; then
            send_alert \
                "GroupAlarm Monitor - Netzwerkproblem erkannt" \
                "Keine Internet-Verbindung seit $((FAILURE_COUNT * CHECK_INTERVAL)) Sekunden. Automatische Wiederherstellung wird gestartet."
            ALERT_SENT=1
        fi

        if ! recover_wifi; then
            log "Kritisch: WLAN-Recovery fehlgeschlagen nach ${RECOVERY_ATTEMPT} Versuchen."
            if [ "${RECOVERY_ATTEMPT}" -ge 5 ]; then
                send_alert \
                    "GroupAlarm Monitor - kritischer Netzwerkfehler" \
                    "Automatische WLAN-Wiederherstellung ist fehlgeschlagen. Bitte System und Netzwerk pruefen."
            fi
        fi
    fi

    sleep "${CHECK_INTERVAL}"
done
