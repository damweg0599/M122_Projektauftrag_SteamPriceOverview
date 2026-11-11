<# CS2-Skin-Preisübersicht
   Liest das Steam Inventar aus und ermittelt die aktuellen Preise
   
Ablauf:
    Schritt 1   Logging vorbereiten
    Schritt 2   Config lesen und prüfen
    Schritt 3   Inventar über die Steam-Inventar-API laden
    Schritt 4   Handelbare Skins zusammenfassen
    Schritt 5   Hilfsfunktionen für die Preisabfrage
    Schritt 6   Preise aller Skins abfragen
    Schritt 6b  Vergleich mit dem letzten bekannten Preis
    Schritt 7   Preisverlauf speichern
    Schritt 8   Übersicht in der Konsole ausgeben
    Schritt 9   HTML-Bericht erstellen und alte Berichte archivieren

    -ConfigPfad   Pfad zur Konfigurationsdatei (Standard: config.json im Skriptordner)

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
    Write-Log "Script completed with Exit-Code $Code" 'FEHLER'
    exit $Code
}

Write-Log 'Script started'

# Schritt 2: Config lesen und prüfen

$configPfad = Join-Path $PSScriptRoot 'config.json'

if (-not (Test-Path $configPfad)) {
    Stop-Skript 1 "Config-File not found: $configPfad"
}

try {
    $config = Get-Content $configPfad -Raw -Encoding UTF8 | ConvertFrom-Json 
}
catch {
    Stop-Skript 1 "Config.json is not a valid JSON file: $($_.Exception.Message)"
}

if ("$($config.steam.steamId64)" -notmatch '^7656\d{13}$') {
    Stop-Skript 1 "Invalid SteamID64 in Config.json: $($config.steam.steamId64)"
}
if ([int]$config.abfrage.pauseSekunden -lt 1) {
    Stop-Skript 1 'pauseSekunden in Config.json must be at least 1'
}

Write-Log "Config loaded (SteamID64: $($config.steam.steamId64))"

#Schritt 3 Inventar laden

$url = "https://steamcommunity.com/inventory/{0}/{1}/2?l=german&count=500" -f `
    $config.steam.steamId64, $config.steam.appId

Write-Log 'Loading Steam Inventory...'

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
    403 { Stop-Skript 2 'Inventory is private (HTTP 403). Set inventory to "Public" on Steam.'}
    404 { Stop-Skript 2 'Inventory not found (HTTP 404). Check SteamID64 in config.json.'}
    429 { Stop-Skript 2 'Too many requests (HTTP 429). Try again later.'}
    default { Stop-Skript 2 "Error loading inventory: (HTTP $status)" }
    }
}

if (-not $inv -or $inv.success -ne 1) {
    Stop-Skript 2 'Steam has not delivered valid inventory data.'
}
if ($inv.more.items) {
    Write-Log 'Inventory has more than 500 items, only the first 500 will be evaluated.' 'WARN'
}

# Schritt 4: Handelbare Skins zusammenfassen

$beschreibung = @{}
foreach ($d in $inv.descriptions) {
    $beschreibung["$($d.classid):$($d.instanceid)"] = $d
}

$icons = @{}


$namen = foreach ($a in $inv.assets) {
    $d = $beschreibung["$($a.classid):$($a.instanceid)"]
    if ($d -and (-not $config.steam.nurHandelbare -or $d.marketable -eq 1)) {
        if (-not $icons.ContainsKey($d.market_hash_name)) {
            $icons[$d.market_hash_name] = $d.icon_url
        }
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
    Write-Log 'No tradeable skins found in inventory.' 'WARN'
    exit 0
}

Write-Log ("Inventory loaded: {0} Items, {1} different tradeable skins" -f `
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

