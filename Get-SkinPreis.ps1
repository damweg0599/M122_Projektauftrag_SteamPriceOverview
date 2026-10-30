<# CS2-Skin-Preisübersicht
   Liest das Steam Inventar aus und ermittelt die aktuellen Preise
   
   Exit Codes:
   0 - OK
   1 - Fehler in der Conifg
   2 - Fehler beim Laden des Inventars
   3 - Fehler bei der Preisabfrage
   #>

   param(
    [string]$ConfigPfad = (Join-Path $PSScriptRoot 'config.json'),
    [int]$TestAnzahl = 0
   )

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

# Schritt 5: Hilfsfunktionen für Preisabfrage

$pause = [int]$config.abfrage.pauseSekunden
$maxVersuche = [int]$config.abfrage.maxVersuche
if ($maxVersuche -lt 1) { $maxVersuche = 1}

function ConvertTo-Preis {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $zahl = $Text -replace '[^\d.,]', ''
    if ($zahl -match ',' -and $zahl -match '\.') {
        $zahl = $zahl -replace ',', ''
    }
    else {
        $zahl = $zahl -replace ',', '.'
    }

    [decimal]$wert = 0
    if ([decimal]::TryParse($zahl, [Globalization.NumberStyles]::Number, [cultureinfo]::InvarationCulture, [ref]$wert)) {
        return $wert
    }
    return $null
}

function Get-Preis {
    param([string]$Name)

    $url = "https://steamcommunity.com/market/priceoverview/?appid={0}&currency={1}&market_hash_name={2}" -f `
        $config.steam.appId, $config.steam.waehrung, [uri]::EscapeDataString($Name)

    for ($versuch = 1; $versuch -le $maxVersuche; $versuch++) {
        try {
            $antwort = Invoke-RestMethod -Uri $url -TimeoutSec 30
            if ($antwort.success) {
                return @{ Status = 'OK'; Antwort = $antwort }
            }
            return @{ Status = 'KEIN_PREIS'; Antwort = $null}
        }
        catch {
            $status = $null
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            
            if ($status -eq 429) {
                Write-Log ("HTTP 429 bei '{0}', warte 60 Sekunden (Versuch {1} von {2})" -f $name, $versuch, $maxVersuche) 'WARN'
                Start-Sleep -Seconds 60
            }
            else {
                Write-Log ("Fehler bei '{0}' (HTTP {1}, Versuch {2} von {3})" -f $name, $status, $versuch, $maxVersuche) 'WARN'
                Start-Sleep -Seconds $pause
            }
        }
    }
    return @{ Status = 'FEHLER'; Antwort = $null }
}

# Schritt 6: Preise für alle Skins abfragen

$skins = @($skins)

if ($TestAnzahl -gt 0) {
    $skins = @($skins | Select-Object -First $TestAnzahl)
    Write-Log "Testmodus: Es werden nur $TestAnzahl Skins abgefragt." 'WARN'
}

$total = $skins.Count
$zeitpunkt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$ergebnisse = @()
$fehlerInFolge = 0
$i = 0

Write-Log ("Frage Preise fuer {0} Skins ab (ca. {1} Minuten) ..." -f $total, [math]::Ceiling($total * $pause / 60))

foreach ($s in $skins) {
    $i++
    Write-Progress -Activity 'Checking price' `
        -Status ("{0} von {1}: {2}" -f $i, $total, $s.Skin) `
        -PercentComplete (($i / $total) * 100)

    $r = Get-Preis -Name $s.Skin
    $preis = $null

    switch ($r.Status) {
        'OK' {
            $preis = ConvertTo-Preis $r.Antwort.lowest_price
            if ($null -eq $preis) {
                $preis = ConvertTo-Preis $r.Antwort.median_price
            }
            if ($null -eq $preis) {
                Write-Log "No price found for '$($s.Skin)'" 'WARN'
            }
            $fehlerInfolge = 0
        }
        'KEIN_PREIS' {
            Write-Log "Steam liefert keinen Preis fuer '$($s.Skin)'" 'WARN'
            $fehlerInFolge = 0
        }
        'FEHLER' {
            Write-Log "Preisabfrage fuer '$($s.Skin)' fehlgeschlagen" 'WARN'
            $fehlerInFolge++
        }
    }

    if ($fehlerInFolge -ge 5) {
        Stop-Skript 3 '5 Preisabfragen in Folge fehlgeschlagen, Abbruch.'
    }

    $ergebnisse += [PSCustomObject]@{
        Zeitpunkt = $zeitpunkt
        Skin = $s.Skin
        Anzahl = $s.Anzahl
        Preis = $preis
        Wert = if ($null -ne $preis) { $preis * $s.Anzahl } else { $null }
    }

    if ($i -lt $total) { Start-Sleep -Seconds $pause }
}

Write-Progress -Activity 'Preise abfragen' -Completed

$mitPreis = @($ergebnisse | Where-Object { $null -ne $_.Preis })
if ($mitPreis.Count -eq 0) {
    Stop-Skript 3 'Fuer keinen einzigen Skin konnte ein Preis ermittelt werden.'
}

# Schritt 7: Preisverlauf speichern

$csvPfad = Join-Path $PSScriptRoot $config.pfade.preisverlauf
$csvOrdner = Split-Path $csvPfad -Parent
if (-not (Test-Path $csvOrdner)) {
    New-Item -ItemType Directory -Path $csvOrdner | Out-Null
}

$ergebnisse |
 Select-Object Zeitpunkt, Skin, Anzahl,
 @{ n = 'Preis'; e = { if ($null -ne $_.Preis) { $_.Preis.ToString('0.00', [cultureInfo]::InvariantCulture) } else { '' } } } |
 Export-Csv -Path $csvPfad -Append -NoTypeInformation -Encoding UTF8 -Delimiter ';'

 Write-Log "Preise gespeichert in $csvPfad"

 # Schritt 8: Übersicht ausgeben

 $gesamt = ($mitPreis | Measure-Object -Property Wert -Sum).Sum

 $ergebnisse | Sort-Object Wert -Descending | Format-Table -AutoSize `
  Skin,
  Anzahl,
  @{ n = 'Preis CHF'; e = { '{0:N2}' -f $_.Preis}; a = 'right'},
  @{ n = 'Wert CHF'; e = { '{0:N2}' -f $_.Wert }; a = 'right'}

  Write-Log ("Gesamtwert Inventar: CHF {0:N2} ({1} von {2} Skins mit Preise)" -f $gesamt, $mitPreis.Count, $total)
  Write-Log 'Skript erfolgreich beendet'
  exit 0