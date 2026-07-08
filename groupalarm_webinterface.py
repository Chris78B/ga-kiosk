#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""GroupAlarm Monitor Web Interface v5.6."""

from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
from datetime import datetime, timedelta
from functools import wraps
from pathlib import Path

from flask import Flask, jsonify, redirect, render_template, request, session
from werkzeug.security import check_password_hash, generate_password_hash


CONFIG_DIR = Path.home() / ".groupalarm-monitor"
CONFIG_FILE = CONFIG_DIR / "config.json"
LOG_FILE = CONFIG_DIR / "monitor.log"
KIOSK_SCRIPT_CANDIDATES = [
    Path("/usr/local/bin/groupalarm-kiosk.sh"),
    Path(__file__).resolve().with_name("groupalarm-kiosk.sh"),
]
CRONTAB_CANDIDATES = [
    Path("/usr/bin/crontab"),
    Path("/bin/crontab"),
]
APPLY_SCHEDULE_SCRIPT = Path("/usr/local/bin/groupalarm-apply-update-schedule.sh")
VALID_UPDATE_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

DEFAULT_CONFIG = {
    "groupalarm_url": "https://app.groupalarm.com/de/monitor",
    "groupalarm_token": "",
    "dark_theme": False,
    "admin_password_hash": generate_password_hash("groupalarm"),
    "auto_update_enabled": False,
    "auto_update_day": "Sun",
    "auto_update_time": "04:00",
    "auto_update_reboot": False,
    "notify_email": "",
    "watcher_enabled": False,
    "watcher_url": "",
    "watcher_token": "",
    "watcher_monitor_id": "groupalarm-monitor",
    "session_secret": secrets.token_hex(32),
}

LEGACY_KEY_MAP = {
    "auto_update": "auto_update_enabled",
    "autoupdate": "auto_update_enabled",
    "update_time": "auto_update_time",
    "updatetime": "auto_update_time",
    "update_reboot": "auto_update_reboot",
    "updatereboot": "auto_update_reboot",
    "update_notify": "notify_email",
    "updatenotify": "notify_email",
}

TEMPLATE_DIR = Path(__file__).resolve().with_name("templates")


def ensure_config_dir() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(CONFIG_DIR, 0o700)
    except OSError:
        pass


def log(message: str, level: str = "INFO") -> None:
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {level}: {message}\n"
    try:
        ensure_config_dir()
        with LOG_FILE.open("a", encoding="utf-8") as handle:
            handle.write(line)
    except OSError:
        pass
    print(line.strip())


def normalize_config(raw_config: dict | None) -> tuple[dict, bool]:
    config = dict(DEFAULT_CONFIG)
    changed = False
    raw_config = raw_config or {}
    for key, value in raw_config.items():
        if key in LEGACY_KEY_MAP:
            config[LEGACY_KEY_MAP[key]] = value
            changed = True
        elif key == "admin_password":
            config["admin_password_hash"] = generate_password_hash(str(value))
            changed = True
        elif key in config:
            config[key] = value
    password_hash = str(config.get("admin_password_hash", ""))
    if not password_hash or not password_hash.startswith(("pbkdf2:", "scrypt:")):
        config["admin_password_hash"] = generate_password_hash(password_hash or "groupalarm")
        changed = True
    if not config.get("session_secret"):
        config["session_secret"] = secrets.token_hex(32)
        changed = True
    if set(raw_config.keys()) != set(config.keys()):
        changed = True
    return config, changed


def load_config() -> dict:
    ensure_config_dir()
    raw = None
    if CONFIG_FILE.exists():
        try:
            raw = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            raw = None
    config, changed = normalize_config(raw)
    if changed or not CONFIG_FILE.exists():
        save_config(config)
    return config


def save_config(config: dict) -> None:
    ensure_config_dir()
    normalized, _ = normalize_config(config)
    CONFIG_FILE.write_text(json.dumps(normalized, indent=2), encoding="utf-8")
    try:
        os.chmod(CONFIG_FILE, 0o600)
    except OSError:
        pass


app = Flask(__name__, template_folder=str(TEMPLATE_DIR))
app.config["PERMANENT_SESSION_LIFETIME"] = timedelta(hours=8)
app.secret_key = load_config()["session_secret"]


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect("/login")
        return view(*args, **kwargs)
    return wrapped


