#!/bin/bash
#
# GroupAlarm Monitor Installer v5.6
# Installs the consolidated 5.6 layout:
# - Openbox owns Chromium kiosk startup
# - systemd owns background services only
# - Weekly auto-update via systemd timer (not cron)
# - System-wide, keyring-independent WLAN + NetworkManager-aware watchdog
# - Web interface, kiosk script and templates are deployed from the 5.6 source set

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ARCHIVE="${SCRIPT_DIR}/ga-kiosk.tar.gz"
PAYLOAD_DIR="${SCRIPT_DIR}"
PAYLOAD_TMP_DIR=""
SERVICE_USER="groupalarm"
SERVICE_GROUP="groupalarm"
USER_HOME="/home/${SERVICE_USER}"
INSTALL_BIN_DIR="/usr/local/bin"
INSTALL_TEMPLATE_DIR="${INSTALL_BIN_DIR}/templates"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_DIR="${USER_HOME}/.groupalarm-monitor"
OPENBOX_DIR="${USER_HOME}/.config/openbox"
LIGHTDM_CONF="/etc/lightdm/lightdm.conf.d/99-groupalarm.conf"
SUDOERS_FILE="/etc/sudoers.d/groupalarm"
NM_CONF_DIR="/etc/NetworkManager/conf.d"
# Optional non-interactive WLAN provisioning: export these before running.
WIFI_SSID="${GROUPALARM_WIFI_SSID:-}"
WIFI_PSK="${GROUPALARM_WIFI_PSK:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup_payload() {
    if [[ -n "${PAYLOAD_TMP_DIR}" && -d "${PAYLOAD_TMP_DIR}" ]]; then
        rm -rf "${PAYLOAD_TMP_DIR}"
    fi
}

trap cleanup_payload EXIT

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        log_error "Dieses Skript muss mit root oder sudo ausgefuehrt werden."
        exit 1
    fi
}

prepare_payload() {
    if [[ -f "${PACKAGE_ARCHIVE}" ]]; then
        log_info "Entpacke Paketarchiv ${PACKAGE_ARCHIVE}..."
        PAYLOAD_TMP_DIR="$(mktemp -d)"
        tar -xzf "${PACKAGE_ARCHIVE}" -C "${PAYLOAD_TMP_DIR}"
        PAYLOAD_DIR="${PAYLOAD_TMP_DIR}"
        log_success "Paketarchiv entpackt"
    else
        log_warn "Kein Paketarchiv gefunden, verwende Einzeldateien aus ${SCRIPT_DIR}"
    fi

    local required_files=(
        "groupalarm_webinterface.py"
        "groupalarm-kiosk.sh"
        "groupalarm-auto-update.sh"
        "groupalarm-apply-update-schedule.sh"
        "groupalarm-wifi-setup.sh"
        "groupalarm-network-watchdog.sh"
        "groupalarm-heartbeat.sh"
        "openbox-autostart"
        "10-groupalarm-powersave.conf"
        "templates/dashboard.html"
        "templates/login.html"
        "groupalarm-webinterface.service"
        "groupalarm-monitor.service"
        "groupalarm-network-watchdog.service"
        "groupalarm-heartbeat.service"
        "groupalarm-heartbeat.timer"
        "groupalarm-auto-update.service"
        "groupalarm-auto-update.timer"
    )

    local file
    for file in "${required_files[@]}"; do
        if [[ ! -f "${PAYLOAD_DIR}/${file}" ]]; then
            log_error "Paketdatei fehlt: ${file}"
            exit 1
        fi
    done
}

apt_install() {
    local package="$1"
    if dpkg -s "${package}" >/dev/null 2>&1; then
        log_success "${package} bereits vorhanden"
        return
    fi

    log_info "Installiere ${package}..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${package}" >/dev/null
    log_success "${package} installiert"
}

ensure_user() {
    if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
        log_success "Benutzer ${SERVICE_USER} bereits vorhanden"
    else
        useradd -m -s /bin/bash -G sudo,video,audio,input "${SERVICE_USER}"
        log_success "Benutzer ${SERVICE_USER} erstellt"
    fi

    usermod -aG video,audio,input "${SERVICE_USER}" >/dev/null 2>&1 || true
}

install_packages() {
    log_info "Installiere Systemabhaengigkeiten..."
    apt-get update >/dev/null

    local packages=(
        python3
        python3-flask
        python3-werkzeug
        chromium-browser
        openbox
        lightdm
        cron
        jq
        curl
        wmctrl
        unclutter
        xbindkeys
        x11-xserver-utils
        wireless-tools
        wpasupplicant
        isc-dhcp-client
        network-manager
        iw
    )

    local package
    for package in "${packages[@]}"; do
        apt_install "${package}"
    done
}

