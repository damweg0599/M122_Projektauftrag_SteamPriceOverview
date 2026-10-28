# Projektantrag M122 – CS2-Skin-Preisübersicht

**Projektmitarbeiter:** Dustin Amweg (Einzelarbeit)

## Ausgangslage

Wer CS2-Skins besitzt, muss die Preise auf dem Steam Community Market heute für jeden Skin einzeln von Hand nachschauen. Dadurch fehlt der Überblick, wie viel das eigene Inventar wert ist und ob ein Preis gerade hoch oder tief ist. Das Projekt richtet sich an mich und andere CS2-Spieler mit eigenem Inventar.

## Ziel (SMART)

Bis am **04.11.2026** liest das Skript einmal täglich automatisch alle handelbaren CS2-Skins aus meinem Steam-Konto aus, ermittelt für jeden Skin den aktuellen Preis in CHF, zeigt die Veränderung zum letzten Lauf in CHF und Prozent sowie den Gesamtwert des Inventars an und meldet Fehler per Log und Exit-Code.

## Umfang

**Dazu gehört:**

- Config-Datei `config.json` mit SteamID64, Währung, Pause zwischen den Abfragen und Ausgabepfaden
- Auslesen des Inventars über die Steam-Inventar-API (nur handelbare Skins, Duplikate werden gezählt)
- Abfrage der aktuellen Preise über die Steam-Market-API
- Speichern der Preise in `preisverlauf.csv`
- Vergleich mit dem letzten Lauf: Veränderung in CHF und Prozent (▲ / ▼)
- Übersicht in der Konsole und als HTML-Bericht mit Gesamtwert
- Log und Exit-Codes bei Fehlern (z. B. Inventar privat, kein Netz, zu viele Anfragen)
- Automatischer Start über die Windows-Aufgabenplanung (1× täglich)
- Code, Dokumentation und Testprotokoll im GitHub-Repository

**Optional:**

- Preisverlauf als Diagramm im HTML-Bericht
- Push-Nachricht über ntfy.sh bei starken Preisänderungen

## Zeit


Abgabe: **04.11.2026**

## Schnittstellen

| Schnittstelle | Zweck | Endpunkt |
|---|---|---|
| Steam-Inventar-API | CS2-Items des Kontos auslesen | `https://steamcommunity.com/inventory/<SteamID64>/730/2` |
| Steam-Market-API | Aktueller Tiefst- und Medianpreis in CHF | `https://steamcommunity.com/market/priceoverview/?appid=730&currency=4&market_hash_name=<Name>` |
| ntfy.sh *(optional)* | Push-Nachricht aufs Handy | `https://ntfy.sh/<Topic>` |

Voraussetzung: Das Steam-Inventar ist auf «öffentlich» gestellt.

## Grober Ablauf

1. Das Skript wird über die Windows-Aufgabenplanung gestartet.
2. Es liest die Einstellungen aus `config.json` und prüft sie.
3. Es lädt das Inventar über die Steam-Inventar-API und behält nur handelbare Skins.
4. Für jeden Skin fragt es den aktuellen Preis über die Steam-Market-API ab (mit Pause zwischen den Abfragen).
5. Es speichert die Preise mit Datum in `preisverlauf.csv`.
6. Es vergleicht die Preise mit dem letzten Lauf und berechnet Veränderung und Gesamtwert.
7. Es gibt die Übersicht in der Konsole und als HTML-Bericht aus.
8. Erfolg oder Fehler werden ins Log geschrieben, das Skript endet mit dem passenden Exit-Code.