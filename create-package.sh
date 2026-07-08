#!/bin/bash
#
# Creates the ga-kiosk runtime package archive (version-agnostic filename,
# so it can always be fetched as a GitHub "latest release" asset).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_NAME="ga-kiosk.tar.gz"
ARCHIVE="${SCRIPT_DIR}/${ARCHIVE_NAME}"
CHECKSUM="${ARCHIVE}.sha256"

PACKAGE_ITEMS=(
    "groupalarm_webinterface.py"
    "groupalarm-kiosk.sh"
    "groupalarm-auto-update.sh"
    "groupalarm-apply-update-schedule.sh"
    "groupalarm-wifi-setup.sh"
    "groupalarm-network-watchdog.sh"
    "groupalarm-heartbeat.sh"
    "openbox-autostart"
    "10-groupalarm-powersave.conf"
    "groupalarm-webinterface.service"
    "groupalarm-monitor.service"
    "groupalarm-network-watchdog.service"
    "groupalarm-heartbeat.service"
    "groupalarm-heartbeat.timer"
    "groupalarm-auto-update.service"
    "groupalarm-auto-update.timer"
    "systemd_services.conf"
    "templates/dashboard.html"
    "templates/login.html"
)

cd "${SCRIPT_DIR}"

for item in "${PACKAGE_ITEMS[@]}"; do
    if [[ ! -e "${item}" ]]; then
        echo "Paketdatei fehlt: ${item}" >&2
        exit 1
    fi
done

rm -f "${ARCHIVE}" "${CHECKSUM}"
tar -czf "${ARCHIVE_NAME}" "${PACKAGE_ITEMS[@]}"
sha256sum "${ARCHIVE_NAME}" > "${CHECKSUM}"

echo "Paket erstellt: ${ARCHIVE}"
echo "Checksumme erstellt: ${CHECKSUM}"