ensure_directories() {
    mkdir -p "${INSTALL_BIN_DIR}" "${INSTALL_TEMPLATE_DIR}" "${CONFIG_DIR}" "${OPENBOX_DIR}" /etc/lightdm/lightdm.conf.d
    touch \
        "${CONFIG_DIR}/monitor.log" \
        "${CONFIG_DIR}/groupalarm-auto-update.log" \
        "${CONFIG_DIR}/groupalarm-auto-update-cron.log" \
        "${CONFIG_DIR}/groupalarm-network-watchdog.log" \
        "${CONFIG_DIR}/groupalarm-heartbeat.log" \
        "${CONFIG_DIR}/openbox-autostart.log"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_DIR}" "${OPENBOX_DIR}"
    chmod 700 "${CONFIG_DIR}"
    chmod 600 "${CONFIG_DIR}"/*.log
    log_success "Verzeichnisse vorbereitet"
}

install_runtime_files() {
    log_info "Installiere 5.6-Laufzeitdateien..."

    install -m 0755 "${PAYLOAD_DIR}/groupalarm_webinterface.py" "${INSTALL_BIN_DIR}/groupalarm-webinterface.py"
    install -m 0755 "${PAYLOAD_DIR}/groupalarm-kiosk.sh" "${INSTALL_BIN_DIR}/groupalarm-kiosk.sh"
    install -m 0755 "${PAYLOAD_DIR}/groupalarm-auto-update.sh" "${INSTALL_BIN_DIR}/groupalarm-auto-update.sh"
    install -m 0755 "${PAYLOAD_DIR}/groupalarm-network-watchdog.sh" "${INSTALL_BIN_DIR}/groupalarm-network-watchdog.sh"
    install -m 0755 "${PAYLOAD_DIR}/groupalarm-heartbeat.sh" "${INSTALL_BIN_DIR}/groupalarm-heartbeat.sh"
    # Privileged helpers: owned by root, invoked by the web interface via sudoers.
    install -m 0755 -o root -g root "${PAYLOAD_DIR}/groupalarm-apply-update-schedule.sh" "${INSTALL_BIN_DIR}/groupalarm-apply-update-schedule.sh"
    install -m 0755 -o root -g root "${PAYLOAD_DIR}/groupalarm-wifi-setup.sh" "${INSTALL_BIN_DIR}/groupalarm-wifi-setup.sh"
    install -m 0755 "${PAYLOAD_DIR}/openbox-autostart" "${OPENBOX_DIR}/autostart"
    install -m 0644 "${PAYLOAD_DIR}/templates/dashboard.html" "${INSTALL_TEMPLATE_DIR}/dashboard.html"
    install -m 0644 "${PAYLOAD_DIR}/templates/login.html" "${INSTALL_TEMPLATE_DIR}/login.html"
    install -m 0644 "${PAYLOAD_DIR}/groupalarm-webinterface.service" "${SYSTEMD_DIR}/groupalarm-webinterface.service"
    install -m 0644 "${PAYLOAD_DIR}/groupalarm-monitor.service" "${SYSTEMD_DIR}/groupalarm-monitor.service"
    install -m 0644 "${PAYLOAD_DIR}/groupalarm-network-watchdog.service" "${SYSTEMD_DIR}/groupalarm-network-watchdog.service"
    install -m 0644 "${PAYLOAD_DIR}/groupalarm-heartbeat.service" "${SYSTEMD_DIR}/groupalarm-heartbeat.service"
    install -m 0644 "${PAYLOAD_DIR}/groupalarm-heartbeat.timer" "${SYSTEMD_DIR}/groupalarm-heartbeat.timer"
    install -m 0644 "${PAYLOAD_DIR}/groupalarm-auto-update.service" "${SYSTEMD_DIR}/groupalarm-auto-update.service"
    install -m 0644 "${PAYLOAD_DIR}/groupalarm-auto-update.timer" "${SYSTEMD_DIR}/groupalarm-auto-update.timer"
    # WLAN power-save drop-in (NetworkManager).
    mkdir -p "${NM_CONF_DIR}"
    install -m 0644 -o root -g root "${PAYLOAD_DIR}/10-groupalarm-powersave.conf" "${NM_CONF_DIR}/10-groupalarm-powersave.conf"

    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${INSTALL_BIN_DIR}/groupalarm-webinterface.py"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${INSTALL_BIN_DIR}/groupalarm-kiosk.sh"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${INSTALL_BIN_DIR}/groupalarm-auto-update.sh"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${INSTALL_BIN_DIR}/groupalarm-network-watchdog.sh"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${INSTALL_BIN_DIR}/groupalarm-heartbeat.sh"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${INSTALL_TEMPLATE_DIR}/dashboard.html" "${INSTALL_TEMPLATE_DIR}/login.html"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${OPENBOX_DIR}/autostart"

    log_success "Laufzeitdateien installiert"
}

write_initial_config() {
    if [[ -f "${CONFIG_DIR}/config.json" ]]; then
        log_success "Vorhandene Konfiguration bleibt erhalten"
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_DIR}/config.json"
        chmod 600 "${CONFIG_DIR}/config.json"
        return
    fi

    cat > "${CONFIG_DIR}/config.json" <<'EOF'
{
  "groupalarm_url": "https://app.groupalarm.com/de/monitor",
  "groupalarm_token": "",
  "dark_theme": false,
  "admin_password_hash": "",
  "auto_update_enabled": false,
  "auto_update_day": "Sun",
  "auto_update_time": "04:00",
  "auto_update_reboot": false,
  "notify_email": "",
  "watcher_enabled": false,
  "watcher_url": "",
  "watcher_token": "",
  "watcher_monitor_id": "groupalarm-monitor",
  "session_secret": ""
}
EOF

    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_DIR}/config.json"
    chmod 600 "${CONFIG_DIR}/config.json"
    log_success "Initiale Konfiguration angelegt"
}

configure_lightdm() {
    cat > "${LIGHTDM_CONF}" <<EOF
[Seat:*]
autologin-user=${SERVICE_USER}
autologin-user-timeout=0
user-session=openbox
autologin-session=openbox
EOF
    chmod 644 "${LIGHTDM_CONF}"

    # user-session is only the greeter's default; LightDM autologin actually
    # honours the session stored in ~/.dmrc from the last greeter selection.
    # If someone ever picked "Ubuntu" (GNOME) at the greeter once, autologin
    # keeps loading GNOME forever after - and the kiosk (openbox autostart)
    # never runs, even though openbox-autostart.log looks untouched and
    # everything else (chromium, network, sudoers) is fine. Force it here too
    # so a stray greeter selection can't silently break the kiosk.
    if [[ -f "${USER_HOME}/.dmrc" ]]; then
        sed -i 's/^Session=.*/Session=openbox/' "${USER_HOME}/.dmrc"
    else
        printf '[Desktop]\nSession=openbox\n' > "${USER_HOME}/.dmrc"
    fi
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${USER_HOME}/.dmrc"

    log_success "LightDM Auto-Login konfiguriert (autologin-session=openbox erzwungen)"
}