Write-Log ("Checking prices for {0} Skins (ca. {1} Minute) ..." -f $total, [math]::Ceiling($total * $pause / 60))

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
            Write-Log "Steam does not deliver price for '$($s.Skin)'" 'WARN'
            $fehlerInFolge = 0
        }
        'FEHLER' {
            Write-Log "Price checking '$($s.Skin)' failed" 'WARN'
            $fehlerInFolge++
        }
    }

    if ($fehlerInFolge -ge 5) {
        Stop-Skript 3 '5 Price checking failed in a row, cancelled.'
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

Write-Progress -Activity 'Price checking complete' -Completed

$mitPreis = @($ergebnisse | Where-Object { $null -ne $_.Preis })
if ($mitPreis.Count -eq 0) {
    Stop-Skript 3 'not a single price for any skin were found.'
}

# Schritt 6b: Vergleich mit dem letzten bekannten Preis

$csvPfad = Join-Path $PSScriptRoot $config.pfade.preisverlauf
$letztePreise = @{}

if (Test-Path $csvPfad) {
    $verlauf = @(Import-Csv -Path $csvPfad -Delimiter ';' -Encoding UTF8)
    $mitWert = $verlauf | Where-Object { $_.Preis -ne '' }

    foreach ($gruppe in ($mitWert | Group-Object Skin)) {
        $letzter = $gruppe.Group | Sort-Object Zeitpunkt | Select-Object -Last 1
        $letztePreise[$gruppe.Name] = [decimal]::Parse($letzter.Preis, [cultureinfo]::InvariantCulture)
    }
    Write-Log ("Preisverlauf geladen: {0} Eingräge, {1} Skins mit früherem Preis" -f $verlauf.Count, $letztePreise.Count)
}
else {
    Write-Log 'no price history available (first run).'
}

foreach ($e in $ergebnisse) {
    $alterPreis = $null
    $differenz = $null
    $prozent = $null

    if ($letztePreise.ContainsKey($e.Skin) -and $null -ne $e.Preis) {
        $alterPreis = $letztePreise[$e.Skin]
        $differenz = $e.Preis - $alterPreis
        if ($alterPreis -ne 0) {
            $prozent = ($differenz / $alterPreis) * 100
        }
    }

    $richtung = if ($null -eq $differenz) { 'neu' }
    elseif ($differenz -gt 0) { 'hoch' }
    elseif ($differenz -lt 0) { 'runter' }
    else { 'gleich' }

    $e | Add-Member -NotePropertyName 'AlterPreis' -NotePropertyValue $alterPreis
    $e | Add-Member -NotePropertyName 'Differenz' -NotePropertyValue $differenz
    $e | Add-Member -NotePropertyName 'Prozent' -NotePropertyValue $prozent
    $e | Add-Member -NotePropertyName 'Richtung' -NotePropertyValue $richtung
}

$pfeile = @{
    hoch = [string][char]0x25b2
    runter = [string][char]0x25bc
    gleich = '='
    neu = '-'
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

$mitVergleich = @($ergebnisse | Where-Object { $null -ne $_.Differenz })
$wertAenderung = $null
if ($mitVergleich.Count -gt 0) {
    $wertAenderung = ($mitVergleich | Foreach-Object { $_.Differenz * $_.Anzahl } | Measure-Object -Sum).Sum
}

$ergebnisse | Sort-Object Wert -Descending | Format-Table `
Skins,
Anzahl,
@{ n = 'Preis CHF'; e = { '{0:N2}' -f $_.Preis }; a = 'right' },
@{ n = 'Trend'; e = { $pfeile[$_.Richtung] }; a = 'center'  },
@{ n = 'Diff CHF'; e = { if ($null -ne $_.Differenz) { '{0:+0.00;-0.00;0.00}' -f $_.Differenz } }; a = 'right' },
@{ n = '%'; e = { if ($null -ne $_.Prozent) { '{0:+0.00;-0.00;0.00}' -f $_.Prozent } }; a = 'right' },
@{ n = 'Wert CHF'; e = { '{0:N2}' -f $_.Wert }; a = 'right' }

Write-Log ("Gesamtwert Inventar: CHF {0:N2} ({1} von {2} Skins mit Preis)" -f $gesamt, $mitPreis.Count, $total)
if ($null -ne $wertAenderung) {
    Write-Log ("Veränderung seit letztem Lauf: CHF {0:+0.00;-0.00;0.00}" -f $wertAenderung)
}

# Schritt 9: HTML-Bericht

$berichtOrdner  = Join-Path $PSScriptRoot $config.pfade.berichte
$archivOrdner = Join-Path $PSScriptRoot $config.pfade.archiv
foreach ($ordner in $berichtOrdner, $archivOrdner) {
    if (-not (Test-Path $ordner)) {
        New-Item -ItemType Directory -Path $ordner | Out-Null
    }
}

# Alte Bericht ins Archiv verschieben

$alteBerichte = @(Get-ChildItem -Path $berichtOrdner -Filter 'bericht*.html' -File)
foreach ($datei in $alteBerichte) {
    try {
        move-item -Path $datei.FullName -Destination $archivOrdner -Force
    }
    catch {
        Write-Log "Bericht '$($datei.Name)' konnte nicht archiviert werden: $($_.Exception.Message)" 'WARN'
    }
}
if ($alteBerichte.Count -gt 0) {
    Write-Log ("old reports moved to archive." -f $alteBerichte.Count)
}

# Neuer Dateiname mit Datum und Uhrzeit des Laufs

$zeitstempel = $zeitpunkt -replace ' ', '_' -replace ':', '-'
$berichtPfad = Join-Path $berichtOrdner ("bericht_{0}.html" -f $zeitstempel)

$bildBasis = "https://$($config.steam.bildServer)/economy/image/"  

$zeilen = foreach ($e in ($ergebnisse | Sort-Object Wert -Descending)) {
    $diffText = ''
    $prozText = ''
    if ($null -ne $e.Differenz) { $diffText = '{0:+0.00;-0.00;0.00}' -f $e.Differenz }
    if ($null -ne $e.Prozent)   { $prozText = '{0:+0.0;-0.0;0.0} %'  -f $e.Prozent }

    $bildHtml = ''
    if($icons.Containskey($e.Skin) -and $icons[$e.Skin]) {
        $bildUrl = $bildBasis + $icons[$e.Skin] + '/96fx96f'
        $bildHtml = "<img src='{0}' alt='{1}' loading='lazy' onerror='this.remove()'>" -f `
        $bildUrl, [System.Net.WebUtility]::HtmlEncode($e.Skin)
    }

    "<tr><td><div class='skin'><span>{0}</span>{8}</div></td><td class='zahl'>{1}</td><td class='zahl'>{2:N2}</td><td class='{3}'>{4}</td><td class='zahl {3}'>{5}</td><td class='zahl {3}'>{6}</td><td class='zahl'>{7:N2}</td></tr>" -f `
    [System.Net.WebUtility]::HtmlEncode($e.Skin), $e.Anzahl, $e.Preis,
    $e.Richtung, $pfeile[$e.Richtung], $diffText, $prozText, $e.Wert, $bildHtml
}

$gesamtText = '{0:N2}' -f $gesamt
if ($null -ne $wertAenderung) {
    $aenderungText   = 'CHF {0:+0.00;-0.00;0.00}' -f $wertAenderung
    $aenderungKlasse = if ($wertAenderung -gt 0) { 'hoch' } elseif ($wertAenderung -lt 0) { 'runter' } else { 'gleich' }
}
else {
    $aenderungText   = 'erster Lauf'
    $aenderungKlasse = 'neu'
}

$html = @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>CS2-Skin-Preis&uuml;bersicht</title>
<style>
  body   { font-family: "Segoe UI", Arial, sans-serif; margin: 2rem; background: #f6f7f9; color: #222; }
  h1     { margin-bottom: .2rem; }
  .stand { color: #666; margin-top: 0; }
  .karten { display: flex; gap: 1rem; flex-wrap: wrap; margin: 1.2rem 0 1.5rem; }
  .karte { background: #fff; border: 1px solid #e3e5e8; border-radius: 8px; padding: .9rem 1.2rem; min-width: 180px; }
  .karte b { display: block; font-size: 1.4rem; margin-top: .2rem; }
  table  { border-collapse: collapse; width: 100%; background: #fff; }
  th, td { padding: .45rem .7rem; border-bottom: 1px solid #e3e5e8; text-align: left; vertical-align: middle; }
  th     { background: #2b3440; color: #fff; }
  tr:hover { background: #f0f3f6; }
  .zahl  { text-align: right; font-variant-numeric: tabular-nums; }
  .hoch  { color: #1a7f37; }
  .runter { color: #c62828; }
  .gleich, .neu { color: #888; }
  .skin      { display: flex; align-items: center; gap: .75rem; }
  .skin img  { width: 64px; height: auto; flex-shrink: 0;
               background: #2b3440; border-radius: 6px; padding: 3px; }
</style>
</head>
<body>
<h1>CS2-Skin-Preis&uuml;bersicht</h1>
<p class="stand">Stand: $zeitpunkt</p>

<div class="karten">
  <div class="karte">Gesamtwert<b>CHF $gesamtText</b></div>
  <div class="karte">Ver&auml;nderung seit letztem Lauf<b class="$aenderungKlasse">$aenderungText</b></div>
  <div class="karte">Skins mit Preis<b>$($mitPreis.Count) / $total</b></div>
</div>

<table>
  <tr><th>Skin</th><th>Anz.</th><th>Preis CHF</th><th>Trend</th><th>Diff CHF</th><th>%</th><th>Wert CHF</th></tr>
  $($zeilen -join "`n  ")
</table>
</body>
</html>
"@

try {
    $html | Set-Content -Path $berichtPfad -Encoding UTF8
}
catch {
    Stop-Skript 4 "HTML-Bericht konnte nicht gespeichert werden: $($_.Exception.Message)"
}
Write-Log "HTML-Bericht erstellt: $berichtPfad"

Write-Log 'Skript successfully completed'
exit 0