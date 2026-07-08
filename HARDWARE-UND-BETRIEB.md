# Hardware & Betrieb

Ergänzendes Hintergrundwissen zum Kiosk-Rechner, das nicht in der Software selbst steckt und
deshalb nicht automatisch mitinstalliert werden kann. Zusammengefasst aus der ursprünglichen
Einrichtungsdokumentation (`docs/` im Hauptprojekt), bereinigt um alles, was inzwischen technisch
überholt ist (netplan → NetworkManager, `groupalarm-monitor.service` als Browser-Treiber → Openbox
+ `groupalarm-kiosk.sh`, Cron → systemd-Timer, Standardpasswort `admin123` → `groupalarm`).

## Zielhardware

Aktuell im Einsatz: **Lenovo ThinkCentre M800 Tiny**, Ubuntu 24.04 LTS, Dual-Boot mit Windows.
Windows wird bewusst nicht gelöscht, sondern als kleine Partition erhalten (Herstellersupport,
BIOS-/Firmware-Updates, Recovery-Option). Die Lenovo-Recovery-Partition bleibt beim Einrichten
unangetastet.

Bei neuer Hardware (Ersatzgerät, zweiter Standort):
1. Windows-Partition mit GParted verkleinern (Recovery-Partition **nicht** anfassen).
2. Ubuntu 24.04 LTS im freien Speicherplatz installieren (**Custom Storage Layout**, nicht
   „Festplatte löschen"), Auto-Login beim Ubuntu-Installer **nicht** aktivieren — das übernimmt
   `groupalarm-install.sh` selbst (siehe `HARDWARE-UND-BETRIEB.md` → LightDM-Fix in
   `CHANGELOG_5.6.md`).
3. Danach den Bootstrap-Befehl aus der `README.md` ausführen.

## Kritisch: BIOS-Einstellungen für unbeaufsichtigten 24/7-Betrieb

Diese zwei Einstellungen kann keine Software setzen — sie müssen **manuell im BIOS** (Taste `F1`
beim Boot) vorgenommen werden, sonst bootet der Rechner nach einem Stromausfall **nicht von
selbst wieder**:

| Einstellung | Wert | Warum |
|---|---|---|
| Power Management → AC Power Recovery / AC Power Loss Restart | **Power On** | Ohne dies bleibt der Rechner nach Stromausfall aus, bis jemand physisch den Power-Knopf drückt. |
| Power Management → ErP Ready / Deep Sleep | **Disabled** | Deep-Sleep-Modi können verhindern, dass „AC Power Recovery" überhaupt greift. |

Test: Netzteil trennen, 30 Sekunden warten, wieder anstecken → Rechner muss selbstständig hochfahren,
danach WLAN und Kiosk automatisch da sein (siehe Reboot-Test in `CHANGELOG_5.6.md`).

## Netzwerk: feste IP-Adresse (empfohlen)

Die `ga-kiosk`-Software regelt nur die WLAN-**Verbindung** selbst (Verbindungsaufbau, Reconnect,
Powersave). Für eine **stabile, vorhersagbare IP-Adresse** (wichtig für den Zugriff aufs Dashboard
unter `http://<ip>:8080`) empfiehlt sich zusätzlich eine **statische DHCP-Reservierung auf dem
Router**, unabhängig von der PC-seitigen Konfiguration:

1. MAC-Adresse des WLAN-Interfaces ermitteln: `ip link show <interface>` (Interface-Name z. B.
   `wlp1s0` — siehe `groupalarm-network-watchdog.sh`, das das Interface automatisch erkennt).
2. Im Router (Fritzbox: *Heimnetz → Netzwerk → DHCP-Reservierungen*; OpenWRT: *Network → DHCP and
   DNS → Static Leases*) diese MAC-Adresse mit einer festen IP verknüpfen.
3. Reboot zum Testen — die IP sollte danach immer gleich bleiben.

## WLAN-Signalstärke einordnen

Referenzwerte, die auch im Dashboard (`groupalarm_webinterface.py`, `classify_wifi_signal()`)
verwendet werden:

| Signal | Bewertung |
|---|---|
| ≥ −50 dBm | Sehr gut |
| −51 bis −60 dBm | Gut |
| −61 bis −67 dBm | Brauchbar |
| −68 bis −75 dBm | Schwach |
| < −75 dBm | Kritisch |

Für Dauerbetrieb sollte nach Möglichkeit ein Wert besser als −65 dBm erreicht werden (ggf. Router
näher stellen, Kanal wechseln, oder Repeater/Access Point in der Nähe des Kiosk-Rechners).

## Externer Watcher (Gegenstelle zum Heartbeat)

`groupalarm-heartbeat.timer`/`.service` sendet alle 60 Sekunden einen Heartbeat an einen externen
Watcher-Endpunkt (`watcher.php`), der **nicht** Teil dieses Repos ist, sondern im Repo
[ga-mon](https://github.com/Chris78B/ga-mon) liegt und auf einem separaten Webserver läuft.

Der Watcher unterscheidet drei Zustände:
- **Ruhemodus** — Heartbeat kommt an, externer iframe-Abruf ist aktuell → alles normal.
- **Alarmierung** — Heartbeat kommt an, aber kein aktueller iframe-Abruf → Monitor lebt, zeigt aber
  gerade die Alarmierungsansicht statt der Ruhemodus-Seite (erwartetes Verhalten im Alarmfall).
- **Ausfall** — kein aktueller Heartbeat mehr, obwohl früher schon einer ankam → Rechner offline,
  kein Internet, oder Heartbeat-Timer läuft nicht.

Konfiguration im Dashboard unter „Externe Überwachung" (`watcher_enabled`, `watcher_url`,
`watcher_token`, `watcher_monitor_id`). Token muss auf Monitor und Watcher identisch gesetzt sein.

Diagnose bei dauerhaftem „Ausfall":
```bash
systemctl status groupalarm-heartbeat.timer
systemctl status groupalarm-heartbeat.service
tail -n 50 /home/groupalarm/.groupalarm-monitor/groupalarm-heartbeat.log
```

## Warum Openbox statt Chromium direkt über systemd?

Kurze Begründung, damit das bei künftigen Änderungen nicht versehentlich rückgängig gemacht wird:
Ein per Dashboard ausgelöster Browser-Neustart über einen systemd-Service (`Restart=on-failure`)
neigt dazu, entweder in eine Neustart-Schleife zu geraten oder nach dem Neustart nicht mehr im
sauberen Vollbild-Zustand zu landen. Deshalb führt **Openbox** (innerhalb der aktiven
Desktop-Sitzung) Chromium, und **systemd** kümmert sich ausschließlich um Hintergrunddienste
(Webinterface, Watchdog, Heartbeat, Auto-Update). Das Dashboard steuert den Kiosk ausschließlich
über `groupalarm-kiosk.sh start|stop|restart|status` — nie direkt über `systemctl` auf einen
Chromium-Prozess.
