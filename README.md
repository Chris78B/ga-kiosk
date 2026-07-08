# ga-kiosk

Ubuntu-Kiosk-Unterbau für den GroupAlarm-Monitor-Anzeigerechner der Feuerwehr Hove.

Der Rechner läuft im Autologin-Kiosk-Modus (Openbox + Chromium Vollbild) und zeigt
den GroupAlarm Monitor inkl. eingebetteter Widgets ([ga-mon](https://github.com/Chris78B/ga-mon)).
Dieses Repo enthält alles, was dafür auf dem Ubuntu-Rechner installiert wird:

- **Webinterface** (Flask, Port 8080) zur Konfiguration (URL, Token, Dark-Theme, Auto-Update-Zeitplan, WLAN-Status)
- **Kiosk-Controller** (`groupalarm-kiosk.sh`) — startet/stoppt Chromium im Kiosk-Modus
- **Netzwerk-Watchdog** — erkennt Verbindungsausfälle und heilt automatisch (NetworkManager-aware, mit ifupdown-Fallback)
- **Wöchentlicher Auto-Update-Timer** (systemd, holt verpasste Läufe nach)
- **WLAN-Provisionierung** — hinterlegt Zugangsdaten systemweit und keyring-unabhängig
- **Installer** (`groupalarm-install.sh`) — idempotent, dient sowohl für Erstinstallation als auch für Updates

## Installation / Update

Ein Befehl reicht, auf dem Zielrechner als Nutzer mit `sudo`-Rechten ausgeführt:

```bash
curl -fsSL https://raw.githubusercontent.com/Chris78B/ga-kiosk/main/bootstrap.sh | sudo bash
```

Das lädt nur `bootstrap.sh` (kurz genug, um sie vor dem Ausführen zu lesen). Sie holt sich
selbstständig das **aktuell neueste** GitHub Release (Installer + Archiv + Prüfsumme), verifiziert
die SHA256-Checksumme und startet den Installer. Derselbe Befehl funktioniert für die
Erstinstallation genauso wie für spätere Updates — `groupalarm-install.sh` ist idempotent und
lässt eine bestehende `config.json` unangetastet.

Wer die Datei vorher lesen möchte, statt sie direkt in `bash` zu pipen:

```bash
curl -fsSL -O https://raw.githubusercontent.com/Chris78B/ga-kiosk/main/bootstrap.sh
sudo bash bootstrap.sh
```

### Was macht der Installer?

- installiert Systemabhängigkeiten (Python/Flask, Chromium, Openbox, LightDM, NetworkManager, jq, …)
- legt den Systembenutzer `groupalarm` an (falls nicht vorhanden)
- deployt alle Laufzeitdateien nach `/usr/local/bin` bzw. `/etc/systemd/system`
- konfiguriert LightDM-Autologin (inkl. erzwungener Openbox-Session, siehe `CHANGELOG_5.6.md`)
- richtet die notwendigen `sudoers`-Regeln für Netzwerk-Recovery und Auto-Update ein
- aktiviert die systemd-Services/-Timer
- optional: WLAN systemweit hinterlegen, wenn `GROUPALARM_WIFI_SSID`/`GROUPALARM_WIFI_PSK` gesetzt sind

Details und Versionsverlauf: siehe `CHANGELOG_5.6.md`.

## Konfiguration

Nach der Installation: `http://<geraete-ip>:8080` öffnen (Initialpasswort `groupalarm`, bitte
danach ändern). Dort lassen sich GroupAlarm-URL/Token, Dark-Theme, Auto-Update
(Wochentag + Uhrzeit), Benachrichtigungs-E-Mail und der externe Watcher-Heartbeat einstellen.

WLAN nachträglich/manuell systemweit hinterlegen (keyring-unabhängig, übersteht Reboot ohne
Passworteingabe):

```bash
sudo /usr/local/bin/groupalarm-wifi-setup.sh '<SSID>' '<WLAN-Passwort>'
```

## Hardware & Betrieb

Zielhardware, kritische BIOS-Einstellungen für unbeaufsichtigten 24/7-Betrieb, Empfehlung zur
festen IP-Adresse, WLAN-Signalstärke-Referenz, externer Watcher und die Begründung für die
Openbox-zentrierte Architektur: siehe [HARDWARE-UND-BETRIEB.md](HARDWARE-UND-BETRIEB.md).

## Ein neues Release veröffentlichen (Entwickler-Workflow)

1. Code ändern, testen.
2. Paket bauen:
   ```powershell
   ./create-package.ps1
   ```
   oder unter Linux/macOS:
   ```bash
   ./create-package.sh
   ```
   Erzeugt `ga-kiosk.tar.gz` + `ga-kiosk.tar.gz.sha256` (versionsunabhängige Dateinamen —
   werden über `.gitignore` bewusst **nicht** committet, da sie nur als Release-Assets existieren).
3. Quelländerungen committen und pushen:
   ```bash
   git add -A
   git commit -m "..."
   git push
   ```
4. Neues GitHub Release anlegen: [releases/new](https://github.com/Chris78B/ga-kiosk/releases/new)
   - Tag z. B. `v5.7` (neues Tag beim Veröffentlichen anlegen lassen)
   - Als Assets **genau diese drei Dateien mit exakt diesen Namen** hochladen:
     - `groupalarm-install.sh`
     - `ga-kiosk.tar.gz`
     - `ga-kiosk.tar.gz.sha256`
   - Publish release.

`bootstrap.sh` muss dafür **nicht** angepasst werden: `/releases/latest/download/<dateiname>`
zeigt automatisch immer auf das jeweils neueste Release, solange die Asset-Dateinamen über alle
Releases hinweg identisch bleiben.

## Sicherheitsmodell

- Das Repo ist bewusst **öffentlich**: Es enthält keine Zugangsdaten (WLAN-Credentials werden zur
  Laufzeit als Parameter übergeben, nicht im Code hinterlegt) — dadurch funktioniert der
  Bootstrap-Download ohne Token/Authentifizierung.
- Die SHA256-Prüfung in `bootstrap.sh` schützt vor Übertragungsfehlern/unvollständigen Downloads.
  Sie schützt **nicht** vor einem kompromittierten Repository (wer Schreibzugriff auf das Repo
  hat, kann Archiv und Checksumme gemeinsam austauschen) — für dieses interne Ein-Personen-Setup
  ein bewusst akzeptierter Kompromiss.

## Fehlerbehebung

Siehe `systemd_services.conf` — dort stehen typische Befehle (Service-Status, Logs) und eine
Liste bekannter Probleme mit Lösungswegen (Webinterface nicht erreichbar, Chromium startet nicht,
Netzwerk-Watchdog heilt nicht, externer Watcher zeigt Ausfall).
