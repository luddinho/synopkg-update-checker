# synopkg-update-checker

Prüft Synology DSM- oder BSM-Systemupdates sowie installierte Paket-Updates aus dem Synology-Archiv und unterstützten Community-Quellen.

Sprache: 🇩🇪 Deutsch | [🇬🇧 English](README.md)

## Überblick

Das Skript unterstützt aktuell:

- Betriebssystem-Prüfung für DSM oder BSM über das Synology-Archiv
- Paket-Update-Prüfung für:
  - offizielle Synology-Pakete
  - SynoCommunity-Pakete
  - GitHub-Releases, wenn der Paket-Distributor auf GitHub verweist
- interaktive Installation heruntergeladener Paket-Updates
- optionalen HTML-E-Mail-Bericht mit klickbaren Links und Quell-Badges
- Filter für laufende Pakete, offizielle Pakete, Community-Pakete sowie reine OS- oder Paketprüfungen

## Voraussetzungen

- Synology NAS mit DSM oder BSM
- erforderliche Befehle:
  - `curl`
  - `dmidecode`
  - `getopt`
  - `jq`
  - `synogetkeyvalue`
  - `synopkg`
  - `wget`
- für den E-Mail-Modus: `ssmtp`, `sendmail` oder `synodsmnotify`
- konfigurierte DSM-E-Mail-Benachrichtigung bei Nutzung von E-Mail-Reports
- root- oder sudo-Rechte empfohlen und für Paketinstallationen erforderlich

## Verwendung

```bash
./bin/synopkg-update-checker.sh [Optionen]
```

```text
Optionen:
  -i, --info          Nur System- und Update-Informationen anzeigen
  -e, --email         Bericht per E-Mail senden und automatisch den Info-Modus aktivieren
  --email-to <email>  Konfigurierten DSM-Empfänger überschreiben
  -r, --running       Nur aktuell laufende Pakete prüfen
  --official-only     Nur offizielle Synology-Pakete anzeigen
  --community-only    Nur Community- oder Drittanbieter-Pakete anzeigen
  --os-only           Nur nach Betriebssystem-Updates suchen
  --packages-only     Nur nach Paket-Updates suchen
  -n, --dry-run       Lauf simulieren, ohne Downloads oder Installation
  -v, --verbose       Reserviertes Flag, derzeit nicht implementiert
  -d, --debug         Detaillierte Debug-Ausgabe aktivieren
  -h, --help          Hilfe anzeigen
```

## Details zu den Optionen

| Option | Beschreibung |
| --- | --- |
| `-i`, `--info` | Zeigt nur den Bericht an. Keine Downloads und kein Installationsmenü. |
| `-e`, `--email` | Sendet den Bericht als HTML-E-Mail und aktiviert automatisch den Info-Modus. Es gibt dabei keine normale stdout-Ausgabe. |
| `--email-to <email>` | Verwendet einen benutzerdefinierten Empfänger statt der DSM-Konfiguration. |
| `-r`, `--running` | Begrenzt die Paketprüfung auf aktuell laufende Dienste. |
| `--official-only` | Zeigt nur offizielle Synology-Pakete. |
| `--community-only` | Zeigt nur Community- oder Drittanbieter-Pakete. Kann nicht mit `--official-only` kombiniert werden. |
| `--os-only` | Überspringt die Paketprüfung und meldet nur DSM- oder BSM-Updates. |
| `--packages-only` | Überspringt die OS-Prüfung und meldet nur Paket-Updates. Kann nicht mit `--os-only` kombiniert werden. |
| `-n`, `--dry-run` | Simuliert den Ablauf ohne Downloads oder Installationen. |
| `-d`, `--debug` | Zeigt zusätzliche interne Details und speichert im E-Mail-Modus eine lokale HTML-Kopie in `debug/`. |
| `-v`, `--verbose` | Ist in der CLI vorhanden, wird vom aktuellen Code aber noch nicht verwendet. |

## Update-Quellen und Erkennung

Die Paketquelle wird aus den Metadaten in `/var/packages/<paket>/INFO` ermittelt.

- **Offizielles Synology-Paket**
  - kein `distributor`-Feld, oder
  - `distributor="Synology Inc."`
