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
  -n, --dry-run       Testlauf ohne Herunterladen oder Installieren von Updates
  -h, --help          Diese Hilfemeldung anzeigen
```

### Optionen
1. Dry-run wird verwendet, um nur nach verfügbaren Updates zu suchen und das Upgrade-Verfahren zu simulieren. Es werden keine Dateien heruntergeladen und es besteht keine Möglichkeit, Pakete versehentlich zu installieren.

### Einschränkungen
Betriebssystem-Updates z.B. für DSM werden nur gemeldet, da der Befehl ```sudo synoupgrade --patch /pfad/zur/datei.pat``` nicht funktioniert.

### Arbeitsablauf
1. Systeminformationen werden ausgewertet
- Produkt
- Modell
- Architektur
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
     - Prüft auf Updates über `synopkg checkupdate`
     - Falls kein Update über synopkg gefunden wird, wird der Synology Archiv-Server abgefragt
     - Überprüft Architektur- und OS-Kompatibilität
   - Zeigt Ergebnisse in einer Tabelle mit Spalten:
     - Paketname
     - Installierte Version
     - Neueste Version
     - Update verfügbar (X oder -)
     - SPK-Dateiname
   - Erstellt eine Liste von Paketen mit verfügbaren Updates

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

### Nach Updates suchen (Dry-run-Modus)
```bash
./bin/synopkg-update-checker.sh --dry-run
```
Dies wird:
- Systeminformationen anzeigen
- Nach OS- und Paket-Updates suchen
- Verfügbare Updates anzeigen, ohne etwas herunterzuladen oder zu installieren

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

## Beispielausgabe

### Keine Updates verfügbar
```
./bin/synopkg-update-checker.sh

System Information
=============================================
Product                        | DiskStation
Model                          | DS1817+
Architecture                   | x86_64
Operating System               | DSM
DSM Version                    | 7.3.2-86009

Operating System Update Check
=============================================

Operating System               | Installed       | Latest Version       | Update Available     | pat
-------------------------------|-----------------|----------------------|----------------------|--------------------
DSM                            | 7.3.2-86009     | 7.3.2-86009          | -                    |

Package Update Check
=============================================

Package                        | Installed       | Latest Version       | Update Available     | spk
-------------------------------|-----------------|----------------------|----------------------|--------------------
ActiveInsight                  | 3.0.5-24122     | 3.0.5-24122          | -                    |
Apache2.4                      | 2.4.63-0155     | 2.4.63-0155          | -                    |
MariaDB10                      | 10.11.11-1551   | 10.11.11-1551        | -                    |
SynologyDrive                  | 4.0.2-27889     | 4.0.2-27889          | -                    |
SynologyPhotos                 | 1.8.2-10090     | 1.8.2-10090          | -                    |

No packages to update. Exiting.
```

### Zwei Updates verfügbar
```
./bin/synopkg-update-checker.sh

System Information
=============================================
Product                        | DiskStation
Model                          | DS1817+
Architecture                   | x86_64
Operating System               | DSM
DSM Version                    | 7.3.2-86009

Operating System Update Check
=============================================

Operating System               | Installed       | Latest Version       | Update Available     | pat
-------------------------------|-----------------|----------------------|----------------------|--------------------
DSM                            | 7.3.2-86009     | 7.3.2-86009          | -                    |

Package Update Check
=============================================

Package                        | Installed       | Latest Version       | Update Available     | spk
-------------------------------|-----------------|----------------------|----------------------|--------------------
MariaDB10                      | 10.11.11-1551   | 10.11.12-1552        | X                    | MariaDB10-x86_64-10.11.12-1552.spk
SynologyDrive                  | 4.0.2-27889     | 4.0.3-27900          | X                    | SynologyDrive-x86_64-4.0.3-27900.spk
SynologyPhotos                 | 1.8.2-10090     | 1.8.2-10090          | -                    |

Download Links for Available Updates:
=============================================

Application                    | Version         | URL
------------------------------ | --------------- | --------------------------------------------------
MariaDB10                      | 10.11.12-1552   | https://archive.synology.com/download/Package/spk/MariaDB10-x86_64-10.11.12-1552.spk
SynologyDrive                  | 4.0.3-27900     | https://archive.synology.com/download/Package/spk/SynologyDrive-x86_64-4.0.3-27900.spk

Downloading updateable packages
=============================================

Downloading MariaDB10-x86_64-10.11.12-1552.spk...
Package: MariaDB10
File: MariaDB10-x86_64-10.11.12-1552.spk
Path: /path/to/downloads/packages/MariaDB10-x86_64-10.11.12-1552.spk

Downloading SynologyDrive-x86_64-4.0.3-27900.spk...
Package: SynologyDrive
File: SynologyDrive-x86_64-4.0.3-27900.spk
Path: /path/to/downloads/packages/SynologyDrive-x86_64-4.0.3-27900.spk

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
```

**Hinweis:** Betriebssystem-Update-Dateien (`.pat`) werden aufgrund von Installationseinschränkungen nicht heruntergeladen.

## Hinweise
- OS-Updates werden nur mit Download-Links gemeldet. Die Installation muss manuell über die DSM-Oberfläche durchgeführt werden
- Paket-Installationen erfordern Benutzerbestätigung
- Alle Downloads werden nach Abschluss des Skripts automatisch aufgeräumt
- Verwenden Sie `--dry-run` für sicheres Testen ohne Änderung Ihres Systems
