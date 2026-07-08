# GroupAlarm Monitor 5.6 — Änderungen

Basiert auf 5.5. Zwei Schwerpunkte: **wöchentliches automatisches Update** und
**Härtung der WLAN-Stabilität** (inkl. des Falls, dass userseitig das Passwort
eingegeben werden musste). Zusätzlich: mobile Login-Seite repariert und ein beim
Rollout auf einem Testgerät gefundener LightDM-Session-Bug behoben.

---

## 0. LightDM lädt beim Autologin die falsche Session (Kiosk startet nicht)

Gefunden bei der Verifikation auf einem Gerät: nach Reboot war das WLAN da,
der Kiosk (Chromium) aber nicht gestartet — erst manueller Trigger übers
Webinterface brachte ihn hoch.

**Ursache:** `user-session=openbox` in der LightDM-Config ist nur der Default
für die *Greeter*-Anzeige. Für **Autologin** zählt stattdessen die zuletzt am
Greeter gewählte Sitzung, gespeichert in `~/.dmrc` (`Session=...`). Wurde dort
je einmal versehentlich „Ubuntu" (GNOME) gewählt, lädt Autologin ab dann dauerhaft
GNOME statt Openbox — `~/.config/openbox/autostart` (und damit die
Kiosk-Startversuche) läuft nie, ohne dass sonst irgendetwas (Chromium-Binary,
Netzwerk, Rechte) auffällig wäre.

**Fix in [groupalarm-install.sh](groupalarm-install.sh) `configure_lightdm()`:**
- `autologin-session=openbox` zusätzlich zu `user-session=openbox` gesetzt —
  das ist die Direktive, die für Autologin tatsächlich bindend ist.
- `~/.dmrc` wird beim Install/Update auf `Session=openbox` gesetzt bzw. neu
  angelegt, damit ein alter Greeter-Fehlgriff nicht weiter nachwirkt.

Betrifft alle 5.x-Installationen gleichermaßen, ist aber erst hier aufgefallen
und deshalb in 5.6 mit behoben.

**Status: verifiziert.** Nach Fix + Reboot lief Openbox automatisch, der Kiosk
startete ohne manuellen Eingriff (Startversuch 1/5 erfolgreich), Chromium zeigte
die korrekte GroupAlarm-URL. Anmerkung: Das Openbox-Autostart-Log erschien beim
Test doppelt (Skript scheint zweimal geladen zu werden); funktional unkritisch,
da `groupalarm-kiosk.sh` über die PID-Datei zuverlässig nur eine Chromium-Instanz
zulässt. Bei Bedarf später per Lock-Datei am Anfang von `openbox-autostart`
zusätzlich absichern.

---

## 1. Wöchentliches automatisches Update

**Vorher (5.5):** Das Webinterface schrieb einen *täglichen* Cron-Eintrag
(`0 H * * *`). Das Skript prüfte zusätzlich die Stunde und brach ab, wenn die
aktuelle Stunde ≠ konfigurierte Stunde war — dadurch fiel ein nachgeholter oder
leicht verschobener Lauf komplett aus.

**Jetzt (5.6):**
- Neuer systemd-Timer `groupalarm-auto-update.timer` mit
  `OnCalendar=<Tag> *-*-* HH:MM` und **`Persistent=true`** → echtes wöchentliches
  Update, das verpasste Läufe (Gerät war aus) beim nächsten Boot nachholt.
- `RandomizedDelaySec=1800` entzerrt mehrere Geräte am selben Uplink.
- `groupalarm-auto-update.service` (oneshot, User `groupalarm`) ruft das
  bestehende `groupalarm-auto-update.sh`.
- Das **Stunden-Gate im Skript wurde entfernt** — der Timer besitzt die
  Zeitplanung. Das Skript honoriert nur noch `auto_update_enabled`.
- Zeitplan ist per Dashboard konfigurierbar: **Wochentag** (neu) + Uhrzeit.
  Das Webinterface ruft `sudo groupalarm-apply-update-schedule.sh`, das die
  Timer-`OnCalendar` per Drop-in aus `config.json` neu erzeugt und den Timer
  aktiviert/deaktiviert.
- Der alte Cron-Eintrag wird beim ersten Speichern automatisch entfernt.

**Neue/relevante Config-Keys:** `auto_update_enabled`, `auto_update_day`
(`Mon`…`Sun`, Default `Sun`), `auto_update_time` (`HH:MM`), `auto_update_reboot`.

