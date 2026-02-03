# synopkg-update-checker
Prüfen auf Synology DSM und Paket-Updates vom Synology Archiv-Server

**[🇬🇧 English Version](README.md)**

## Voraussetzungen
- Synology NAS mit DSM oder BSM Betriebssystem
- Erforderliche Befehle: `dmidecode`, `curl`, `synopkg`, `synogetkeyvalue`, `wget`
- Root/sudo-Zugriff für Systemoperationen

## Verwendung
```bash
Verwendung: ./synopkg-update-checker.sh [Optionen]
Optionen:
  -i, --info          Nur System- und Update-Informationen anzeigen,
                      wie Dry-run aber ohne Download-Meldungen und interaktive Installation
  -e, --email         E-Mail-Modus - keine Ausgabe auf stdout, nur Bericht per E-Mail senden (erfordert --info)
  --email-to <email>  Empfänger-E-Mail-Adresse überschreiben (optional, Standard ist DSM-Konfiguration)
  -r, --running       Updates nur für Pakete prüfen, die aktuell laufen
  --official-only     Nur offizielle Synology-Pakete anzeigen
  --community-only    Nur Community-/Drittanbieter-Pakete anzeigen
  --os-only           Nur nach Betriebssystem-Updates prüfen
  --packages-only     Nur nach Paket-Updates prüfen
  -n, --dry-run       Testlauf ohne Herunterladen oder Installieren von Updates
  -v, --verbose       Ausführliche Ausgabe aktivieren (nicht implementiert)
  -d, --debug         Debug-Modus aktivieren
  -h, --help          Diese Hilfemeldung anzeigen
```

