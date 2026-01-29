#!/bin/bash
#=============================================================================
# Script to check for Synology DSM and package updates from the Synology archive
# Requires: dmidecode, curl, synopkg, synogetkeyvalue, wget
# Author: luddinho
# Version: 1.0
#=============================================================================

#-----------------------------------------------------------------------------
# COMMAND LINE ARGUMENT HANDLING
# Parse optional arguments for dry-run mode and help display
#-----------------------------------------------------------------------------
DRY_RUN=false
INFO_MODE=false
usage() {
    cat <<EOF
    Usage: $filename [options]

    Options:
        -i, --info          Display system and update information only,
                            like dry-run but without download messages and interactive installation
        -n, --dry-run       Perform a dry run without downloading or installing updates
        -v, --verbose       Enable verbose output (not implemented)
        -d, --debug         Enable debug mode
        --                  End of options

      -h, --help          Display this help message

EOF
}

# Parse the command line arguments using getopt
filename=$(basename "$0")
PARSED_OPTIONS=$(getopt -n "$filename" -o invdh --long info,dry-run,verbose,debug,help -- "$@")
retcode=$?
if [ $retcode != 0 ]; then
    usage
    exit 1
fi
# Extract the options and their arguments into variables
eval set -- "$PARSED_OPTIONS"
# Handle the options and arguments
while true; do
    case "$1" in
        # optional arguments
        -i|--info)
            INFO_MODE=true; shift ;;

        -n|--dry-run)
            DRY_RUN=true; shift ;;

        -v|--verbose)
            VERBOSE=true; shift ;;

        -d|--debug)
            DEBUG=true; shift ;;

        -h|--help)
            usage
            exit 0
            ;;
        # End of options
        --)
            shift
            break ;;
        # Default
        *)
            break ;;
    esac
done

# Print simulation mode message if dry-run is enabled
if [ "$DRY_RUN" = true ]; then
    printf "\n[SIMULATION MODE] Running in dry-run mode. No changes will be made.\n\n"
fi

if [ "$INFO_MODE" = true ]; then
    printf "\nDisplaying system and update information only. No downloads or installations will be performed.\n\n"
fi

#-----------------------------------------------------------------------------
# DIRECTORY SETUP
# Create download directories for OS updates (.pat) and packages (.spk)
# If directories exist from previous runs, clean them to ensure fresh downloads
#-----------------------------------------------------------------------------
script_dir="$(dirname "$0")"

# Prepare download directories, clean if already exists
download_dir="$script_dir/../downloads"
if [ ! -d "$download_dir" ]; then
    mkdir -p "$download_dir"
else
    rm -rf "$download_dir"
    mkdir -p "$download_dir"
fi
# Create subdirectory for OS
download_dir_os="$download_dir/os"
if [ ! -d "$download_dir_os" ]; then
    mkdir -p "$download_dir_os"
fi
# Create subdirectory for packages
download_dir_pkg="$download_dir/packages"
if [ ! -d "$download_dir_pkg" ]; then
    mkdir -p "$download_dir_pkg"
fi

#-----------------------------------------------------------------------------
# SYSTEM INFORMATION GATHERING
# Extract system details from Synology configuration files:
# - Product type (DiskStation, RackStation, VirtualDSM, etc.)
# - Model name (e.g., DS1817+, RS2421+)
# - Architecture (x86_64, armv7, etc.)
# - OS name (DSM or BSM)
# - Version information (major.minor.micro-build-smallfix)
#-----------------------------------------------------------------------------
product=$(synogetkeyvalue /etc.defaults/synoinfo.conf product)
if [ "$product" == "VirtualDSM" ]; then
    model="VirtualDSM"
else
    model=$(dmidecode -s system-product-name)
fi
arch=$(uname -m)

os_name=$(synogetkeyvalue /etc.defaults/VERSION os_name)
major_version=$(synogetkeyvalue /etc.defaults/VERSION majorversion)
minor_version=$(synogetkeyvalue /etc.defaults/VERSION minorversion)
micro_version=$(synogetkeyvalue /etc.defaults/VERSION micro)
build_number=$(synogetkeyvalue /etc.defaults/VERSION buildnumber)
smallfix_number=$(synogetkeyvalue /etc.defaults/VERSION smallfixnumber)

if [ $smallfix_number -eq 0 ]; then
    os_installed_version="${major_version}.${minor_version}.${micro_version}-${build_number}"