**Nebenbei behobener Bug:** `auto-update.sh` nutzte `shutdown -r +5`, die sudoers
erlaubten aber nur `+1` → Auto-Reboot schlug fehl. Jetzt `+1` (passt zur Regel).

## 2. WLAN-Härtung

### Ursache des Passwort-Falls
Die WLAN-Zugangsdaten lagen als **benutzergebundene** NetworkManager-Verbindung
im **GNOME-Keyring**. Bei LightDM-Autologin wird der Keyring nicht entsperrt →
der gespeicherte PSK ist unerreichbar → NetworkManager fragt interaktiv nach dem
Passwort. Ohne Eingabe keine Verbindung.

### Maßnahmen
- **`groupalarm-wifi-setup.sh <SSID> <PSK>`**: legt die WLAN-Verbindung
  **systemweit** an — `psk-flags=0` (Schlüssel im System, nicht im Keyring),
  leere `permissions` (verfügbar vor/ohne Login), `autoconnect=yes`,
  `autoconnect-retries=0` (unendlich). Fällt ohne NetworkManager auf
  `wpa_supplicant-<iface>.conf` zurück.
- **WLAN-Powersave global aus** via `10-groupalarm-powersave.conf`
  (`wifi.powersave=2`) und zusätzlich `iw ... set power_save off` im Watchdog —
  häufige Ursache spontaner Verbindungsabbrüche.
- **Watchdog an den echten Stack angepasst:** erkennt NetworkManager und heilt
  per `nmcli` (`radio wifi on`, `connection up groupalarm-wifi`,
  `device reconnect`); ifupdown/`wpa_supplicant` bleibt Fallback. Vorher wurde
  blind `networking.service` neu gestartet, das es auf NM-Systemen nicht gibt.
- **Interface-Autodetection:** statt hart `wlan0` wird das WLAN-Interface
  ermittelt (nmcli / `/sys/class/net/*/wireless` / `iw`), unterstützt `wlpXsY`.

### Behobener Recovery-Bug (wichtig)
Die Unit `groupalarm-network-watchdog.service` hatte `NoNewPrivileges=true` und
`ProtectSystem=strict`. Das **blockiert genau die `sudo`-Aufrufe der Recovery**
(und Schreibzugriffe wie dhclient→`/etc/resolv.conf`). Mit dem `|| true` in den
Skripten lief die Wiederherstellung faktisch ins Leere. Diese Sandbox-Optionen
wurden entfernt.

**Neue sudoers-Rechte:** `nmcli *`, `iw *`, `wpa_supplicant@*`,
`groupalarm-apply-update-schedule.sh`, `groupalarm-wifi-setup.sh *`.
**Neue Pakete:** `network-manager`, `iw`.

## 3. Mobile Login-Seite (`templates/login.html`)

- **iOS-Auto-Zoom** beim Fokus behoben: Inputs haben jetzt `font-size: 16px`
  (Safari zoomt sonst automatisch in Felder < 16px).
- **iPhone-Passwortmanager** greift jetzt: Feld `autocomplete="current-password"`
  plus ein `username`-Feld mit `autocomplete="username"` (das Backend prüft nur
  das Passwort). Zusätzlich `autocapitalize=none`, `autocorrect=off`,
  `spellcheck=false`; Viewport um `viewport-fit=cover` ergänzt.

---

## Deployment

1. Paket bauen: `./create-package.sh` (oder `create-package.ps1` unter Windows).
2. Auf dem Ubuntu-Rechner als root: `./groupalarm-install.sh`.
3. WLAN einmalig systemweit hinterlegen (falls nicht via
   `GROUPALARM_WIFI_SSID`/`GROUPALARM_WIFI_PSK` beim Install):
   `sudo /usr/local/bin/groupalarm-wifi-setup.sh '<SSID>' '<WLAN-Passwort>'`
4. Im Dashboard Auto-Update aktivieren, Wochentag/Uhrzeit setzen.
5. **Reboot-Test:** Nach Neustart muss das WLAN **ohne Login** verbinden.

### Offene Annahme
Der Watchdog erkennt den Stack automatisch, ist aber auf **NetworkManager**
(Ubuntu-Desktop-Default) optimiert. Auf dem Zielgerät kurz `nmcli device status`
prüfen. Meldet der Befehl „command not found" oder ist NM inaktiv, greift der
ifupdown-Fallback — dann sollte die WLAN-Provisionierung über die
`wpa_supplicant`-Variante laufen.
