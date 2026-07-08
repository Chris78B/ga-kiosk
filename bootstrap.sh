#!/bin/bash
#
# ga-kiosk bootstrap / update entry point.
#
# Fetches the latest ga-kiosk release (installer + payload archive + checksum)
# from GitHub and runs the installer. Safe to re-run any time: groupalarm-install.sh
# is idempotent, it updates an existing installation in place and keeps the
# existing config.json.
#
# This script itself is meant to be fetched from the stable "main" branch URL
# (it changes rarely and is short enough to read before running); the actual
# payload always comes from the "latest" GitHub Release, so this file does not
# need to change between ga-kiosk versions.
#
# Usage (run as root), review-first:
#   curl -fsSL -O https://raw.githubusercontent.com/Chris78B/ga-kiosk/main/bootstrap.sh
#   sudo bash bootstrap.sh
#
# Usage, one-liner:
#   curl -fsSL https://raw.githubusercontent.com/Chris78B/ga-kiosk/main/bootstrap.sh | sudo bash

set -euo pipefail

REPO="Chris78B/ga-kiosk"
RELEASE_BASE="https://github.com/${REPO}/releases/latest/download"
INSTALLER="groupalarm-install.sh"
ARCHIVE="ga-kiosk.tar.gz"
CHECKSUM_FILE="${ARCHIVE}.sha256"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Dieses Skript muss als root laufen (sudo)." >&2
    exit 1
fi

for cmd in curl sha256sum tar; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Benoetigtes Werkzeug fehlt: ${cmd}" >&2
        exit 1
    fi
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
cd "${WORKDIR}"

echo "Lade aktuelles ga-kiosk-Release von GitHub..."
curl -fsSL -O "${RELEASE_BASE}/{${INSTALLER},${ARCHIVE},${CHECKSUM_FILE}}"

echo "Pruefe Dateisicherheit (SHA256)..."
if ! sha256sum -c "${CHECKSUM_FILE}"; then
    echo "FEHLER: SHA256-Pruefsumme stimmt nicht ueberein. Abbruch." >&2
    exit 1
fi

chmod +x "${INSTALLER}"
echo "Starte Installation/Update..."
"./${INSTALLER}"