else
    os_installed_version="${major_version}.${minor_version}.${micro_version}-${build_number}-${smallfix_number}"
fi

# Print system information
printf "\n"
printf "%s\n" "System Information"
printf "%s\n" "============================================="
printf "%-30s | %s\n" "Product" "$product"
printf "%-30s | %s\n" "Model" "$model"
printf "%-30s | %s\n" "Architecture" "$arch"
printf "%-30s | %s\n" "Operating System" "$os_name"
printf "%-30s | %s\n" "$os_name Version" "$os_installed_version"

#-----------------------------------------------------------------------------
# OPERATING SYSTEM UPDATE CHECK
# Query the Synology archive server for available OS updates:
# 1. Fetch all available OS versions from archive.synology.com
# 2. Compare with currently installed version
# 3. Check model compatibility for newer versions
# 4. Display results in table format
# 5. Provide download link if update is available
#-----------------------------------------------------------------------------
printf "\n\n\n"
printf "%s\n" "Operating System Update Check"
printf "%s\n" "============================================="
printf "%s\n"
# Print header for OS update table
printf "%-30s | %-15s | %-15s | %-10s | %-20s\n" "Operating System" "Installed" "Latest Version" "Update" "pat"
printf "%-30s|%-15s|%-15s|%-10s|%-20s\n" "-------------------------------" "-----------------" "-----------------" "------------" "--------------------"

# Fetch the OS archive page and parse for available versions
os_archive_url="https://archive.synology.com/download/Os/$os_name"
os_archive_html=$(curl -s "$os_archive_url")
if [ $? -eq 0 ] && echo "$os_archive_html" | grep -q "href=\"/download/Os/$os_name/"; then
    all_os_versions=$(echo "$os_archive_html" | grep -o 'href="/download/Os/'$os_name'/[^"]*"' | sed 's|href="/download/Os/'$os_name'/||;s|"||' | sort -V -r)
    for os_version in $all_os_versions; do
        if [[ "$os_version" != "$os_installed_version" ]] && [[ $(printf '%s\n%s' "$os_installed_version" "$os_version" | sort -V | head -1) == "$os_installed_version" ]]; then
            # Newer version found, now check for model compatibility
            os_version_url="https://archive.synology.com/download/Os/$os_name/$os_version"
            os_version_html=$(curl -s "$os_version_url")
            if echo "$os_version_html" | grep -q "$model.*\.pat"; then
                os_pat=$(echo "$os_version_html" | grep -o "[^/]*$model[^\"']*\.pat" | head -1 | sed 's/.*">//;s/".*$//')
            else
                continue
            fi
            os_latest="$os_version"
            os_update_avail="X"
            os_url=$(echo "$os_version_html" | grep "[^/]*$model[^\"']*\.pat" | grep -o "href=\"[^\"']*\.pat" | head -1 | sed 's|href="||;s|"||')
            break
        else
            # No update available
            os_latest="$os_installed_version"
            os_update_avail="-"
            os_pat=""
        fi
    done
    printf "%-30s | %-15s | %-15s | %-10s | %-20s\n" "$os_name" "$os_installed_version" "$os_latest" "$os_update_avail" "$os_pat"
fi

# Print download link if OS update is available
# NOTE: OS downloads are disabled because manual installation is required
# The command 'synoupgrade --patch' is not supported for automated installation
if [ "$os_update_avail" = "X" ] && [ -n "$os_url" ]; then
    printf "\n"
    printf "%s\n" "Download Link for OS Update:"
    printf "%-30s | %-50s\n" "Operating System" "URL"
    printf "%-30s | %-50s\n" "------------------------------" "--------------------------------------------------"
    printf "%-30s | %-50s\n" "$os_name $os_latest" "$os_url"
    printf "\n"
    printf "NOTE: OS update must be downloaded and installed manually through DSM interface.\n"
    printf "      Automated installation via 'synoupgrade --patch' is not supported.\n"
fi

#-----------------------------------------------------------------------------
# PACKAGE UPDATE CHECK
# For each installed package:
# 1. First check via synopkg checkupdate (official update channel)
# 2. If no update found, query Synology archive server for newer versions
# 3. Verify architecture and OS compatibility (DSM vs BSM)
# 4. Collect packages with available updates for later download
# 5. Display results in table format with version comparison
#-----------------------------------------------------------------------------
printf "\n\n\n"
printf "Package Update Check\n"
printf "%s\n" "============================================="
printf "%s\n"
# Print header for package update table
printf "%-30s | %-15s | %-15s | %-10s | %-20s\n" "Package" "Installed" "Latest Version" "Update" "spk"
printf "%-30s|%-15s|%-15s|%-10s|%-20s\n" "-------------------------------" "-----------------" "-----------------" "------------" "--------------------"