def api_login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return jsonify({"error": "Not logged in"}), 401
        return view(*args, **kwargs)
    return wrapped


def get_kiosk_script() -> Path:
    for candidate in KIOSK_SCRIPT_CANDIDATES:
        if candidate.exists():
            return candidate
    return KIOSK_SCRIPT_CANDIDATES[0]


def get_crontab_command() -> str | None:
    for candidate in CRONTAB_CANDIDATES:
        if candidate.exists():
            return str(candidate)
    return None


def run_command(command: list[str], timeout: int = 30, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=check)


def run_kiosk_command(action: str) -> tuple[bool, str]:
    script = get_kiosk_script()
    if not script.exists():
        return False, f"Kiosk-Skript nicht gefunden: {script}"
    try:
        result = run_command([str(script), action], timeout=45)
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"Kiosk-Kommando fehlgeschlagen ({action}): {exc}", level="ERROR")
        return False, str(exc)
    output = "\n".join(part for part in [result.stdout.strip(), result.stderr.strip()] if part).strip()
    return result.returncode == 0, output or f"Kiosk {action}"


def classify_wifi_signal(signal_dbm: int | None) -> tuple[str, str]:
    if signal_dbm is None:
        return "unknown", "Nicht verfuegbar"
    if signal_dbm >= -50:
        return "excellent", "Sehr gut"
    if signal_dbm >= -60:
        return "good", "Gut"
    if signal_dbm >= -67:
        return "usable", "Brauchbar"
    if signal_dbm >= -75:
        return "weak", "Schwach"
    return "critical", "Kritisch"


def get_wifi_status() -> dict:
    status = {
        "interface": "",
        "signal_dbm": None,
        "quality": "unknown",
        "label": "Nicht verfuegbar",
        "message": "Keine WLAN-Signalstaerke gefunden.",
    }

    try:
        iwconfig = run_command(["iwconfig"], timeout=5)
    except (OSError, subprocess.SubprocessError):
        iwconfig = None

    if iwconfig and iwconfig.returncode == 0:
        for block in re.split(r"\n(?=\S)", iwconfig.stdout):
            signal_match = re.search(r"Signal level[=:\s]*(-?\d+)\s*dBm", block)
            if not signal_match:
                continue
            interface = block.split(maxsplit=1)[0].strip()
            signal_dbm = int(signal_match.group(1))
            quality, label = classify_wifi_signal(signal_dbm)
            status.update({
                "interface": interface,
                "signal_dbm": signal_dbm,
                "quality": quality,
                "label": label,
                "message": f"{label} ({signal_dbm} dBm)",
            })
            return status

    try:
        iw_dev = run_command(["iw", "dev"], timeout=5)
    except (OSError, subprocess.SubprocessError):
        iw_dev = None

    if iw_dev and iw_dev.returncode == 0:
        interfaces = re.findall(r"Interface\s+(\S+)", iw_dev.stdout)
        for interface in interfaces:
            try:
                link = run_command(["iw", "dev", interface, "link"], timeout=5)
            except (OSError, subprocess.SubprocessError):
                continue
            signal_match = re.search(r"signal:\s*(-?\d+)\s*dBm", link.stdout)
            if not signal_match:
                continue
            signal_dbm = int(signal_match.group(1))
            quality, label = classify_wifi_signal(signal_dbm)
            status.update({
                "interface": interface,
                "signal_dbm": signal_dbm,
                "quality": quality,
                "label": label,
                "message": f"{label} ({signal_dbm} dBm)",
            })
            return status

    return status


def remove_legacy_cron() -> None:
    """Drop the pre-5.6 per-user cron line; scheduling now lives in a systemd timer."""
    crontab_command = get_crontab_command()
    if crontab_command is None:
        return
    try:
        current = run_command([crontab_command, "-l"], timeout=5)
    except (OSError, subprocess.SubprocessError):
        return
    if current.returncode != 0:
        return
    lines = [line for line in current.stdout.splitlines() if "groupalarm-auto-update.sh" not in line]
    if len(lines) == len(current.stdout.splitlines()):
        return
    new_crontab = "\n".join(lines).strip()
    if new_crontab:
        new_crontab += "\n"
    try:
        subprocess.run([crontab_command, "-"], input=new_crontab, text=True, capture_output=True, timeout=10)
        log("Alter Auto-Update-Cron-Eintrag entfernt (Umstieg auf systemd-Timer).")
    except (OSError, subprocess.SubprocessError):
        pass


