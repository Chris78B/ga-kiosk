#!/bin/bash
#
# GroupAlarm Monitor - apply auto-update schedule v5.6
# Regenerates the systemd timer schedule from config.json and enables/disables
# the weekly auto-update timer accordingly.
#
# Invoked as root (via sudoers) by the web interface after a config change.

set -euo pipefail

CONFIG_FILE="/home/groupalarm/.groupalarm-monitor/config.json"
TIMER_UNIT="groupalarm-auto-update.timer"
DROPIN_DIR="/etc/systemd/system/${TIMER_UNIT}.d"
DROPIN_FILE="${DROPIN_DIR}/schedule.conf"

VALID_DAYS="Mon Tue Wed Thu Fri Sat Sun"

read_config() {
    local key="$1" default_value="$2" value
    if [ ! -f "${CONFIG_FILE}" ] || ! command -v jq >/dev/null 2>&1; then
        printf '%s' "${default_value}"
        return 0
    fi
    value="$(jq -r "${key} // empty" "${CONFIG_FILE}" 2>/dev/null || true)"
    if [ -z "${value}" ] || [ "${value}" = "null" ]; then
        printf '%s' "${default_value}"
    else
        printf '%s' "${value}"
    fi
}

day="$(read_config '.auto_update_day' 'Sun')"
time="$(read_config '.auto_update_time' '04:00')"
enabled="$(read_config '.auto_update_enabled' 'false')"

# Validate the weekday against the allow-list; fall back to Sun on anything odd.
case " ${VALID_DAYS} " in
    *" ${day} "*) : ;;
    *) day="Sun" ;;
esac

# Validate HH:MM; fall back to 04:00.
if ! printf '%s' "${time}" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
    time="04:00"
fi

mkdir -p "${DROPIN_DIR}"
# The empty first OnCalendar= resets the unit's list before we set the new value.
cat > "${DROPIN_FILE}" <<EOF
[Timer]
OnCalendar=
OnCalendar=${day} *-*-* ${time}:00
EOF

systemctl daemon-reload

if [ "${enabled}" = "true" ]; then
    systemctl enable --now "${TIMER_UNIT}" >/dev/null 2>&1 || true
    echo "Auto-Update aktiv: ${day} ${time}"
else
    systemctl disable --now "${TIMER_UNIT}" >/dev/null 2>&1 || true
    echo "Auto-Update deaktiviert (Zeitplan gespeichert: ${day} ${time})"
fi