# Initialize arrays to track packages with available updates:
# - download_apps: package names
# - downlaod_revisions: new version numbers
# - download_links: download URLs for .spk files
# - downlaod_files: local file paths after download
declare -a download_apps=()
declare -a downlaod_revisions=()
declare -a download_links=()
declare -a downlaod_files=()

# Iterate through all installed packages and check for updates
for app in $(synopkg list --name | sort); do
    # Identify currently installed revision
    installed_revision=$(synopkg version $app)

    # Check Synology archive server for available updates
    archive_url="https://archive.synology.com/download/Package/$app"
    archive_html=$(curl -s "$archive_url")
    if [ $? -eq 0 ] && echo "$archive_html" | grep -q "href=\"/download/Package/$app/"; then
        # Extract all version folders, sort numerically descending (latest first)
        all_versions=$(echo "$archive_html" | grep -o 'href="/download/Package/'$app'/[^"]*"' | sed 's|href="/download/Package/'$app'/||;s|"||' | sort -V -r)
        found=""
        for version in $all_versions; do
            # Check if version is newer than current installed_revision
            if [[ "$version" != "$installed_revision" ]] && [[ $(printf '%s\n%s' "$installed_revision" "$version" | sort -V | head -1) == "$installed_revision" ]]; then
                # Check if there's an SPK for the current architecture and OS
                version_url="https://archive.synology.com/download/Package/$app/$version"
                version_html=$(curl -s "$version_url")
                if [ "$os_name" = "BSM" ]; then
                    if echo "$version_html" | grep -q "BSM.*$arch.*\.spk"; then
                        latest_revision="$version"
                        # grep the name of the spk file
                        spk=$(echo "$version_html" | grep -o "[^/]*BSM[^/]*$arch[^\"']*\.spk" | head -1 | sed 's/.*">//;s/".*$//')
                        url=$(echo "$version_html" | grep -o "href=\"[^\"']*/download/Package/spk/[^\"']*BSM[^\"']*$arch[^\"']*\.spk\"" | head -1 | sed 's|href="||;s|"||')
                        download_apps+=("$app")
                        downlaod_revisions+=("$latest_revision")
                        download_links+=("$url")
                        update_avail="X"
                        found="yes"
                        break
                    fi
                else
                    if echo "$version_html" | grep -q "$arch.*\.spk" && ! echo "$version_html" | grep -q "BSM"; then
                        latest_revision="$version"
                        # grep the name of the spk file
                        spk=$(echo "$version_html" | grep -o "[^/]*$arch[^\"']*\.spk" | head -1 | sed 's/.*">//;s/".*$//')
                        url=$(echo "$version_html" | grep -o "href=\"[^\"']*/download/Package/spk/[^\"']*$arch[^\"']*\.spk\"" | head -1 | sed 's|href="||;s|"||')
                        download_apps+=("$app")
                        downlaod_revisions+=("$latest_revision")
                        download_links+=("$url")
                        update_avail="X"
                        found="yes"
                        break
                    fi
                fi
            fi
        done
        if [ -z "$found" ]; then
            spk=""
            download_link=""
            update_avail="-"
            latest_revision="$installed_revision"
        fi
    else
        spk=""
        download_link=""
        update_avail="-"
        latest_revision="$installed_revision"
    fi
       printf "%-30s | %-15s | %-15s | %-10s | %-20s\n" "$app" "$installed_revision" "$latest_revision" "$update_avail" "$spk"
done