def apply_update_schedule(config: dict) -> bool:
    """Regenerate the weekly systemd timer from config via the privileged helper."""
    remove_legacy_cron()
    if not APPLY_SCHEDULE_SCRIPT.exists():
        log(f"Zeitplan-Helfer nicht gefunden: {APPLY_SCHEDULE_SCRIPT}", level="WARN")
        return False
    try:
        result = run_command(["sudo", str(APPLY_SCHEDULE_SCRIPT)], timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"Zeitplan konnte nicht angewandt werden: {exc}", level="WARN")
        return False
    if result.returncode == 0:
        log(f"Auto-Update-Zeitplan aktualisiert: {result.stdout.strip()}")
        return True
    log(f"Zeitplan-Helfer meldete Fehler: {result.stderr.strip() or result.stdout.strip()}", level="WARN")
    return False


@app.route("/login", methods=["GET", "POST"])
def login():
    if session.get("logged_in"):
        return redirect("/")
    error = None
    if request.method == "POST":
        if check_password_hash(load_config()["admin_password_hash"], request.form.get("password", "")):
            session["logged_in"] = True
            session.permanent = True
            log("Admin-Login erfolgreich")
            return redirect("/")
        error = "Falsches Passwort"
        log("Fehlgeschlagener Login-Versuch", level="WARN")
    return render_template("login.html", error=error)


@app.route("/logout")
def logout():
    session.clear()
    return redirect("/login")


@app.route("/")
@login_required
def dashboard():
    return render_template("dashboard.html")


@app.route("/api/config", methods=["GET"])
@api_login_required
def api_get_config():
    config = load_config()
    running, message = run_kiosk_command("status")
    config["kiosk_running"] = running
    config["kiosk_status_message"] = message
    config["network"] = get_wifi_status()
    return jsonify(config)


@app.route("/api/network/status", methods=["GET"])
@api_login_required
def api_network_status():
    return jsonify(get_wifi_status())


@app.route("/api/config/save", methods=["POST"])
@api_login_required
def api_save_config():
    data = request.get_json(silent=True) or {}
    url = str(data.get("groupalarm_url", "")).strip()
    if not url:
        return jsonify({"error": "groupalarm_url ist erforderlich"}), 400
    config = load_config()
    config.update({
        "groupalarm_url": url,
        "groupalarm_token": str(data.get("groupalarm_token", "")).strip(),
        "dark_theme": bool(data.get("dark_theme", False)),
        "auto_update_enabled": bool(data.get("auto_update_enabled", False)),
        "auto_update_day": (str(data.get("auto_update_day", "Sun")).strip().capitalize()
                            if str(data.get("auto_update_day", "Sun")).strip().capitalize() in VALID_UPDATE_DAYS
                            else "Sun"),
        "auto_update_time": str(data.get("auto_update_time", "04:00")).strip() or "04:00",
        "auto_update_reboot": bool(data.get("auto_update_reboot", False)),
        "notify_email": str(data.get("notify_email", "")).strip(),
        "watcher_enabled": bool(data.get("watcher_enabled", False)),
        "watcher_url": str(data.get("watcher_url", "")).strip(),
        "watcher_token": str(data.get("watcher_token", "")).strip(),
        "watcher_monitor_id": str(data.get("watcher_monitor_id", "groupalarm-monitor")).strip() or "groupalarm-monitor",
    })
    save_config(config)
    apply_update_schedule(config)
    running, _ = run_kiosk_command("status")
    restarted = False
    if running:
        restarted, message = run_kiosk_command("restart")
        log(f"Kiosk nach Konfigurationsaenderung neu gestartet: {message}" if restarted else message, level="INFO" if restarted else "WARN")
    return jsonify({"success": True, "message": "Konfiguration gespeichert", "kiosk_restarted": restarted})


