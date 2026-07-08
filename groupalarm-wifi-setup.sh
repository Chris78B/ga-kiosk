#!/bin/bash
#
# GroupAlarm Monitor - WLAN provisioning v5.6
#
# Stores WLAN credentials SYSTEM-WIDE and login-independent so the kiosk
# reconnects at boot without anyone typing a password.
#
# Root cause this fixes: when the WLAN password lives in a per-user
# NetworkManager connection, it is sealed in the GNOME keyring. With LightDM
# autologin the keyring is never unlocked, so the PSK is unreachable and
# NetworkManager falls back to prompting for the password interactively.
#
# Here the PSK is written with psk-flags=0 (stored in the system connection
# file, NOT the keyring) and empty permissions (available to all users /
# before any login). Power saving is disabled to avoid the WLAN chip dropping.
#
# Usage:
#   sudo groupalarm-wifi-setup.sh <SSID> <PSK> [interface]
#
# Runs as root.

set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Dieses Skript muss als root laufen (sudo)." >&2
    exit 1
fi

SSID="${1:-}"
PSK="${2:-}"
IFACE="${3:-}"
CON_NAME="groupalarm-wifi"

if [ -z "${SSID}" ] || [ -z "${PSK}" ]; then
    echo "Verwendung: $0 <SSID> <PSK> [interface]" >&2
    exit 2
fi

if [ "${#PSK}" -lt 8 ]; then
    echo "WPA-PSK muss mindestens 8 Zeichen haben." >&2
    exit 2
fi

# --- Path 1: NetworkManager (Ubuntu Desktop default) --------------------------
if command -v nmcli >/dev/null 2>&1; then
    echo "NetworkManager erkannt - lege systemweite Verbindung '${CON_NAME}' an."

    # Remove any earlier version of our connection so we start clean.
    nmcli connection delete "${CON_NAME}" >/dev/null 2>&1 || true

    nm_args=(
        connection.id "${CON_NAME}"
        connection.autoconnect yes
        connection.autoconnect-priority 100
        connection.autoconnect-retries 0
        connection.permissions ""
        802-11-wireless.ssid "${SSID}"
        802-11-wireless.powersave 2
        802-11-wireless-security.key-mgmt wpa-psk
        802-11-wireless-security.psk "${PSK}"
        802-11-wireless-security.psk-flags 0
    )
    if [ -n "${IFACE}" ]; then
        nm_args+=(connection.interface-name "${IFACE}")
    fi

    nmcli connection add type wifi "${nm_args[@]}"

    # Make sure the stored file is root-only.
    chmod 600 "/etc/NetworkManager/system-connections/${CON_NAME}.nmconnection" 2>/dev/null || true
    nmcli connection reload
    nmcli connection up "${CON_NAME}" >/dev/null 2>&1 || \
        echo "Hinweis: Verbindung angelegt, konnte aber gerade nicht aktiviert werden (Signal/SSID pruefen)."

    echo "WLAN '${SSID}' systemweit hinterlegt (keyring-unabhaengig)."
    exit 0
fi

# --- Path 2: ifupdown / wpa_supplicant fallback -------------------------------
echo "NetworkManager nicht gefunden - schreibe wpa_supplicant-Fallback."
IFACE="${IFACE:-wlan0}"
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf"

mkdir -p /etc/wpa_supplicant
{
    echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev"
    echo "update_config=1"
    echo "country=DE"
    wpa_passphrase "${SSID}" "${PSK}"
} > "${WPA_CONF}"
chmod 600 "${WPA_CONF}"

systemctl enable "wpa_supplicant@${IFACE}.service" >/dev/null 2>&1 || true
systemctl restart "wpa_supplicant@${IFACE}.service" >/dev/null 2>&1 || true

echo "WLAN '${SSID}' in ${WPA_CONF} hinterlegt."
echo "Bitte sicherstellen, dass ${IFACE} in /etc/network/interfaces (oder netplan) als auto/dhcp gefuehrt wird."
