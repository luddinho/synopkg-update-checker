# synology-update-check
Check for Synology DSM and package updates from the Synology archive server

**[🇩🇪 Deutsche Version](README.de.md)**

## Requirements
- Synology NAS with DSM or BSM operating system
- Required commands: `dmidecode`, `curl`, `synopkg`, `synogetkeyvalue`, `wget`
- Root/sudo access for system operations

## Usage
```bash
Usage: ./synology-update-check.sh [options]
Options:
  -n, --dry-run       Perform a dry run without downloading or installing updates
  -h, --help          Display this help message
```

### Options
1. Dry run is used to check only for available updates and simulate the upgrade procedure. No files will be downloaded and no possibility to install packages by mistake.

### Restrictions
Operating system updates e.g. for DSM will only reported because the command ```sudo synoupgrade --patch /path/to/file.pat``` does not work.

### Workflow
1. System information is evaluated
- Product
- Model
- Architecture
- Operating System
- Version

2. With the system information the Synology archive server will be parsed dependent on the installed OS version and the packages to identify available updates.

3. Operating System Update Check
   - Fetches available OS versions from `https://archive.synology.com/download/Os/<OS_NAME>`
   - Compares installed version with available versions
   - Checks for model compatibility
   - Displays update availability in a table format
   - If an OS update is available:
     - Shows download link for the `.pat` file
     - Downloads the file (unless `--dry-run` is enabled)
     - **Note:** OS updates are only reported and downloaded. Installation must be done manually as `synoupgrade --patch` is not supported.

4. Package Update Check
   - Iterates through all installed packages using `synopkg list`
   - For each package:
     - Checks for updates via `synopkg checkupdate`
     - If no update found via synopkg, queries the Synology archive server
     - Verifies architecture and OS compatibility
   - Displays results in a table with columns:
     - Package name
     - Installed version
     - Latest version
     - Update available (X or -)
     - SPK filename
   - Creates a list of packages with available updates

5. Package Download
   - Downloads all available package updates (`.spk` files) to `downloads/packages/` directory
   - Skips download in `--dry-run` mode
   - Shows progress for each download

6. Interactive Package Installation
   - Presents an interactive menu with available packages to update
   - Options:
     - Select individual packages by number
     - Select `all` to process all packages
     - Select `quit` to exit without installing
   - For each selected package:
     - Prompts for confirmation before installation
     - Installs using `synopkg install <file>` (unless `--dry-run` is enabled)
     - Reports success or error status
   - Continues until all packages are processed or user quits

7. Cleanup
   - Removes the `downloads/` directory and all downloaded files after installation

## Examples

### Check for updates (dry-run mode)
```bash
./bin/synology-update-check.sh --dry-run
```
This will:
- Display system information
- Check for OS and package updates
- Show available updates without downloading or installing anything

### Check and install updates
```bash
sudo ./bin/synology-update-check.sh
```
This will:
- Display system information
- Check for OS and package updates
- Download available updates
- Present an interactive menu to select packages for installation
- Install selected packages after confirmation

## Output Example

### No updates available
```
./bin/synology-update-check.sh

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

### Two updates available
```
./bin/synology-update-check.sh

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

## Output Structure
```
downloads/
└── packages/    # Package .spk files
```

**Note:** OS update files (`.pat`) are not downloaded due to installation restrictions.

## Notes
- OS updates are only reported with download links. Installation must be done manually through DSM interface
- Package installations require user confirmation
- All downloads are cleaned up automatically after the script completes
- Use `--dry-run` for safe testing without modifying your system