### Optionen
1. **Info-Modus** (`-i, --info`): Zeigt System- und Update-Informationen ohne Herunterladen oder Installieren. Perfekt für schnelle Überprüfungen oder automatisierte Überwachung.
2. **E-Mail-Modus** (`-e, --email`): Sendet Update-Bericht per E-Mail mit professioneller HTML-Formatierung:
   - **Gestylte HTML-Tabellen** mit farbcodierten Überschriften:
     - Systeminformationen: Grüne Überschrift
     - Betriebssystem: Hellblaue Überschrift
     - Pakete: Orange Überschrift
   - **Paketquellen-Badges**: 🏢 OFFICIAL (blau) oder 👥 COMMUNITY (lila) mit Quellennamen
   - **Visuelle Indikatoren**: 🔄 Emoji für verfügbare Updates, ✅ Emoji für keine Updates
   - **Statusmeldungen mit Farbcodierung**:
     - Dunkelgrün (#228B22) mit ✅ Emoji wenn keine Updates verfügbar sind
     - Rot (#FF0000) mit ⚠️ Emoji wenn Updates verfügbar sind
   - **Anklickbare Download-Links**: Versionsnummern werden zu klickbaren Links, wenn Updates verfügbar sind
   - **Zusammenfassungsstatistiken**: Gesamtzahl installierter Pakete und Pakete mit Updates
   - Erfordert E-Mail-Konfiguration in DSM (Systemsteuerung > Benachrichtigung > E-Mail)
   - **Optional**: Verwenden Sie `--email-to <email>`, um den Empfänger zu überschreiben, ohne die DSM-Einstellungen zu ändern
3. **Nur laufende** (`-r, --running`): Prüft Updates nur für Pakete, die aktuell laufen. Gestoppte Pakete werden übersprungen. Nützlich für die Konzentration auf aktive Dienste. Paketzähler zeigt nur laufende Pakete, wenn mit diesem Filter kombiniert.
4. **Nur offiziell** (`--official-only`): Zeigt nur offizielle Synology-Pakete. Community-/Drittanbieter-Pakete werden herausgefiltert. Paketzähler zeigt nur offizielle Pakete.
5. **Nur Community** (`--community-only`): Zeigt nur Community-/Drittanbieter-Pakete (z.B. von SynoCommunity). Offizielle Synology-Pakete werden herausgefiltert. Paketzähler zeigt nur Community-Pakete. Kann nicht mit `--official-only` verwendet werden.
6. **Nur Betriebssystem** (`--os-only`): Prüft nur nach Betriebssystem-Updates. Paket-Update-Prüfung wird übersprungen. Kann nicht mit `--packages-only` verwendet werden.
7. **Nur Pakete** (`--packages-only`): Prüft nur nach Paket-Updates. Betriebssystem-Update-Prüfung wird übersprungen. Kann nicht mit `--os-only` verwendet werden.
8. **Dry-run-Modus** (`-n, --dry-run`): Prüft auf Updates und simuliert das Upgrade-Verfahren ohne Herunterladen oder Installieren. Interaktives Menü wird weiterhin angezeigt. Alle Operationen werden mit **[DRY RUN MODE]** Indikator gekennzeichnet.
9. **Debug-Modus** (`-d, --debug`): Aktiviert detaillierte Debug-Ausgabe zur Fehlersuche:
   - Paketquellen-Erkennung (distributor-Feld)
   - Server-URLs, die abgefragt werden (Synology-Archiv oder Community-Repositorys)
   - Versionsvergleichslogik und Matching-Prozess
   - In Kombination mit E-Mail-Modus (`-d -e`) wird eine Kopie der HTML-E-Mail in `debug/email_JJJJMMTT_HHMMSS.html` zur Inspektion gespeichert.

### Einschränkungen
Betriebssystem-Updates z.B. für DSM werden nur gemeldet, da der Befehl ```sudo synoupgrade --patch /pfad/zur/datei.pat``` nicht funktioniert.

### Arbeitsablauf
1. Systeminformationen werden ausgewertet
- Produkt
- Modell
- Architektur
- Plattformname (CPU-Codename wie avoton, apollolake, usw.)
- Betriebssystem
- Version

2. Mit den Systeminformationen wird der Synology Archiv-Server in Abhängigkeit von der installierten OS-Version und den Paketen nach verfügbaren Updates durchsucht.

3. Betriebssystem-Update-Prüfung
   - Ruft verfügbare OS-Versionen von `https://archive.synology.com/download/Os/<OS_NAME>` ab
   - Vergleicht installierte Version mit verfügbaren Versionen
   - Prüft Modell-Kompatibilität
   - Zeigt Update-Verfügbarkeit in Tabellenformat an
   - Falls ein OS-Update verfügbar ist:
     - Zeigt Download-Link für die `.pat`-Datei an
     - Lädt die Datei herunter (außer `--dry-run` ist aktiviert)
     - **Hinweis:** OS-Updates werden nur gemeldet und heruntergeladen. Die Installation muss manuell durchgeführt werden, da `synoupgrade --patch` nicht unterstützt wird.

4. Paket-Update-Prüfung
   - Iteriert durch alle installierten Pakete mit `synopkg list`
   - Für jedes Paket:
     - Erkennt Paketquelle automatisch durch Prüfung des `distributor`-Feldes in `/var/packages/<paket>/INFO`:
       - Kein distributor-Feld oder `distributor="Synology Inc."`: Offizielles Synology-Paket
       - Anderer Distributor (z.B. `SynoCommunity`): Community-/Drittanbieter-Paket
     - Wendet Filteroptionen (`--official-only`, `--community-only`, `--running`) an, falls angegeben
     - Für offizielle Pakete: Fragt nur Synology-Archiv-Server ab
     - Für Community-Pakete: Fragt Community-Repository direkt ab (z.B. SynoCommunity) mit der `distributor_url` aus der INFO-Datei
     - Überprüft Architektur- und OS-Kompatibilität
   - Zeigt Ergebnisse in einer Tabelle mit Spalten:
     - Paketname
     - Quelle (Distributor/Maintainer mit Badge im E-Mail-Modus)
     - Installierte Version
     - Neueste Version
     - Update verfügbar (X oder -)
   - Erstellt eine Liste von Paketen mit verfügbaren Updates
   - Paketzähler berücksichtigt aktive Filter

5. Paket-Download
   - Lädt alle verfügbaren Paket-Updates (`.spk`-Dateien) in das Verzeichnis `downloads/packages/` herunter
   - Überspringt Download im `--dry-run`-Modus
   - Zeigt Fortschritt für jeden Download an

6. Interaktive Paket-Installation
   - Zeigt ein interaktives Menü mit verfügbaren Paketen zum Aktualisieren an
   - Optionen:
     - Einzelne Pakete nach Nummer auswählen
     - `all` wählen, um alle Pakete zu verarbeiten
     - `quit` wählen, um ohne Installation zu beenden
   - Für jedes ausgewählte Paket:
     - Fordert Bestätigung vor der Installation an
     - Installiert mit `synopkg install <datei>` (außer `--dry-run` ist aktiviert)
     - Meldet Erfolg oder Fehlerstatus
   - Fortsetzung bis alle Pakete verarbeitet sind oder Benutzer beendet

7. Aufräumen
   - Entfernt das Verzeichnis `downloads/` und alle heruntergeladenen Dateien nach der Installation

## Beispiele

### Nach Updates suchen (Info-Modus)
```bash
./bin/synopkg-update-checker.sh --info
```
Dies wird:
- Systeminformationen anzeigen
- Nach OS- und Paket-Updates suchen
- Verfügbare Updates anzeigen, ohne etwas herunterzuladen oder zu installieren
- Nach Anzeige der Informationen beenden (kein interaktives Menü)

### Nach Updates suchen und per E-Mail benachrichtigen
```bash
./bin/synopkg-update-checker.sh --email
```
Dies wird:
- Nach OS- und Paket-Updates suchen
- Einen HTML-formatierten E-Mail-Bericht senden mit:
  - Systeminformationen
  - Update-Verfügbarkeitstabellen
  - Anklickbaren Download-Links (verkürzt mit App-Namen)
- Erfordert E-Mail-Konfiguration in DSM (siehe [Konfiguration E-Mail Benachrichtigung])

**Alternative:** Empfänger-E-Mail-Adresse überschreiben, ohne DSM-Einstellungen zu ändern:
```bash
./bin/synopkg-update-checker.sh --email --email-to ihre@email.de
```

[Konfiguration E-Mail Benachrichtigung]: https://kb.synology.com/de-de/DSM/help/DSM/AdminCenter/system_notification_email?version=7

### Nach Updates suchen (Dry-run-Modus)
```bash
./bin/synopkg-update-checker.sh --dry-run
```
Dies wird:
- Systeminformationen anzeigen
- Nach OS- und Paket-Updates suchen
- Verfügbare Updates anzeigen
- Interaktives Menü anzeigen, aber tatsächliche Downloads und Installationen überspringen

### Updates suchen und installieren
```bash
sudo ./bin/synopkg-update-checker.sh
```
Dies wird:
- Systeminformationen anzeigen
- Nach OS- und Paket-Updates suchen
- Verfügbare Updates herunterladen
- Ein interaktives Menü zur Auswahl der zu installierenden Pakete anzeigen
- Ausgewählte Pakete nach Bestätigung installieren

### Debug-Modus
```bash
./bin/synopkg-update-checker.sh --debug
```
Aktiviert detaillierte Debug-Ausgabe mit:
- Versionsvergleichslogik
- .pat-Datei-Matching-Prozess
- URL-Extraktionsdetails

## Beispielausgabe

### Keine Updates verfügbar
```
./bin/synopkg-update-checker.sh

System Information
=============================================================================================================
Product                                                         | DiskStation
Model                                                           | DS1817+
Architecture                                                    | x86_64
Operating System                                                | DSM
DSM Version                                                     | 7.3.2-86009

Operating System Update Check
=============================================================================================================

Operating System                                                | Installed       | Latest          | Update
----------------------------------------------------------------|-----------------|-----------------|--------
DSM                                                             | 7.3.2-86009     | 7.3.2-86009     | -

No operating system updates available. System is up to date.

Package Update Check
=============================================================================================================

Package                        | Source                         | Installed       | Latest          | Update
-------------------------------|--------------------------------|-----------------|-----------------|--------
ActiveInsight                  | Synology Inc.                  | 3.0.5-24122     | 3.0.5-24122     | -
Apache2.4                      | Synology Inc.                  | 2.4.63-0155     | 2.4.63-0155     | -
MariaDB10                      | Synology Inc.                  | 10.11.11-1551   | 10.11.11-1551   | -
SynologyDrive                  | Synology Inc.                  | 4.0.2-27889     | 4.0.2-27889     | -
SynologyPhotos                 | Synology Inc.                  | 1.8.2-10090     | 1.8.2-10090     | -

No package updates available. All packages are up to date.

Total installed packages: 5

No packages to update. Exiting.
```

### Zwei Updates verfügbar
```
./bin/synopkg-update-checker.sh

System Information
=============================================================================================================
Product                                                         | DiskStation
Model                                                           | DS1817+
Architecture                                                    | x86_64
Operating System                                                | DSM
DSM Version                                                     | 7.3.2-86009

Operating System Update Check
=============================================================================================================

Operating System                                                | Installed       | Latest          | Update
----------------------------------------------------------------|-----------------|-----------------|--------
DSM                                                             | 7.3.2-86009     | 7.3.2-86009     | -

No operating system updates available. System is up to date.

Package Update Check
=============================================================================================================

Package                        | Source                         | Installed       | Latest          | Update
-------------------------------|--------------------------------|-----------------|-----------------|--------
MariaDB10                      | Synology Inc.                  | 10.11.11-1551   | 10.11.12-1552   | X
SynologyDrive                  | Synology Inc.                  | 4.0.2-27889     | 4.0.3-27900     | X
SynologyPhotos                 | Synology Inc.                  | 1.8.2-10090     | 1.8.2-10090     | -

*** PACKAGE UPDATES AVAILABLE ***

Download Links for Available Updates:
=============================================================================================================

Application                    | Version         | URL
------------------------------ | --------------- | --------------------------------------------------
MariaDB10                      | 10.11.12-1552   | https://archive.synology.com/download/Package/spk/MariaDB10-x86_64-10.11.12-1552.spk
SynologyDrive                  | 4.0.3-27900     | https://archive.synology.com/download/Package/spk/SynologyDrive-x86_64-4.0.3-27900.spk

Downloading updateable packages
=============================================================================================================

Downloading MariaDB10-x86_64-10.11.12-1552.spk...
Package: MariaDB10
File: MariaDB10-x86_64-10.11.12-1552.spk
Path: /path/to/downloads/packages/MariaDB10-x86_64-10.11.12-1552.spk

Downloading SynologyDrive-x86_64-4.0.3-27900.spk...
Package: SynologyDrive
File: SynologyDrive-x86_64-4.0.3-27900.spk
Path: /path/to/downloads/packages/SynologyDrive-x86_64-4.0.3-27900.spk

Total installed packages: 5
Total packages with updates available: 2

Select packages to update:
==========================

1) MariaDB10
2) SynologyDrive
3) all
4) quit
Select the operation: 1

You selected to update package: MariaDB10
Are you sure you want to update this package? (y/n): y
Installing package from file: /path/to/downloads/packages/MariaDB10-x86_64-10.11.12-1552.spk

Package MariaDB10 installed successfully.

Select packages to update:
==========================

1) SynologyDrive
2) all
3) quit
Select the operation: 1

You selected to update package: SynologyDrive
Are you sure you want to update this package? (y/n): n
Installation cancelled by user.
Starting over selection.

Select packages to update:
==========================

1) SynologyDrive
2) all
3) quit
Select the operation: 2

You selected to update all packages.
Are you sure you want to update this package? (y/n): y
Installing package from file: /path/to/downloads/packages/SynologyDrive-x86_64-4.0.3-27900.spk

Package SynologyDrive installed successfully.

All packages processed. Exiting.
```

## Ausgabestruktur
```
downloads/
└── packages/    # Paket .spk-Dateien

debug/           # HTML-E-Mail-Debug-Dateien (bei Verwendung der -d -e Flags)
└── email_JJJJMMTT_HHMMSS.html
```

**Hinweis:** Betriebssystem-Update-Dateien (`.pat`) werden aufgrund von Installationseinschränkungen nicht heruntergeladen.

## Hinweise
- OS-Updates werden nur mit Download-Links gemeldet. Die Installation muss manuell über die DSM-Oberfläche durchgeführt werden
- Paket-Installationen erfordern Benutzerbestätigung
- Alle Downloads werden nach Abschluss des Skripts automatisch aufgeräumt
- Verwenden Sie `--dry-run` für sicheres Testen ohne Änderung Ihres Systems
