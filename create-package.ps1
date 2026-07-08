$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ArchivePath = Join-Path $ScriptDir "groupalarm-monitor-5.6.tar.gz"
$ChecksumPath = Join-Path $ScriptDir "groupalarm-monitor-5.6.tar.gz.sha256"

$PackageItems = @(
    "groupalarm_webinterface.py",
    "groupalarm-kiosk.sh",
    "groupalarm-auto-update.sh",
    "groupalarm-apply-update-schedule.sh",
    "groupalarm-wifi-setup.sh",
    "groupalarm-network-watchdog.sh",
    "groupalarm-heartbeat.sh",
    "openbox-autostart",
    "10-groupalarm-powersave.conf",
    "groupalarm-webinterface.service",
    "groupalarm-monitor.service",
    "groupalarm-network-watchdog.service",
    "groupalarm-heartbeat.service",
    "groupalarm-heartbeat.timer",
    "groupalarm-auto-update.service",
    "groupalarm-auto-update.timer",
    "systemd_services.conf",
    "templates/dashboard.html",
    "templates/login.html"
)

Push-Location $ScriptDir
try {
    foreach ($Item in $PackageItems) {
        if (-not (Test-Path $Item)) {
            throw "Paketdatei fehlt: $Item"
        }
    }

    if (Test-Path $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath
    }

    & tar -czf $ArchivePath @PackageItems

    $Hash = Get-FileHash -Algorithm SHA256 -Path $ArchivePath
    "$($Hash.Hash.ToLower())  groupalarm-monitor-5.6.tar.gz" | Set-Content -Path $ChecksumPath -Encoding ascii

    Write-Host "Paket erstellt: $ArchivePath"
    Write-Host "Checksumme erstellt: $ChecksumPath"
}
finally {
    Pop-Location
}