@app.route("/api/password/change", methods=["POST"])
@api_login_required
def api_change_password():
    data = request.get_json(silent=True) or {}
    old_password = str(data.get("old_password", ""))
    new_password = str(data.get("new_password", ""))
    config = load_config()
    if len(new_password) < 8:
        return jsonify({"error": "Das neue Passwort muss mindestens 8 Zeichen lang sein"}), 400
    if not check_password_hash(config["admin_password_hash"], old_password):
        return jsonify({"error": "Aktuelles Passwort ist falsch"}), 400
    config["admin_password_hash"] = generate_password_hash(new_password)
    save_config(config)
    log("Admin-Passwort wurde geaendert")
    return jsonify({"success": True, "message": "Passwort geaendert. Bitte neu anmelden."})


@app.route("/api/kiosk/status", methods=["GET"])
@api_login_required
def api_kiosk_status():
    running, message = run_kiosk_command("status")
    return jsonify({"running": running, "message": message})


@app.route("/api/kiosk/<action>", methods=["POST"])
@api_login_required
def api_kiosk_action(action: str):
    if action not in {"start", "stop", "restart"}:
        return jsonify({"error": "Unbekannte Aktion"}), 404
    success, message = run_kiosk_command(action)
    log(f"Kiosk-Aktion {action}: {message}", level="INFO" if success else "WARN")
    return jsonify({"success": success, "message": message}), (200 if success else 500)


@app.route("/api/system/update", methods=["POST"])
@api_login_required
def api_system_update():
    try:
        run_kiosk_command("stop")
        run_command(["sudo", "apt-get", "update"], timeout=300, check=True)
        run_command(["sudo", "apt-get", "upgrade", "-y"], timeout=1200, check=True)
        run_kiosk_command("start")
        log("System-Update abgeschlossen")
        return jsonify({"success": True, "message": "System-Update abgeschlossen"})
    except Exception as exc:  # noqa: BLE001
        log(f"System-Update fehlgeschlagen: {exc}", level="ERROR")
        return jsonify({"error": str(exc)}), 500


@app.route("/api/system/reboot", methods=["POST"])
@api_login_required
def api_system_reboot():
    try:
        run_kiosk_command("stop")
        run_command(["sudo", "shutdown", "-r", "+1", "GroupAlarm Monitor wird neu gestartet"], timeout=5, check=True)
        return jsonify({"success": True, "message": "System wird in 60 Sekunden neu gestartet"})
    except Exception as exc:  # noqa: BLE001
        log(f"System-Reboot fehlgeschlagen: {exc}", level="ERROR")
        return jsonify({"error": str(exc)}), 500


@app.route("/api/system/shutdown", methods=["POST"])
@api_login_required
def api_system_shutdown():
    try:
        run_kiosk_command("stop")
        run_command(["sudo", "shutdown", "-h", "+1", "GroupAlarm Monitor wird heruntergefahren"], timeout=5, check=True)
        return jsonify({"success": True, "message": "System wird in 60 Sekunden heruntergefahren"})
    except Exception as exc:  # noqa: BLE001
        log(f"System-Shutdown fehlgeschlagen: {exc}", level="ERROR")
        return jsonify({"error": str(exc)}), 500


@app.route("/api/system/cancel-shutdown", methods=["POST"])
@api_login_required
def api_system_cancel_shutdown():
    try:
        run_command(["sudo", "shutdown", "-c"], timeout=5, check=True)
        return jsonify({"success": True, "message": "Shutdown oder Reboot wurde abgebrochen"})
    except Exception as exc:  # noqa: BLE001
        log(f"Shutdown-Abbruch fehlgeschlagen: {exc}", level="ERROR")
        return jsonify({"error": str(exc)}), 500


@app.route("/api/logs", methods=["GET"])
@api_login_required
def api_logs():
    if not LOG_FILE.exists():
        return jsonify({"logs": []})
    with LOG_FILE.open("r", encoding="utf-8") as handle:
        return jsonify({"logs": handle.readlines()[-200:]})


@app.route("/api/logs/clear", methods=["POST"])
@api_login_required
def api_logs_clear():
    try:
        if LOG_FILE.exists():
            LOG_FILE.unlink()
        log("Logs geloescht")
        return jsonify({"success": True})
    except OSError as exc:
        return jsonify({"error": str(exc)}), 500


if __name__ == "__main__":
    log("GroupAlarm Monitor Web Interface v5.6 startet")
    app.run(host="0.0.0.0", port=8080, debug=False, use_reloader=False)