# Print download links if any updates are available
if [[ ${#download_apps[@]} -gt 0 && ${#download_links[@]} -gt 0 ]]; then
    # check if both arrays have the same length
    if [ ${#download_apps[@]} -ne ${#download_links[@]} ]; then
        echo "Error: download_apps and download_links arrays have different lengths."
        exit 1
    fi
    printf "\n\n\n"
    printf "Download Links for Available Updates:\n"
    printf "%s\n" "============================================="
    printf "%s\n"
    printf "%-30s | %-30s | %-50s\n" "Application" "Version" "URL"
    printf "%-30s | %-30s | %-50s\n" "------------------------------" "------------------------------" "--------------------------------------------------"

    # count the number of elements in download_apps
    amount=${#download_apps[@]}
    idx=0
    for idx in $(seq 0 $((amount - 1))); do
        app_name="${download_apps[$idx]}"
        url="${download_links[$idx]}"
        printf "%-30s | %-30s | %-50s\n" "$app_name" "${downlaod_revisions[$idx]}" "$url"
    done
    printf "\n\n"
    printf "Downloading updateable packages\n"
    printf "%s\n" "============================================="
    # Download the spk files into the downloads directory if not in dry run mode
    idx=0
    for idx in $(seq 0 $((amount - 1))); do
        url="${download_links[$idx]}"
        spk_name=$(basename "$url")
        filePath="$(realpath "$download_dir_pkg/$spk_name")"
        downlaod_files+=("$filePath")
        if [ "$INFO_MODE" = true ]; then
            continue
        elif [ "$DRY_RUN" = true ]; then
            printf "Dry run mode: Skipping download of %s\n" $(basename "$url")
        else
            printf "\n"
            printf "Downloading %s...\n"
            printf "Package: %s\n" "${download_apps[$idx]}"
            printf "File: %s\n" "$spk_name"
            printf "Path: %s\n" "$filePath"
            wget -q --show-progress -O "$filePath" "$url"
        fi
    done
fi

# Display total count of packages with available updates
amount=${#download_apps[@]}
printf "\n"
printf "Total packages with updates available: %d\n" "$amount"

# Exit if in info mode
if [ "$INFO_MODE" = true ]; then
    printf "\nNo installations will be performed. Exiting.\n"
    exit 0
fi

#-----------------------------------------------------------------------------
# INTERACTIVE PACKAGE INSTALLATION
# Present user with interactive menu to select packages for installation:
# - Individual package selection by number
# - "all" option to process all packages
# - "quit" option to exit without installing
# Each installation requires explicit user confirmation
# Package arrays are updated as installations complete
#-----------------------------------------------------------------------------
if [ ${#download_apps[@]} -eq 0 ]; then
    printf "\n\n"
    printf "No packages to update. Exiting.\n"
    exit 0
fi

printf "\n\n\n"
printf "Select packages to update:\n"
printf "==========================\n"

while [ ${#download_apps[@]} -gt 0 ]; do
    printf "\n"
    PS3="Select the operation (or 'q' to quit): "
    COLUMNS=1

    select opt in "${download_apps[@]}" all; do
        # Allow 'q' as a quit shortcut
        if [[ "$REPLY" == "q" || "$REPLY" == "Q" ]]; then
            break 2
        fi
        # Handle user selection
        case $opt in
            all)
                printf "You selected to update all packages.\n"
                # Ask user to confirm installation for all packages once
                read -p "Are you sure you want to update ALL packages? (y/n): " confirm_all
                if [[ "$confirm_all" == "y" || "$confirm_all" == "Y" ]]; then
                    for index in "${!download_apps[@]}"; do
                        selected_file="${downlaod_files[$index]}"
                        if [[ -f "$selected_file" || "$DRY_RUN" = true ]]; then
                            printf "\n"
                            printf "Package to update: %s\n" "${download_apps[$index]}"
                            if [ "$DRY_RUN" = true ]; then
                                printf "Dry run mode: Skipping installation of %s\n" $(basename "$selected_file")
                            else
                                app_name="${download_apps[$index]}"
                                # Store previous status before installation
                                prev_status_output=$(synopkg status "$app_name" 2>/dev/null)
                                prev_pkg_status=$(echo "$prev_status_output" | jq -r '.status')
                                printf "Installing package from file: %s\n" "$selected_file"
                                output=$(synopkg install "$selected_file" 2>/dev/null)
                                error_code=$(echo "$output" | jq -r '.error.code')
                                success=$(echo "$output" | jq -r '.success')
                                if [ "$success" = "true" ] && [ "$error_code" = "0" ]; then
                                    echo "Installation successful (error code: $error_code)"
                                    # Only start the application if it was running before and is not running after
                                    status_output=$(synopkg status "$app_name" 2>/dev/null)
                                    pkg_status=$(echo "$status_output" | jq -r '.status')
                                    [ "$DEBUG" = true ] && echo "[DEBUG] Previous package status: $prev_pkg_status"
                                    [ "$DEBUG" = true ] && echo "[DEBUG] Current package status: $pkg_status"
                                    if [ "$prev_pkg_status" = "running" ] && [ "$pkg_status" != "running" ]; then
                                        printf "Starting application: %s\n" "$app_name"
                                        start_output=$(synopkg start "$app_name" 2>/dev/null)
                                        start_error_code=$(echo "$start_output" | jq -r '.error.code')
                                        start_success=$(echo "$start_output" | jq -r '.success')
                                        if [ "$start_success" = "true" ] && [ "$start_error_code" = "0" ]; then
                                            echo "Start successful (error code: $start_error_code)"
                                        else
                                            echo "Start failed (error code: $start_error_code)"
                                        fi
                                    else
                                        echo "Application was running before and is already running after update. Not starting."
                                    fi
                                else
                                    echo "Installation failed (error code: $error_code)"
                                fi
                            fi
                        else
                            printf "Error: File %s does not exist.\n" "$selected_file"
                        fi
                    done
                    printf "\n"
                    printf "================================\n"
                    echo "All packages processed. Exiting."
                    break 2
                else
                    printf "Installation of all packages cancelled by user.\n"
                fi
                ;;
            *)
                if [[ "$REPLY" -ge 1 && "$REPLY" -le ${#download_apps[@]} ]]; then
                    index=$((REPLY - 1))
                    selected_file="${downlaod_files[$index]}"
                    if [[ -f "$selected_file" || "$DRY_RUN" = true ]]; then
                        printf "\n"
                        printf "You selected to update package: %s\n" "${download_apps[$index]}"
                        # Ask user to confirm installation
                        read -p "Are you sure you want to update this package? (y/n): " confirm
                        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                            if [ "$DRY_RUN" = true ]; then
                                printf "Dry run mode: Skipping installation of %s\n" $(basename "$selected_file")
                            else
                                app_name="${download_apps[$index]}"
                                # Store previous status before installation
                                prev_status_output=$(synopkg status "$app_name" 2>/dev/null)
                                prev_pkg_status=$(echo "$prev_status_output" | jq -r '.status')
                                printf "Installing package from file: %s\n" "$selected_file"
                                output=$(synopkg install "$selected_file" 2>/dev/null)
                                error_code=$(echo "$output" | jq -r '.error.code')
                                success=$(echo "$output" | jq -r '.success')
                                if [ "$success" = "true" ] && [ "$error_code" = "0" ]; then
                                    echo "Installation successful (error code: $error_code)"
                                    # Only start the application if it was running before and is not running after
                                    status_output=$(synopkg status "$app_name" 2>/dev/null)
                                    pkg_status=$(echo "$status_output" | jq -r '.status')
                                    [ "$DEBUG" = true ] && echo "[DEBUG] Previous package status: $prev_pkg_status"
                                    [ "$DEBUG" = true ] && echo "[DEBUG] Current package status: $pkg_status"
                                    if [ "$prev_pkg_status" = "running" ] && [ "$pkg_status" != "running" ]; then
                                        printf "Starting application: %s\n" "$app_name"
                                        start_output=$(synopkg start "$app_name" 2>/dev/null)
                                        start_error_code=$(echo "$start_output" | jq -r '.error.code')
                                        start_success=$(echo "$start_output" | jq -r '.success')
                                        if [ "$start_success" = "true" ] && [ "$start_error_code" = "0" ]; then
                                            echo "Start successful (error code: $start_error_code)"
                                        else
                                            echo "Start failed (error code: $start_error_code)"
                                        fi
                                    else
                                        echo "Application was running before and is already running after update. Not starting."
                                    fi
                                else
                                    echo "Installation failed (error code: $error_code)"
                                fi
                            fi

                            # Remove the selected item from arrays
                            download_apps=("${download_apps[@]:0:$index}" "${download_apps[@]:$((index+1))}")
                            download_files=("${download_files[@]:0:$index}" "${download_files[@]:$((index+1))}")
                            if [ ${#download_apps[@]} -eq 0 ]; then
                                printf "\n"
                                printf "================================\n"
                                echo "All packages processed. Exiting."
                                break 2
                            fi
                        else
                            printf "Installation cancelled by user.\n"
                            printf "Starting over selection.\n"
                        fi
                    else
                        printf "Error: File %s does not exist.\n" "$selected_file"
                    fi
                else
                    printf "%s\n" "==> Wrong input, please retry..."
                fi
                break
                ;;
        esac
    done
done

#-----------------------------------------------------------------------------
# CLEANUP
# Remove all downloaded files and directories after installation
# This ensures no residual .spk files remain on the system
#-----------------------------------------------------------------------------
rm -rf "$download_dir"

exit 0
