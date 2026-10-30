<# CS2-Skin-Preisübersicht
   Liest das Steam Inventar aus und ermittelt die aktuellen Preise
   
   Exit Codes:
   0 - OK
   1 - Fehler in der Conifg
   2 - Fehler beim Laden des Inventars
   3 - Fehler bei der Preisabfrage
   #>

   $ErrorActionPreference = "Stop"


# Schritt 1: Logging

$logOrdner = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logOrdner)) {
    New-Item -ItemType Directory -Path $logOrdner | Out-Null
}
$logDatei = Join-Path $logOrdner ("{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))

function Write-Log {
    param(
        [string]$Text,
        [ValidateSet('Info', 'WARN', 'FEHLER')]
        [string]$Stufe = 'INFO'
    )
    $zeile = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Stufe, $Text
    Add-Content -Path $logDatei -Value $zeile -Encoding UTF8

    switch ($Stufe) {
        'FEHLER' { Write-Host $zeile -ForegroundColor Red }
        'WARN' { Write-Host $zeile -ForegroundColor Yellow }
        default { Write-Host $zeile }
    }
}

function Stop-Skript {
    param(
        [int]$Code,
        [string]$Text
    )
    Write-Log $Text 'FEHLER'
    Write-Log "Skript beendet mit Exit-Code $Code" 'FEHLER'
    exit $Code
}

Write-Log 'Skript gestartet'

# Schritt 2: Config lesen und prüfen

$configPfad = Join-Path $PSScriptRoot 'config.json'

if (-not (Test-Path $configPfad)) {
    Stop-Skript 1 "Config-Datei nicht gefunden: $configPfad"
}

try {
    $config = Get-Content $configPfad -Raw -Encoding UTF8 | ConvertFrom-Json 
}
catch {
    Stop-Skript 1 "Config.json ist keine gültige JSON-Datei: $($_.Exception.Message)"
}

if ("$($config.steam.steamId64)" -notmatch '^7656\d{13}$') {
    Stop-Skript 1 "Ungueltige SteamID64 in Config.json: $($config.steam.steamId64)"
}
if ([int]$config.abfrage.pauseSekunden -lt 1) {
    Stop-Skript 1 'pauseSekunden in Config.json muss mindestens 1 sein'
}

Write-Log "Config geladen (SteamID64: $($config.steam.steamId64))"

#Schritt 3 Inventar laden

$url = "https://steamcommunity.com/inventory/{0}/{1}/2?l=german&count=500" -f `
    $config.steam.steamId64, $config.steam.appId

Write-Log 'Lade Inventar von Steam...'

try {
    $inv = Invoke-RestMethod -Uri $url -TimeoutSec 30
}
catch {
    $fehler = $_
    $status = $null
    if ($fehler.Exception.Response) {
        $status = [int]$fehler.Exception.Response.StatusCode
}
Switch ($status) {
    403 { Stop-Skript 2 'Inventar ist Privat (HTTP 403). In Steam auf "Öffentlich stellen.'}
    404 { Stop-Skript 2 'Inventar nicht gefunden (HTTP 404). SteamID64 in config.json prüfen.'}
    429 { Stop-Skript 2 'Zu viele Anfragen (HTTP 429). Später erneut versuchen.'}
    default { Stop-Skript 2 "Fehler beim Laden des Inventars: (HTTP $status)" }
    }
}

if (-not $inv -or $inv.success -ne 1) {
    Stop-Skript 2 'Steam hat keine gültigen Inventardaten geliefert.'
}
if ($inv.more.items) {
    Write-Log 'Inventar hat mehr als 500 Items, es werden nur die ersten 500 ausgewertet.' 'WARN'
}

# Schritt 4: Handelbare Skins zusammenfassen

$beschreibung = @{}
foreach ($d in $inv.descriptions) {
    $beschreibung["$($d.classid):$($d.instanceid)"] = $d
}

$namen = foreach ($a in $inv.assets) {
    $d = $beschreibung["$($a.classid):$($a.instanceid)"]
    if ($d -and (-not $config.steam.nurHandelbare -or $d.marketable -eq 1)) {
        $d.market_hash_name
    }
}

$skins =$namen | Group-Object | Sort-Object Count -Descending | ForEach-Object {
    [PSCustomObject]@{
        Skin = $_.Name
        Anzahl = $_.Count
    }
}

if (-not $skins) {
    Write-Log 'Keine handelbaren Skins im Inventar gefunden.' 'WARN'
    exit 0
}

Write-Log ("Inventar geladen: {0} Items, {1} verschiedene handelbare Skins" -f `
    $inv.total_inventory_count, @($skins).Count)

# Zwischenausgabe zum Testen
$skins | Format-Table -AutoSize