configure_sudoers() {
    cat > "${SUDOERS_FILE}" <<'EOF'
# GroupAlarm Monitor v5.6
groupalarm ALL=(root) NOPASSWD: /usr/bin/apt-get update
groupalarm ALL=(root) NOPASSWD: /usr/bin/apt-get upgrade -y
groupalarm ALL=(root) NOPASSWD: /usr/bin/systemctl restart groupalarm-webinterface.service
# Auto-update schedule + WLAN provisioning helpers (called by the web interface)
groupalarm ALL=(root) NOPASSWD: /usr/local/bin/groupalarm-apply-update-schedule.sh
groupalarm ALL=(root) NOPASSWD: /usr/local/bin/groupalarm-wifi-setup.sh *
# NetworkManager-based WLAN recovery (watchdog)
groupalarm ALL=(root) NOPASSWD: /usr/bin/nmcli *
groupalarm ALL=(root) NOPASSWD: /usr/sbin/iw *
groupalarm ALL=(root) NOPASSWD: /sbin/iw *
# ifupdown/wpa_supplicant fallback recovery
groupalarm ALL=(root) NOPASSWD: /usr/bin/systemctl restart networking
groupalarm ALL=(root) NOPASSWD: /usr/bin/systemctl restart wpa_supplicant
groupalarm ALL=(root) NOPASSWD: /bin/systemctl restart networking
groupalarm ALL=(root) NOPASSWD: /bin/systemctl restart wpa_supplicant
groupalarm ALL=(root) NOPASSWD: /usr/bin/systemctl restart wpa_supplicant@*
groupalarm ALL=(root) NOPASSWD: /bin/systemctl restart wpa_supplicant@*
groupalarm ALL=(root) NOPASSWD: /sbin/dhclient -r *
groupalarm ALL=(root) NOPASSWD: /usr/sbin/dhclient -r *
groupalarm ALL=(root) NOPASSWD: /sbin/dhclient *
groupalarm ALL=(root) NOPASSWD: /usr/sbin/dhclient *
groupalarm ALL=(root) NOPASSWD: /sbin/ip link set * down
groupalarm ALL=(root) NOPASSWD: /sbin/ip link set * up
groupalarm ALL=(root) NOPASSWD: /usr/sbin/ip link set * down
groupalarm ALL=(root) NOPASSWD: /usr/sbin/ip link set * up
groupalarm ALL=(root) NOPASSWD: /sbin/shutdown -r +1 *
groupalarm ALL=(root) NOPASSWD: /sbin/shutdown -h +1 *
groupalarm ALL=(root) NOPASSWD: /sbin/shutdown -c
groupalarm ALL=(root) NOPASSWD: /usr/sbin/shutdown -r +1 *
groupalarm ALL=(root) NOPASSWD: /usr/sbin/shutdown -h +1 *
groupalarm ALL=(root) NOPASSWD: /usr/sbin/shutdown -c
EOF
    chmod 440 "${SUDOERS_FILE}"
    visudo -c -f "${SUDOERS_FILE}" >/dev/null
    log_success "Sudoers-Regeln aktualisiert"
}

