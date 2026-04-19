# synopkg-update-checker

Check Synology DSM or BSM system updates and installed package updates from the Synology archive and supported community sources.

Language: 🇬🇧 English | [🇩🇪 Deutsch](README.de.md)

## Overview

This script currently supports:

- DSM or BSM operating system update checks via the Synology archive
- package update checks for:
  - official Synology packages
  - SynoCommunity packages
  - GitHub releases when a package distributor points to GitHub
- interactive installation of downloaded package updates
- optional HTML email reporting with clickable links and source badges
- filters for running packages, official packages, community packages, OS-only, or packages-only checks

## Requirements

- Synology NAS running DSM or BSM
- required commands:
  - `curl`
  - `dmidecode`
  - `getopt`
  - `jq`
  - `synogetkeyvalue`
  - `synopkg`
  - `wget`
- for email mode: `ssmtp`, `sendmail`, or `synodsmnotify`
- DSM email notification settings configured when using email reports
- root or sudo privileges recommended, and required for package installation

## Usage

```bash
./bin/synopkg-update-checker.sh [options]
```

```text
Options:
  -i, --info          Display system and update information only
  -e, --email         Send the report by email and automatically enable info mode
  --email-to <email>  Override the configured DSM recipient address
  -r, --running       Check updates only for currently running packages
  --official-only     Show only official Synology packages
  --community-only    Show only community or third-party packages
  --os-only           Check only for operating system updates
  --packages-only     Check only for package updates
  -n, --dry-run       Simulate actions without downloading or installing
  -v, --verbose       Reserved flag, currently not implemented
  -d, --debug         Enable detailed debug output
  -h, --help          Show help
```

## Option details

| Option | Description |
| --- | --- |
| `-i`, `--info` | Prints a report only. No downloads and no installation menu. |
| `-e`, `--email` | Sends the report as HTML email and automatically switches to info mode. No normal stdout report is produced. |
| `--email-to <email>` | Uses a custom recipient instead of the DSM notification configuration. |
| `-r`, `--running` | Limits package checks to services that are currently running. |
| `--official-only` | Shows only official Synology packages. |
| `--community-only` | Shows only community or third-party packages. Cannot be combined with `--official-only`. |
| `--os-only` | Skips package checks and only reports DSM or BSM updates. |
| `--packages-only` | Skips OS checks and only reports package updates. Cannot be combined with `--os-only`. |
| `-n`, `--dry-run` | Simulates the run without downloading or installing any package. |
| `-d`, `--debug` | Shows additional internal details and, in email mode, stores a local HTML copy in `debug/`. |
| `-v`, `--verbose` | Present in the CLI, but not used by the current code yet. |

## Update sources and detection

The script identifies package sources from the package INFO metadata in `/var/packages/<package>/INFO`.

- **Official Synology package**
  - no `distributor` field, or
  - `distributor="Synology Inc."`
- **GitHub package**
  - the distributor contains a GitHub URL such as `https://github.com/<owner>/<repo>`
  - the script checks the latest GitHub release and looks for matching `.spk` assets
- **Community package**
  - any other non-Synology distributor
  - SynoCommunity pages are checked directly when applicable

For package downloads, the script now uses the package-specific `arch` value from each package INFO file, plus the system platform name, to find the best matching SPK file.

## Email report formatting

When email mode is used, the report contains styled HTML tables and visual badges:

- 🏢 **OFFICIAL** for Synology packages
- 👥 **COMMUNITY** for community repositories
- 🐙 **GITHUB** for packages tracked from GitHub releases
- 🔴 means an update is available
- 🟢 means the installed item is already up to date

The terminal table still uses simple values in the **Update** column:

- `X` = update available
- `-` = no update

## Workflow

1. Collect system information:
   - product
   - model
   - architecture
   - platform name
   - operating system
   - installed version

2. Check operating system updates:
   - query the Synology archive
   - compare installed and available versions
   - verify model or platform compatibility
   - show a direct `.pat` download link when an update exists

3. Check installed packages:
   - list installed packages in stable alphabetical order
   - detect each package source
   - apply active filters such as running-only or official-only
   - compare installed and latest versions
   - collect matching download URLs for updateable packages

4. In normal mode:
   - download package files to `downloads/packages/`
   - present an interactive selection menu
   - install chosen packages with confirmation

5. Cleanup:
   - remove the temporary download directory when the run is finished

## Important notes and limitations

- OS updates are **reported with download links only**. The current script does not install DSM or BSM updates automatically.
- Package installation requires confirmation and should be run with appropriate privileges.
- `--email` depends on DSM mail settings or an explicit `--email-to` override.
- In `--debug --email` mode, a copy of the generated HTML report is saved as `debug/email_YYYYMMDD_HHMMSS.html`.
- If sending the email fails, the script exits with an error.

## Examples

### Show a report only

```bash
./bin/synopkg-update-checker.sh --info
```

### Send the report by email

```bash
./bin/synopkg-update-checker.sh --email
```

### Send the report to a custom recipient

```bash
./bin/synopkg-update-checker.sh --email --email-to you@example.com
```

### Check only running official packages

```bash
./bin/synopkg-update-checker.sh --info --running --official-only
```

### Check only community and GitHub-based packages

```bash
./bin/synopkg-update-checker.sh --info --community-only --packages-only
```

### Simulate the installation flow

```bash
./bin/synopkg-update-checker.sh --dry-run
```

### Download and install available package updates

```bash
sudo ./bin/synopkg-update-checker.sh
```

## Output directories

```text
downloads/
├── os/
└── packages/

debug/
└── email_YYYYMMDD_HHMMSS.html
```

## DSM email configuration

If you want to use email reporting, configure DSM notifications first:

[Configure Synology email notifications](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/system_notification_email?version=7)