- **GitHub-Paket**
  - der Distributor enthält eine GitHub-URL wie `https://github.com/<owner>/<repo>`
  - das Skript prüft das neueste GitHub-Release und sucht nach passenden `.spk`-Assets
- **Community-Paket**
  - jeder andere nicht-Synology-Distributor
  - SynoCommunity-Seiten werden direkt berücksichtigt, wenn passend

Für Paketdownloads verwendet das Skript jetzt den paket-spezifischen `arch`-Wert aus der INFO-Datei und zusätzlich den Plattformnamen des Systems, um das passendste SPK zu finden.

## E-Mail-Bericht

Im E-Mail-Modus wird ein HTML-Bericht mit formatierten Tabellen und visuellen Badges erstellt:

- 🏢 **OFFICIAL** für Synology-Pakete
- 👥 **COMMUNITY** für Community-Repositories
- 🐙 **GITHUB** für Pakete, die über GitHub-Releases geprüft werden
- 🔴 bedeutet: Update verfügbar
- 🟢 bedeutet: bereits aktuell

In der Terminalausgabe bleibt die Spalte **Update** bewusst schlicht:

- `X` = Update verfügbar
- `-` = kein Update

## Ablauf

1. Systeminformationen sammeln:
   - Produkt
   - Modell
   - Architektur
   - Plattformname
   - Betriebssystem
   - installierte Version

2. Betriebssystem-Updates prüfen:
   - Synology-Archiv abfragen
   - installierte und verfügbare Versionen vergleichen
   - Modell- oder Plattform-Kompatibilität prüfen
   - direkten `.pat`-Download-Link anzeigen, wenn ein Update existiert

3. Installierte Pakete prüfen:
   - installierte Pakete stabil alphabetisch auflisten
   - Paketquelle erkennen
   - aktive Filter wie running-only oder official-only anwenden
   - installierte und neueste Version vergleichen
   - passende Download-URLs für aktualisierbare Pakete sammeln

4. Im normalen Modus:
   - Paketdateien nach `downloads/packages/` herunterladen
   - interaktives Auswahlmenü anzeigen
   - gewählte Pakete nach Bestätigung installieren

5. Aufräumen:
   - temporäres Download-Verzeichnis nach dem Lauf entfernen

## Wichtige Hinweise und Einschränkungen

- OS-Updates werden **nur mit Download-Link gemeldet**. Das Skript installiert DSM- oder BSM-Updates aktuell nicht automatisch.
- Paketinstallationen erfordern eine Bestätigung und sollten mit passenden Rechten ausgeführt werden.
- `--email` benötigt funktionierende DSM-Mail-Einstellungen oder einen expliziten Empfänger über `--email-to`.
- Im Modus `--debug --email` wird eine Kopie des HTML-Reports als `debug/email_JJJJMMTT_HHMMSS.html` gespeichert.
- Wenn das Senden der E-Mail fehlschlägt, beendet sich das Skript mit einem Fehlercode.

## Beispiele

### Nur Bericht anzeigen

```bash
./bin/synopkg-update-checker.sh --info
```

### Bericht per E-Mail senden

```bash
./bin/synopkg-update-checker.sh --email
```

### Bericht an einen eigenen Empfänger senden

```bash
./bin/synopkg-update-checker.sh --email --email-to ihre@email.de
```

### Nur laufende offizielle Pakete prüfen

```bash
./bin/synopkg-update-checker.sh --info --running --official-only
```

### Nur Community- und GitHub-basierte Pakete prüfen

```bash
./bin/synopkg-update-checker.sh --info --community-only --packages-only
```

### Installationsablauf simulieren

```bash
./bin/synopkg-update-checker.sh --dry-run
```

### Verfügbare Paket-Updates herunterladen und installieren

```bash
sudo ./bin/synopkg-update-checker.sh
```

## Ausgabeverzeichnisse

```text
downloads/
├── os/
└── packages/

debug/
└── email_JJJJMMTT_HHMMSS.html
```

## DSM-E-Mail-Konfiguration

Für E-Mail-Reports muss die Synology-Benachrichtigung eingerichtet sein:

[Synology E-Mail-Benachrichtigungen konfigurieren](https://kb.synology.com/de-de/DSM/help/DSM/AdminCenter/system_notification_email?version=7)