provision_wifi() {
    if [[ -z "${WIFI_SSID}" || -z "${WIFI_PSK}" ]]; then
        log_info "Keine WLAN-Zugangsdaten uebergeben (GROUPALARM_WIFI_SSID/_PSK). WLAN-Provisionierung uebersprungen."
        return
    fi
    log_info "Richte systemweite WLAN-Verbindung ein..."
    if "${INSTALL_BIN_DIR}/groupalarm-wifi-setup.sh" "${WIFI_SSID}" "${WIFI_PSK}"; then
        log_success "WLAN systemweit hinterlegt (keyring-unabhaengig)"
    else
        log_warn "WLAN-Provisionierung nicht erfolgreich. Bitte manuell mit groupalarm-wifi-setup.sh nachziehen."
    fi
}

configure_systemd() {
    systemctl daemon-reload
    # NetworkManager must run so the WLAN stays up before/without any user login.
    systemctl enable NetworkManager >/dev/null 2>&1 || true
    systemctl start NetworkManager >/dev/null 2>&1 || true
    systemctl reload NetworkManager >/dev/null 2>&1 || true
    systemctl enable groupalarm-webinterface.service >/dev/null
    systemctl enable groupalarm-network-watchdog.service >/dev/null 2>&1 || true
    systemctl enable groupalarm-heartbeat.timer >/dev/null 2>&1 || true
    systemctl enable groupalarm-auto-update.timer >/dev/null 2>&1 || true
    systemctl disable groupalarm-monitor.service >/dev/null 2>&1 || true
    systemctl stop groupalarm-monitor.service >/dev/null 2>&1 || true
    systemctl restart groupalarm-webinterface.service
    systemctl restart groupalarm-network-watchdog.service >/dev/null 2>&1 || true
    systemctl restart groupalarm-heartbeat.timer >/dev/null 2>&1 || true
    # Render the weekly update schedule from config.json and (de)activate the timer.
    "${INSTALL_BIN_DIR}/groupalarm-apply-update-schedule.sh" >/dev/null 2>&1 || true
    log_success "Systemd fuer 5.6 konfiguriert"
}

print_summary() {
    local host_ip
    host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

    echo
    echo -e "${GREEN}GroupAlarm Monitor 5.6 wurde installiert.${NC}"
    echo
    echo "Webinterface:"
    echo "  http://${host_ip:-<ip>}:8080"
    echo
    echo "Wichtige Punkte:"
    echo "  - Chromium wird nicht ueber groupalarm-monitor.service gefuehrt."
    echo "  - Openbox startet den Kiosk ueber /usr/local/bin/groupalarm-kiosk.sh."
    echo "  - Woechentliches Update laeuft ueber groupalarm-auto-update.timer (systemd)."
    echo "  - WLAN systemweit ablegen (einmalig, keyring-unabhaengig):"
    echo "      sudo /usr/local/bin/groupalarm-wifi-setup.sh '<SSID>' '<WLAN-Passwort>'"
    echo "  - Der erste Login ins Webinterface nutzt das Initialpasswort 'groupalarm'."
    echo
    echo "Empfohlen danach:"
    echo "  1. WLAN mit groupalarm-wifi-setup.sh hinterlegen (falls nicht via ENV geschehen)"
    echo "  2. Webinterface aufrufen und Passwort aendern"
    echo "  3. Auto-Update im Dashboard aktivieren und Tag/Zeit setzen"
    echo "  4. Reboot des Gesamtsystems pruefen (WLAN muss ohne Login verbinden)"
}

main() {
    require_root
    log_info "Starte GroupAlarm Monitor Installer v5.6..."
    ensure_user
    install_packages
    prepare_payload
    ensure_directories
    install_runtime_files
    write_initial_config
    configure_lightdm
    configure_sudoers
    configure_systemd
    provision_wifi
    print_summary
}

main "$@"
