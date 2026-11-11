# M122 – CS2-Skin-Preisübersicht

PowerShell-Skript, das die CS2-Skins aus meinem Steam-Inventar ausliest, die aktuellen Preise in CHF über den Steam Community Market abfragt, sie mit dem letzten Lauf vergleicht und daraus einen HTML-Bericht erstellt. Das Skript startet jeden Tag automatisch über die Windows-Aufgabenplanung.

**Projektmitarbeiter:** Dustin Amweg (Einzelarbeit) · Modul M122 · Technische Berufsschule Zürich

---

## Inhalt

- [Ausgangslage und Ziel](#ausgangslage-und-ziel)
- [Funktionen](#funktionen)
- [Projektstruktur](#projektstruktur)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Konfiguration](#konfiguration)
- [Bedienung](#bedienung)
- [Automatischer Start](#automatischer-start)
- [Ablauf des Skripts](#ablauf-des-skripts)
- [Fehlerbehandlung und Exit-Codes](#fehlerbehandlung-und-exit-codes)
- [Schnittstellen](#schnittstellen)
- [Tests](#tests)
- [Bekannte Einschränkungen](#bekannte-einschränkungen)

---

## Ausgangslage und Ziel

Wer CS2-Skins besitzt, muss die Preise auf dem Steam Community Market für jeden Skin einzeln von Hand nachschauen. Dadurch fehlt der Überblick, wie viel das eigene Inventar wert ist und ob ein Preis gerade hoch oder tief ist. Ich spiele selbst CS2 und wollte das automatisieren.

**Ziel (SMART):** Bis am **04.11.2026** liest das Skript einmal täglich automatisch alle handelbaren CS2-Skins aus meinem Steam-Konto aus, ermittelt für jeden Skin den aktuellen Preis in CHF, zeigt die Veränderung zum letzten Lauf in CHF und Prozent sowie den Gesamtwert des Inventars an und meldet Fehler per Log und Exit-Code.

## Funktionen

- Inventar über die Steam-Inventar-API laden und gleiche Skins zusammenzählen
- Aktuellen Preis jedes Skins in CHF über die Steam-Market-API abfragen, mit Pause und Wiederholung bei Fehlern
- Preise mit Zeitstempel in `daten/preisverlauf.csv` speichern
- Veränderung zum letzten bekannten Preis in CHF und Prozent berechnen (▲ / ▼ / =)
- Übersicht mit Gesamtwert in der Konsole ausgeben
- HTML-Bericht mit Gesamtwert, Veränderung, Trend und Skinbildern erstellen
- Ältere Berichte automatisch nach `berichte/archiv` verschieben
- Jeden Schritt mit Zeitstempel in `logs/<Datum>.log` protokollieren
- Bei Fehlern mit einem definierten Exit-Code abbrechen, statt still zu scheitern

## Projektstruktur

| Datei / Ordner | Beschreibung |
|---|---|
| `Get-SkinPreis.ps1` | Hauptskript |
| `config.json` | Einstellungen |
| `readme.md` | Diese Anleitung |
| `daten/preisverlauf.csv` | Preise aller Läufe (vom Skript erstellt) |
| `berichte/` | Aktueller HTML-Bericht `bericht_<Datum>_<Uhrzeit>.html` (vom Skript erstellt) |
| `berichte/archiv/` | Ältere Berichte |
| `logs/` | Eine Logdatei pro Tag, z. B. `2026-11-11.log` |

Die Ordner `daten`, `berichte`, `berichte/archiv` und `logs` legt das Skript selbst an, falls sie fehlen.

## Voraussetzungen

| Komponente | Version | Verwendung |
|---|---|---|
| Windows | 10 oder 11 | Betriebssystem, Aufgabenplanung |
| Windows PowerShell | 5.1 (vorinstalliert) | Ausführung des Skripts |
| Internetzugang | HTTPS (Port 443) | Zugriff auf die Steam-Dienste |
| Steam-Konto | – | CS2-Inventar, Profil und Inventar auf **«Öffentlich»** |
| Webbrowser | beliebig | Anzeige des HTML-Berichts |

Zusätzliche PowerShell-Module sind nicht nötig.

## Installation

1. Repository klonen:
   ```powershell
   git clone https://github.com/damweg0599/M122_Projektauftrag_SteamPriceOverview.git
   cd M122_Projektauftrag_SteamPriceOverview
   ```
2. In Steam unter *Profil bearbeiten → Privatsphäre-Einstellungen* das Profil und das Inventar auf **«Öffentlich»** stellen.
3. Skriptausführung für den eigenen Benutzer erlauben (einmalig):
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```
4. In `config.json` die eigene SteamID64 eintragen (siehe [Konfiguration](#konfiguration)).
5. Testlauf durchführen (siehe [Bedienung](#bedienung)).
6. Automatischen Start einrichten (siehe [Automatischer Start](#automatischer-start)).

## Konfiguration

Alle Einstellungen stehen in `config.json`. Das Skript fragt nichts interaktiv ab.

```json
{
    "steam": {
        "steamId64": "7656119XXXXXXXXXX",
        "appId": 730,
        "Waehrung": 4,
        "nurHandelbar": true,
        "bildServer": "community.fastly.steamstatic.com"
    },
    "abfrage": {
        "pauseSekunden": 5,
        "maxVersuche": 3
    },
    "pfade": {
        "preisverlauf": "daten/preisverlauf.csv",
        "berichte": "berichte",
        "archiv": "berichte/archiv"
    }
}
```

| Parameter | Wert | Bedeutung |
|---|---|---|
| `steam.steamId64` | 17 Ziffern | Steam-ID des Kontos, beginnt mit `7656` |
| `steam.appId` | `730` | Spiel-ID von CS2 |
| `steam.Waehrung` | `4` | Währungscode von Steam (4 = CHF) |
| `steam.nurHandelbar` | `true` | Nur Items berücksichtigen, die auf dem Markt verkauft werden können |
| `steam.bildServer` | Hostname | Bildserver von Steam für die Skinbilder im Bericht |
| `abfrage.pauseSekunden` | min. `1` | Wartezeit zwischen zwei Preisabfragen |
| `abfrage.maxVersuche` | `3` | Versuche pro Preisabfrage |
| `pfade.*` | relativer Pfad | Ablageorte für Preisverlauf, Berichte und Archiv |

Die SteamID64 findest du in Steam unter *Kontodetails* oder in der Profil-URL. Sie ist öffentlich und kein Geheimnis. Passwörter oder API-Schlüssel gehören nie in die Config.

## Bedienung

Im Projektordner in PowerShell:

```powershell
# Testlauf mit den ersten 5 Skins
.\Get-SkinPreis.ps1 -TestAnzahl 5

# Vollständiger Lauf mit allen Skins
.\Get-SkinPreis.ps1

# Exit-Code des letzten Laufs anzeigen
$LASTEXITCODE

# Aktuellen Bericht im Browser öffnen
Get-ChildItem .\berichte\bericht_*.html | Start-Process

# Letzte Einträge im Log anzeigen
Get-Content .\logs\*.log -Tail 10
```

| Parameter | Standard | Bedeutung |
|---|---|---|
| `-TestAnzahl` | `0` (alle) | Nur die ersten n Skins abfragen |

Ein vollständiger Lauf dauert wegen der Pause zwischen den Abfragen mehrere Minuten, bei rund 140 Skins und 5 Sekunden Pause etwa 12 Minuten.

## Automatischer Start

Das Skript wird über die **Windows-Aufgabenplanung** jeden Tag um **09:00 Uhr** gestartet.

1. Aufgabenplanung öffnen: Start → «Aufgabenplanung» (`taskschd.msc`).
2. Rechts auf **«Aufgabe erstellen…»** klicken.
3. Register **Allgemein**: Name `CS2-Skin-Preisuebersicht`, Beschreibung `M122: tägliche CS2-Preisabfrage`, Option «Nur ausführen, wenn der Benutzer angemeldet ist».
4. Register **Trigger** → «Neu…»: «Nach einem Zeitplan», «Täglich», 09:00:00 Uhr, «Aktiviert».
5. Register **Aktionen** → «Neu…»: «Programm starten»
   - Programm/Skript: `powershell.exe`
   - Argumente: `-NoProfile -ExecutionPolicy Bypass -File "C:\Users\dustin.amweg\M122_Projektauftrag\Get-SkinPreis.ps1"`
   - Starten in: `C:\Users\dustin.amweg\M122_Projektauftrag`
6. Register **Einstellungen**: «Aufgabe so schnell wie möglich nach einem verpassten Start ausführen» aktivieren.
7. Mit «OK» speichern.

**Kontrolle:** Aufgabe markieren und mit «Ausführen» starten. Danach muss unter «Letztes Ausführungsergebnis» `0x0` stehen, im Ordner `logs` ein neuer Eintrag und im Ordner `berichte` ein neuer Bericht erscheinen.

Die Pfade im Skript werden über `$PSScriptRoot` gebildet, deshalb funktioniert der Start auch aus der Aufgabenplanung heraus. Die Pfade unter «Argumente» und «Starten in» müssen an den eigenen Speicherort angepasst werden.

## Ablauf des Skripts

| Schritt | Aufgabe |
|---|---|
| 1 | Logging vorbereiten (`Write-Log`, `Stop-Skript`) |
| 2 | `config.json` lesen und prüfen |
| 3 | Inventar über die Steam-Inventar-API laden |
| 4 | Skins zusammenfassen und zählen |
| 5 | Hilfsfunktionen `ConvertTo-Preis` und `Get-Preis` |
| 6 | Preise aller Skins abfragen, Wert = Preis × Anzahl |
| 6b | Letzten bekannten Preis aus `preisverlauf.csv` laden, Veränderung berechnen |
| 7 | Neue Preise an `preisverlauf.csv` anhängen |
| 8 | Übersicht in der Konsole ausgeben |
| 9 | Alte Berichte archivieren, neuen HTML-Bericht erstellen |

## Fehlerbehandlung und Exit-Codes

Jeder Schritt wird mit Zeitstempel und Stufe (INFO, WARN, FEHLER) in `logs/<Datum>.log` geschrieben. Bei einem Fehler bricht das Skript mit einem definierten Exit-Code ab.

| Exit-Code | Bedeutung | Beispiele |
|---|---|---|
| `0` | Erfolgreich beendet | Bericht erstellt; oder keine Skins gefunden (Warnung) |
| `1` | Fehler in der Config | Datei fehlt, ungültiges JSON, falsche SteamID64 |
| `2` | Fehler beim Laden des Inventars | Kein Internet, HTTP 403 (privat), 404, 429 |
| `3` | Fehler bei der Preisabfrage | 5 Skins in Folge ohne Erfolg oder kein einziger Preis |
| `4` | Fehler beim Speichern des Berichts | Keine Schreibrechte, Datenträger voll |

Bei HTTP 429 (zu viele Anfragen) wartet das Skript 60 Sekunden und versucht es erneut. Einzelne Skins ohne Preis führen nur zu einer Warnung im Log.

## Schnittstellen

| Schnittstelle | Zweck | Endpunkt |
|---|---|---|
| Steam-Inventar-API | CS2-Items des Kontos auslesen | `https://steamcommunity.com/inventory/<SteamID64>/730/2` |
| Steam-Market-API | Aktueller Tiefst- und Medianpreis in CHF | `https://steamcommunity.com/market/priceoverview/?appid=730&currency=4&market_hash_name=<Name>` |
| Steam-Bildserver | Skinbilder im HTML-Bericht | `https://<bildServer>/economy/image/<icon_url>/96fx96f` |

## Tests

| Nr. | Datum | Testfall | Ergebnis | Status |
|---|---|---|---|---|
| T01 | 30.10.2026 | Inventar-API manuell abfragen | 226 Items erhalten | ✅ OK |
| T02 | 30.10.2026 | Market-API für einen Skin abfragen | CHF 0.25, Volumen 266 | ✅ OK |
| T03 | 30.10.2026 | Skript mit gültiger Config starten | «Config geladen» | ✅ OK |
| T04 | 30.10.2026 | Inventar laden und Skins zählen | Liste mit Skin und Anzahl | ✅ OK |
| T05 | 30.10.2026 | Preisabfrage im Testmodus | Preise, Gesamtwert, Exit-Code 0 | ✅ OK |
| T06 | 30.10.2026 | Vollständiger Lauf, Preisverlauf schreiben | 118 von 138 Skins mit Preis, CHF 154.29 | ✅ OK |
| T07 | 02.11.2026 | Vergleich mit letztem Lauf | Veränderung im Bericht angezeigt | ✅ OK |
| T08 | 11.11.2026 | Falsche Config: SteamID64 mit 16 Ziffern | «Invalid SteamID64», Exit-Code 1 | ✅ OK |
| T09 | – | Schnittstelle nicht erreichbar: falsche SteamID64 | Erwartet: HTTP 404, Exit-Code 2 | ⏳ offen |
| T10 | 11.11.2026 | Kein Netz: WLAN ausgeschaltet | «Error loading inventory», Exit-Code 2 | ✅ OK |
| T11 | 11.11.2026 | Automatischer Start über die Aufgabenplanung | Erwartet: Ergebnis 0x0, neuer Log und Bericht | ⏳ offen |

Das vollständige Testprotokoll mit Nachweisen (Screenshots der Konsole und der Logdateien) steht in der Projektdokumentation.

## Bekannte Einschränkungen

- Die Steam-Schnittstellen sind nicht offiziell dokumentiert und können sich ändern.
- Steam begrenzt die Anzahl Preisabfragen (ca. 20 pro Minute). Deshalb die Pause zwischen den Abfragen.
- Der Filter `nurHandelbar` wird im aktuellen Skript noch nicht ausgewertet (Tippfehler `nurHandelbare` in Schritt 4). Deshalb werden auch Münzen, Medaillen, Abzeichen, Musik-Kits und Graffiti abgefragt. Sie haben keinen Marktpreis und erscheinen im Log als Warnung.
- Die Skinbilder im Bericht werden beim Öffnen vom Steam-Bildserver geladen und brauchen Internet.
- Es werden höchstens die ersten 500 Items des Inventars ausgewertet.
