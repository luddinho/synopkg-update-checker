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
EMAIL_MODE=false
RUNNING_ONLY=false
VERBOSE=false
DEBUG=false
declare -a COMMUNITIES=()

usage() {
    cat <<EOF
    Usage: $filename [options]

    Options:
        -i, --info          Display system and update information only,
                            like dry-run but without download messages and interactive installation
        -e, --email         Email mode - no output to stdout, only capture to variable (requires --info)
        -r, --running       Check updates only for packages that are currently running
        -c, --community     Check community repositories for package updates when not found on Synology archive
                            (can be specified multiple times with: synocommunity, <future_community>)
                            Example: -c synocommunity
                            Example: -c synocommunity -c another_community

        -n, --dry-run       Perform a dry run without downloading or installing updates
        -v, --verbose       Enable verbose output (not implemented)
        -d, --debug         Enable debug mode
        --                  End of options

      -h, --help          Display this help message

EOF
}

# Parse the command line arguments using getopt
filename=$(basename "$0")
PARSED_OPTIONS=$(getopt -n "$filename" -o ienvrdc:h --long info,email,dry-run,running,verbose,debug,community:,help -- "$@")
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

        -e|--email)
            EMAIL_MODE=true;
            INFO_MODE=true;
            shift ;;
        -r|--running)
            RUNNING_ONLY=true; shift ;;

        -c|--community)
            COMMUNITIES+=("$2"); shift 2 ;;

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

#-----------------------------------------------------------------------------
# CONVERT URLS TO HTML LINKS
# Convert plain text URLs to HTML anchor tags with application names
# Used in email mode to create clickable, shortened links
#-----------------------------------------------------------------------------
convert_urls_to_html_links() {
    local text="$1"
    local result="$text"

    # Convert OS download links: "Download Link: <URL>" -> "Download Link: <a href='URL'>OSName_version_filename.pat</a>"
    # Extract filename from URL and use it as link text with OS name and latest version, separated by underscores
    while [[ "$result" =~ (Download\ Link:\ )(https://[^ ]+/([^/]+\.pat)) ]]; do
        full_match="${BASH_REMATCH[0]}"
        url="${BASH_REMATCH[2]}"
        filename="${BASH_REMATCH[3]}"
        # URL decode the filename (e.g., %2B -> +)
        decoded_filename=$(echo "$filename" | sed 's/%2B/+/g; s/%20/ /g; s/%2F/\//g')
        replacement="Download Link: <a href='${url}' style='color: #0066cc; text-decoration: none;'>${os_name}_${os_latest}_${decoded_filename}</a>"
        result="${result//${full_match}/${replacement}}"
    done

    # Convert package download links in table format
    # Match lines with app name, version, and URL, then replace URL with clickable link
    local processed_result=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^([A-Za-z0-9_-]+)[[:space:]]+\|[[:space:]]+([0-9.-]+)[[:space:]]+\|[[:space:]]+(https://[^[:space:]]+\.spk) ]]; then
            app_name="${BASH_REMATCH[1]}"
            version="${BASH_REMATCH[2]}"
            url="${BASH_REMATCH[3]}"
            # Replace the URL with a clickable link using app name and version
            # Construct the replacement string separately to avoid expansion issues
            link_text="${app_name}_${version}"
            anchor_tag="<a href='${url}' style='color: #0066cc; text-decoration: none;'>${link_text}</a>"
            # Use sed for more reliable replacement
            new_line=$(echo "$line" | sed "s|${url}|${anchor_tag}|")
            processed_result+="${new_line}"$'\n'
        else
            processed_result+="${line}"$'\n'
        fi
    done <<< "$result"

    # Remove the trailing newline added by the loop
    result="${processed_result%$'\n'}"

    echo "$result"
}

#-----------------------------------------------------------------------------
# EMAIL FUNCTION
# Send email using Synology's built-in mail functionality
# Requires: Synology mail server to be configured in DSM
#-----------------------------------------------------------------------------
send_email() {
    local subject="$1"
    local body="$2"

    # Parse DSM SMTP configuration
    local smtp_server=""
    local smtp_port=""
    local smtp_use_ssl=""
    local smtp_auth=""
    local smtp_user=""
    local smtp_pass=""
    local smtp_from_name=""
    local smtp_from_mail=""
    local subject_prefix=""
    local recipient=""

    if [ -f "/usr/syno/etc/synosmtp.conf" ]; then
        smtp_server=$(grep "^eventsmtp=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        smtp_port=$(grep "^eventport=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        smtp_use_ssl=$(grep "^eventusessl=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        smtp_auth=$(grep "^eventauth=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        smtp_user=$(grep "^eventuser=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        smtp_pass=$(grep "^eventpasscrypted=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        smtp_from_name=$(grep "^smtp_from_name=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        smtp_from_mail=$(grep "^smtp_from_mail=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        subject_prefix=$(grep "^eventsubjectprefix=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        recipient=$(grep "^eventmails=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
    fi

    # Check if required SMTP configuration is available
    if [ -z "$smtp_server" ] || [ -z "$smtp_port" ] || [ -z "$smtp_user" ] || [ -z "$smtp_pass" ] || [ -z "$recipient" ]; then
        echo "Error: SMTP server or recipient not configured in DSM."
        echo "Please configure email notifications in DSM: Control Panel > Notification > Email"
        return 1
    fi

    # Build From header with name if available
    local from_header
    if [ -n "$smtp_from_name" ]; then
        from_header="From: $smtp_from_name <$smtp_from_mail>"
    else
        from_header="From: $smtp_from_mail"
    fi

    # Add subject prefix if configured
    local full_subject="${subject_prefix}${subject}"

    # Use HTML_OUTPUT if available (proper HTML tables), otherwise convert plain text
    local html_body
    if [ -n "$HTML_OUTPUT" ]; then
        # HTML_OUTPUT already contains proper HTML tables
        html_body="<!DOCTYPE html>
<html>
<head>
<meta charset=\"UTF-8\">
<style>
    body { font-family: Arial, sans-serif; font-size: 14px; line-height: 1.6; background-color: #f5f5f5; padding: 20px; }
    .container { background-color: white; padding: 20px; border-radius: 5px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
    h2 { color: #333; border-bottom: 2px solid #0066cc; padding-bottom: 5px; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
    th { border: 1px solid #ddd; padding: 8px; background-color: #f2f2f2; text-align: left; font-weight: bold; }
    td { border: 1px solid #ddd; padding: 8px; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    a { color: #0066cc; text-decoration: none; }
    a:hover { text-decoration: underline; }
</style>
</head>
<body>
<div class=\"container\">
$HTML_OUTPUT
</div>
</body>
</html>"
    else
        # Fallback to old conversion method for plain text
        local processed_body=$(convert_urls_to_html_links "$body")
        local escaped_body="$processed_body"

        # Step 1: Extract and protect anchor tags by replacing them with unique placeholders
        local anchor_counter=0
        declare -A anchor_map
        while [[ "$escaped_body" =~ \<a\ href=\'([^\']+)\'[^\>]*\>([^\<]+)\</a\> ]]; do
            full_anchor="${BASH_REMATCH[0]}"
            href="${BASH_REMATCH[1]}"
            text="${BASH_REMATCH[2]}"
            placeholder="__ANCHOR_${anchor_counter}__"
            anchor_map[$placeholder]="<a href='${href}' style='color: #0066cc; text-decoration: none;'>${text}</a>"
            escaped_body="${escaped_body//${full_anchor}/${placeholder}}"
            ((anchor_counter++))
        done

        # Step 2: Escape HTML entities in the remaining text
        escaped_body=$(echo "$escaped_body" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

        # Step 3: Restore anchor tags
        for placeholder in "${!anchor_map[@]}"; do
            escaped_body="${escaped_body//${placeholder}/${anchor_map[$placeholder]}}"
        done

        html_body="<!DOCTYPE html>
<html>
<head>
<meta charset=\"UTF-8\">
</head>
<body style=\"font-family: 'Courier New', Courier, monospace; font-size: 12px; line-height: 1.4; background-color: #f5f5f5; padding: 20px;\">
<div style=\"background-color: white; padding: 20px; border-radius: 5px; box-shadow: 0 2px 4px rgba(0,0,0,0.1);\">
<pre style=\"font-family: 'Courier New', Courier, monospace; font-size: 12px; white-space: pre; margin: 0;\">$escaped_body</pre>
</div>
</body>
</html>"
    fi

    # Check if ssmtp is available
    if command -v ssmtp &> /dev/null; then
        # Configure ssmtp on-the-fly using DSM settings
        local ssmtp_conf="/tmp/ssmtp_$$.conf"
        cat > "$ssmtp_conf" <<EOF
root=$smtp_from_mail
mailhub=$smtp_server:$smtp_port
hostname=$(hostname)
FromLineOverride=YES
EOF

        # Add SSL/TLS settings
        if [ "$smtp_use_ssl" = "yes" ] || [ "$smtp_use_ssl" = "true" ]; then
            echo "UseTLS=YES" >> "$ssmtp_conf"
            echo "UseSTARTTLS=YES" >> "$ssmtp_conf"
        fi

        # Add authentication settings
        if [ "$smtp_auth" = "yes" ] || [ "$smtp_auth" = "true" ]; then
            if [ -n "$smtp_user" ]; then
                echo "AuthUser=$smtp_user" >> "$ssmtp_conf"
            fi
            if [ -n "$smtp_pass" ]; then
                echo "AuthPass=$smtp_pass" >> "$ssmtp_conf"
            fi
        fi

        [ "$DEBUG" = true ] && echo "[DEBUG] Using ssmtp with config: $ssmtp_conf"
        [ "$DEBUG" = true ] && cat "$ssmtp_conf"

        # Send email using temporary config with HTML body
        {
            echo "$from_header"
            echo "To: $recipient"
            echo "Subject: $full_subject"
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/html; charset=UTF-8"
            echo ""
            echo "$html_body"
        } | ssmtp -C "$ssmtp_conf" "$recipient"
        local result=$?
        rm -f "$ssmtp_conf"
        return $result

    elif command -v sendmail &> /dev/null; then
        # Fallback to sendmail with HTML
        {
            echo "$from_header"
            echo "To: $recipient"
            echo "Subject: $full_subject"
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/html; charset=UTF-8"
            echo ""
            echo "$html_body"
        } | sendmail -t
        return $?

    elif command -v synodsmnotify &> /dev/null; then
        # Use Synology DSM notification system as last resort (plain text only)
        synodsmnotify @administrators "$full_subject" "$body"
        return $?
    else
        echo "Error: No mail command available (ssmtp, sendmail, or synodsmnotify)."
        echo "Please configure email notifications in DSM: Control Panel > Notification > Email"
        return 1
    fi
}

# Initialize output capture variable for INFO_MODE
INFO_OUTPUT=""
HTML_OUTPUT=""

# Print simulation mode message if dry-run is enabled
if [ "$DRY_RUN" = true ]; then
    printf "\n[SIMULATION MODE] Running in dry-run mode. No changes will be made.\n\n"
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
platform_name=$(synogetkeyvalue /etc.defaults/synoinfo.conf platform_name)

os_name=$(synogetkeyvalue /etc.defaults/VERSION os_name)
major_version=$(synogetkeyvalue /etc.defaults/VERSION majorversion)
minor_version=$(synogetkeyvalue /etc.defaults/VERSION minorversion)
micro_version=$(synogetkeyvalue /etc.defaults/VERSION micro)
build_number=$(synogetkeyvalue /etc.defaults/VERSION buildnumber)
smallfix_number=$(synogetkeyvalue /etc.defaults/VERSION smallfixnumber)

if [ $smallfix_number -eq 0 ]; then
    os_installed_version="${major_version}.${minor_version}.${micro_version}-${build_number}-0"
else
    os_installed_version="${major_version}.${minor_version}.${micro_version}-${build_number}-${smallfix_number}"
fi

# And update the display version (separate variable for showing to users)
if [ $smallfix_number -eq 0 ]; then
    os_display_version="${major_version}.${minor_version}.${micro_version}-${build_number}"
else
    os_display_version="${major_version}.${minor_version}.${micro_version}-${build_number}-${smallfix_number}"
fi

# Temporary debug variable - override OS version for testing
# DEBUG_OS_VERSION="7.3.2-86009"
if [ -n "$DEBUG_OS_VERSION" ]; then
    os_installed_version="$DEBUG_OS_VERSION"
    os_display_version="$DEBUG_OS_VERSION"
    [ "$DEBUG" = true ] && echo "[DEBUG] Using debug OS version: $DEBUG_OS_VERSION"
fi

# Print system information
if [ "$INFO_MODE" = true ]; then
    msg=$(cat <<EOF

System Information
=============================================
$(printf "%-30s | %s\n" "Product" "$product")
$(printf "%-30s | %s\n" "Model" "$model")
$(printf "%-30s | %s\n" "Architecture" "$arch")
$(printf "%-30s | %s\n" "Platform Name" "$platform_name")
$(printf "%-30s | %s\n" "Operating System" "$os_name")
$(printf "%-30s | %s\n" "Version" "$os_display_version")
EOF
)
    if [ "$EMAIL_MODE" = false ]; then
        printf "%s\n" "$msg"
    fi
    INFO_OUTPUT+="$msg"$'\n'

    # Build HTML table for email
    if [ "$EMAIL_MODE" = true ]; then
        HTML_OUTPUT+="<h2>1. System Information</h2>"
        HTML_OUTPUT+="<table style='border-collapse: collapse; width: 100%; margin-bottom: 20px;'>"
        HTML_OUTPUT+="<tr><th style='border: 1px solid #ddd; padding: 8px; background-color: #90EE90; text-align: left; width: 60%;'>Property</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #90EE90; text-align: left; width: 40%;'>Value</th></tr>"
        HTML_OUTPUT+="<tr><td style='border: 1px solid #ddd; padding: 4px;'>Product</td><td style='border: 1px solid #ddd; padding: 4px;'>$product</td></tr>"
        HTML_OUTPUT+="<tr><td style='border: 1px solid #ddd; padding: 4px;'>Model</td><td style='border: 1px solid #ddd; padding: 4px;'>$model</td></tr>"
        HTML_OUTPUT+="<tr><td style='border: 1px solid #ddd; padding: 4px;'>Architecture</td><td style='border: 1px solid #ddd; padding: 4px;'>$arch</td></tr>"
        HTML_OUTPUT+="<tr><td style='border: 1px solid #ddd; padding: 4px;'>Platform Name</td><td style='border: 1px solid #ddd; padding: 4px;'>$platform_name</td></tr>"
        HTML_OUTPUT+="<tr><td style='border: 1px solid #ddd; padding: 4px;'>Operating System</td><td style='border: 1px solid #ddd; padding: 4px;'>$os_name</td></tr>"
        HTML_OUTPUT+="<tr><td style='border: 1px solid #ddd; padding: 4px;'>Version</td><td style='border: 1px solid #ddd; padding: 4px;'>$os_display_version</td></tr>"
        HTML_OUTPUT+="</table>"
    fi
else
    printf "\n"
    printf "%s\n" "System Information"
    printf "%s\n" "============================================="
    printf "%-30s | %s\n" "Product" "$product"
    printf "%-30s | %s\n" "Model" "$model"
    printf "%-30s | %s\n" "Architecture" "$arch"
    printf "%-30s | %s\n" "Platform Name" "$platform_name"
    printf "%-30s | %s\n" "Operating System" "$os_name"
    printf "%-30s | %s\n" "Version" "$os_display_version"
fi

#-----------------------------------------------------------------------------
# OPERATING SYSTEM UPDATE CHECK
# Query the Synology archive server for available OS updates:
# 1. Fetch all available OS versions from archive.synology.com
# 2. Compare with currently installed version
# 3. Check model compatibility for newer versions
# 4. Display results in table format
# 5. Provide download link if update is available
#-----------------------------------------------------------------------------
if [ "$INFO_MODE" = true ]; then
    msg=$(cat <<EOF



Operating System Update Check
=============================================

$(printf "%-30s | %-15s | %-15s | %-6s\n" "Operating System" "Installed" "Latest Version" "Update")
$(printf "%-30s|%-15s|%-15s|%-6s\n" "-------------------------------" "-----------------" "-----------------" "--------")
EOF
)
    if [ "$EMAIL_MODE" = false ]; then
        printf "%s\n" "$msg"
    fi
    INFO_OUTPUT+="$msg"$'\n'

    # Build HTML table for email
    if [ "$EMAIL_MODE" = true ]; then
        HTML_OUTPUT+="<h2>2. Operating System</h2>"
        HTML_OUTPUT+="<table style='border-collapse: collapse; width: 100%; margin-bottom: 20px;'>"
        HTML_OUTPUT+="<tr><th style='border: 1px solid #ddd; padding: 8px; background-color: #ADD8E6; text-align: left; width: 40%;'>Operating System</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #ADD8E6; text-align: left; width: 20%;'>Installed</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #ADD8E6; text-align: left; width: 20%;'>Latest Version</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #ADD8E6; text-align: left; width: 20%;'>Update</th></tr>"
    fi
else
    printf "\n\n\n"
    printf "%s\n" "Operating System Update Check"
    printf "%s\n" "============================================="
    printf "%s\n"
    # Print header for OS update table
    printf "%-30s | %-15s | %-15s | %-6s\n" "Operating System" "Installed" "Latest Version" "Update"
    printf "%-30s|%-15s|%-15s|%-6s\n" "-------------------------------" "-----------------" "-----------------" "--------"
fi

# Fetch the OS archive page and parse for available versions
os_archive_url="https://archive.synology.com/download/Os/$os_name"
os_archive_html=$(curl -s "$os_archive_url")

# Initialize variables before the loop
os_url=""
os_latest=""
os_update_avail="-"
os_pat=""

if [ $? -eq 0 ] && echo "$os_archive_html" | grep -q "href=\"/download/Os/$os_name/"; then
    all_os_versions=$(echo "$os_archive_html" | grep -o 'href="/download/Os/'$os_name'/[^"]*"' | sed 's|href="/download/Os/'$os_name'/||;s|"||' | sort -V -r)

    # Normalize installed version for comparison (add -0 if missing smallfix)
    os_installed_version_normalized="$os_installed_version"
    if [[ ! "$os_installed_version" =~ -[0-9]+-[0-9]+$ ]]; then
        os_installed_version_normalized="${os_installed_version}-0"
    fi

    for os_version in $all_os_versions; do
        [ "$DEBUG" = true ] && echo "[DEBUG] Checking archive version: $os_version"

        # Normalize archive version for comparison
        os_version_normalized="$os_version"
        if [[ ! "$os_version" =~ -[0-9]+-[0-9]+$ ]]; then
            os_version_normalized="${os_version}-0"
        fi

        [ "$DEBUG" = true ] && echo "[DEBUG] Installed normalized: $os_installed_version_normalized"
        [ "$DEBUG" = true ] && echo "[DEBUG] Archive normalized: $os_version_normalized"

        # Compare normalized versions
        if [[ "$os_version_normalized" != "$os_installed_version_normalized" ]]; then
            [ "$DEBUG" = true ] && echo "[DEBUG] Versions are different, checking if newer..."
            sort_result=$(printf '%s\n%s' "$os_installed_version_normalized" "$os_version_normalized" | sort -V | head -1)
            [ "$DEBUG" = true ] && echo "[DEBUG] Sort result (oldest): $sort_result"

            if [[ "$sort_result" == "$os_installed_version_normalized" ]]; then
                [ "$DEBUG" = true ] && echo "[DEBUG] Archive version is NEWER, checking for .pat file..."
                # Newer version found, now check for model compatibility
                os_version_url="https://archive.synology.com/download/Os/$os_name/$os_version"
                os_version_html=$(curl -s "$os_version_url")

                # Debug: show all .pat files found
                [ "$DEBUG" = true ] && echo "[DEBUG] All .pat files in $os_version:" && echo "$os_version_html" | grep -o 'href="[^"]*\.pat"' | sed 's/href="//;s/"//'

                # Extract model series (e.g., "1817+" from "DS1817+")
                model_series="${model#DS}"
                model_series="${model_series#RS}"

                # Escape special characters in model name for grep
                model_escaped=$(echo "$model" | sed 's/[+]/\\&/g')
                model_series_escaped=$(echo "$model_series" | sed 's/[+]/\\&/g')
                # Convert to lowercase for case-insensitive matching
                model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
                model_series_lower=$(echo "$model_series" | tr '[:upper:]' '[:lower:]')

                [ "$DEBUG" = true ] && echo "[DEBUG] Model: $model"
                [ "$DEBUG" = true ] && echo "[DEBUG] Model series: $model_series"
                [ "$DEBUG" = true ] && echo "[DEBUG] Model escaped: $model_escaped"
                [ "$DEBUG" = true ] && echo "[DEBUG] Model series escaped: $model_series_escaped"
                [ "$DEBUG" = true ] && echo "[DEBUG] Platform name: $platform_name"

                # Check for either naming convention:
                # Major releases as versions like 7.3.2-86009 use the model name directly (e.g., DS1817+)
                # Patch releases as versions like 7.3.2-86009-1 use the platform name with underscore (e.g., $platform_name_1817+)
                # For VirtualDSM, prioritize platform_name match (e.g., synology_kvmx64_virtualdsm.pat)
                if echo "$os_version_html" | grep -qiE "($model_escaped|_${model_series_escaped})|_${platform_name}(_|.*(${model_lower}|${model_series_lower})).*\.pat"; then
                    # Extract all .pat filenames and filter for our model/platform
                    os_pat=$(echo "$os_version_html" | grep -oE '[a-zA-Z0-9_+-]+\.pat' | grep -iE "($model_escaped|_${model_series_escaped}|_${platform_name})" | head -1)
                    [ "$DEBUG" = true ] && echo "[DEBUG] Found .pat file: $os_pat"
                    os_latest="$os_version"
                    os_update_avail="X"

                    # Extract URL - need to handle URL-encoded characters like %2B for +
                    # First, get all .pat URLs, then filter for our model
                    model_series_url_encoded="${model_series//+/%2B}"
                    model_url_encoded="${model//+/%2B}"
                    # For VirtualDSM and similar, prioritize platform_name in URL matching
                    os_url=$(echo "$os_version_html" | grep -o 'href="[^"]*\.pat"' | grep -iE "(${model_url_encoded}|_${model_series_url_encoded}|_${platform_name})" | head -1 | sed 's|href="||;s|"||')
                    [ "$DEBUG" = true ] && echo "[DEBUG] Extracted os_url (raw): '$os_url'"

                    # Prepend domain if URL is relative
                    if [[ "$os_url" =~ ^/ ]]; then
                        os_url="https://archive.synology.com${os_url}"
                        [ "$DEBUG" = true ] && echo "[DEBUG] URL was relative, prepended domain: '$os_url'"
                    else
                        [ "$DEBUG" = true ] && echo "[DEBUG] URL is absolute or empty: '$os_url'"
                    fi
                    [ "$DEBUG" = true ] && echo "[DEBUG] Update available! Latest: $os_latest"
                    [ "$DEBUG" = true ] && echo "[DEBUG] Final os_url: '$os_url'"
                    break
                else
                    [ "$DEBUG" = true ] && echo "[DEBUG] No .pat file found for model $model (or series $model_series), skipping..."
                    continue
                fi
            fi
        fi
    done

    # Set default if no update found
    if [ -z "$os_latest" ]; then
        os_latest="$os_installed_version"
        os_update_avail="-"
        os_pat=""
        os_url=""
    fi

    if [ "$INFO_MODE" = true ]; then
        msg=$(printf "%-30s | %-15s | %-15s | %-6s\n" "$os_name" "$os_display_version" "$os_latest" "$os_update_avail")
        if [ "$EMAIL_MODE" = false ]; then
            printf "%s\n" "$msg"
        fi
        INFO_OUTPUT+="$msg"$'\n'

        # Add row to HTML table for email
        if [ "$EMAIL_MODE" = true ]; then
            # Convert update status to icon for HTML
            if [ "$os_update_avail" = "X" ]; then
                update_icon="<span style='font-size: 14px;'>🔄</span>"
                # Make latest version clickable if download URL is available
                if [ -n "$os_url" ]; then
                    os_latest_display="<a href='$os_url' style='color: #0066cc; text-decoration: none;'>$os_latest</a>"
                else
                    os_latest_display="$os_latest"
                fi
            else
                update_icon="<span style='font-size: 14px; color: #51CF66;'>✅</span>"
                os_latest_display="$os_latest"
            fi
            HTML_OUTPUT+="<tr><td style='border: 1px solid #ddd; padding: 4px;'>$os_name</td><td style='border: 1px solid #ddd; padding: 4px;'>$os_display_version</td><td style='border: 1px solid #ddd; padding: 4px;'>$os_latest_display</td><td style='border: 1px solid #ddd; padding: 4px; text-align: center;'>$update_icon</td></tr>"
            HTML_OUTPUT+="</table>"
        fi

        # Add download link right after the table if update is available
        if [ "$os_update_avail" = "X" ] && [ -n "$os_url" ]; then
            msg=$(printf "\nDownload Link: %s\n" "$os_url")
            if [ "$EMAIL_MODE" = false ]; then
                printf "%s" "$msg"
            fi
            INFO_OUTPUT+="$msg"
        fi
    else
        printf "%-30s | %-15s | %-15s | %-6s\n" "$os_name" "$os_display_version" "$os_latest" "$os_update_avail"
    fi
fi

# Add download link right after the table if update is available (only for non-INFO_MODE)
if [ "$os_update_avail" = "X" ] && [ -n "$os_url" ]; then
    if [ "$INFO_MODE" = false ]; then
        printf "\nDownload Link: %s\n" "$os_url"
    fi
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
if [ "$INFO_MODE" = true ]; then
    msg=$(cat <<EOF



Package Update Check
=============================================

$(printf "%-30s | %-15s | %-15s | %-6s\n" "Package" "Installed" "Latest Version" "Update")
$(printf "%-30s|%-15s|%-15s|%-6s\n" "-------------------------------" "-----------------" "-----------------" "--------")
EOF
)
    if [ "$EMAIL_MODE" = false ]; then
        printf "%s\n" "$msg"
    fi
    INFO_OUTPUT+="$msg"$'\n'

    # Build HTML table for email
    if [ "$EMAIL_MODE" = true ]; then
        HTML_OUTPUT+="<h2>3. Packages</h2>"
        HTML_OUTPUT+="<table style='border-collapse: collapse; width: 100%; margin-bottom: 20px;'>"
        HTML_OUTPUT+="<tr><th style='border: 1px solid #ddd; padding: 8px; background-color: #FFA500; text-align: left; width: 40%;'>Package</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #FFA500; text-align: left; width: 20%;'>Installed</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #FFA500; text-align: left; width: 20%;'>Latest Version</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #FFA500; text-align: left; width: 20%;'>Update</th></tr>"
    fi
else
    printf "\n\n\n"
    printf "Package Update Check\n"
    printf "%s\n" "============================================="
    printf "%s\n"
    # Print header for package update table
    printf "%-30s | %-15s | %-15s | %-6s\n" "Package" "Installed" "Latest Version" "Update"
    printf "%-30s|%-15s|%-15s|%-6s\n" "-------------------------------" "-----------------" "-----------------" "--------"
fi

# Initialize arrays to track packages with available updates:
# - download_apps: package names
# - downlaod_revisions: new version numbers
# - download_links: download URLs for .spk files
# - downlaod_files: local file paths after download
declare -a download_apps=()
declare -a downlaod_revisions=()
declare -a download_links=()
declare -a downlaod_files=()

# Count total installed packages
total_installed_packages=0

# Iterate through all installed packages and check for updates
for app in $(synopkg list --name | sort); do
    ((total_installed_packages++))
    # Skip non-running packages if RUNNING_ONLY is enabled
    if [ "$RUNNING_ONLY" = true ]; then
        pkg_status_output=$(synopkg status "$app" 2>/dev/null)
        pkg_status=$(echo "$pkg_status_output" | jq -r '.status')
        if [ "$pkg_status" != "running" ]; then
            [ "$DEBUG" = true ] && echo "[DEBUG] Skipping $app (status: $pkg_status)"
            continue
        fi
    fi

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
        # No update found on Synology archive, check community repositories if enabled
        if [ ${#COMMUNITIES[@]} -gt 0 ]; then
            [ "$DEBUG" = true ] && echo "[DEBUG] No package found on Synology archive for $app, checking community repositories..."

            # Iterate through each specified community
            for community in "${COMMUNITIES[@]}"; do
                [ "$DEBUG" = true ] && echo "[DEBUG] Checking community: $community"

                case "$community" in
                    synocommunity)
                        # Check SynoCommunity package page
                        synocommunity_pkg_url="https://synocommunity.com/package/$app"
                        synocommunity_pkg_html=$(curl -s "$synocommunity_pkg_url")

                        if [ $? -eq 0 ] && ! echo "$synocommunity_pkg_html" | grep -q "404\|Not Found\|not found"; then
                            [ "$DEBUG" = true ] && echo "[DEBUG] Found $app in SynoCommunity"

                            # Extract version numbers from <dt>Version X.Y.Z-N</dt> tags
                            # Look for lines with "Version" followed by version pattern
                            all_syno_versions=$(echo "$synocommunity_pkg_html" | grep -oP '(?<=<dt>Version\s)[0-9]+\.[0-9]+(\.[0-9]+)*-[0-9]+(?=</dt>)' | sort -Vur)

                            [ "$DEBUG" = true ] && echo "[DEBUG] SynoCommunity versions found: $all_syno_versions"

                            for version in $all_syno_versions; do
                                # Check if version is newer than current installed_revision
                                if [[ "$version" != "$installed_revision" ]] && [[ $(printf '%s\n%s' "$installed_revision" "$version" | sort -V | head -1) == "$installed_revision" ]]; then
                                    [ "$DEBUG" = true ] && echo "[DEBUG] Found newer SynoCommunity version: $version"

                                    # Extract download link for this version matching our architecture and DSM major version
                                    # DSM versions on SynoCommunity: DSM 5.x, DSM 6.x, DSM 7.x map to firmware codes
                                    # DSM 5.x uses f5644, DSM 6.x uses f25556, DSM 7.x uses f42661
                                    dsm_major="$major_version"  # e.g., 7 from 7.3.2

                                    # Map DSM major version to firmware codes used in SynoCommunity URLs
                                    case "$dsm_major" in
                                        5) firmware_code="f5644" ;;
                                        6) firmware_code="f25556" ;;
                                        7) firmware_code="f42661" ;;
                                        *) firmware_code="" ;;
                                    esac

                                    [ "$DEBUG" = true ] && echo "[DEBUG] Looking for DSM $dsm_major.x (firmware: $firmware_code) with platform: $platform_name or arch: $arch"

                                    # Try to find the download URL from href attributes matching firmware code and platform/arch
                                    # First try with platform_name (e.g., kvmx64)
                                    if [ -n "$firmware_code" ]; then
                                        spk_url=$(echo "$synocommunity_pkg_html" | grep -oP 'href="\Khttps://packages\.synocommunity\.com[^"]*\.spk' | \
                                                  grep "$firmware_code" | grep -i "\[$platform_name\]\|$platform_name-\|$platform_name\]" | head -1)
                                    fi

                                    if [ -z "$spk_url" ] && [ -n "$firmware_code" ]; then
                                        # Try with architecture if platform_name didn't work (e.g., x86_64)
                                        spk_url=$(echo "$synocommunity_pkg_html" | grep -oP 'href="\Khttps://packages\.synocommunity\.com[^"]*\.spk' | \
                                                  grep "$firmware_code" | grep -i "\[$arch\]\|$arch-\|$arch\]" | head -1)
                                    fi

                                    if [ -z "$spk_url" ]; then
                                        # Fallback: try without firmware code filter (just platform/arch)
                                        spk_url=$(echo "$synocommunity_pkg_html" | grep -oP 'href="\Khttps://packages\.synocommunity\.com[^"]*\.spk' | \
                                                  grep -i "$platform_name" | head -1)
                                    fi

                                    if [ -n "$spk_url" ]; then
                                        spk=$(basename "$spk_url")
                                        # URL decode the filename
                                        spk=$(echo "$spk" | sed 's/%5B/[/g; s/%5D/]/g')

                                        [ "$DEBUG" = true ] && echo "[DEBUG] Found download URL: $spk_url"
                                        [ "$DEBUG" = true ] && echo "[DEBUG] SPK filename: $spk"

                                        latest_revision="$version"
                                        download_apps+=("$app")
                                        downlaod_revisions+=("$latest_revision")
                                        download_links+=("$spk_url")
                                        update_avail="X"
                                        found="yes"
                                        break 2  # Break out of both version and community loops
                                    else
                                        [ "$DEBUG" = true ] && echo "[DEBUG] No download link found for DSM $dsm_major.x / $platform_name / $arch"
                                    fi
                                fi
                            done

                            if [ -z "$found" ]; then
                                [ "$DEBUG" = true ] && echo "[DEBUG] No newer version found in SynoCommunity"
                            fi
                        else
                            [ "$DEBUG" = true ] && echo "[DEBUG] Package $app not found in SynoCommunity"
                        fi
                        ;;

                    *)
                        [ "$DEBUG" = true ] && echo "[DEBUG] Unknown community: $community"
                        ;;
                esac

                # If found in this community, break the community loop
                if [ -n "$found" ]; then
                    break
                fi
            done
        fi

        if [ -z "$found" ]; then
            spk=""
            download_link=""
            update_avail="-"
            latest_revision="$installed_revision"
        fi
    fi
    if [ "$INFO_MODE" = true ]; then
        msg=$(printf "%-30s | %-15s | %-15s | %-6s\n" "$app" "$installed_revision" "$latest_revision" "$update_avail")
        if [ "$EMAIL_MODE" = false ]; then
            printf "%s\n" "$msg"
        fi
        INFO_OUTPUT+="$msg"$'\n'

        # Add row to HTML table for email
        if [ "$EMAIL_MODE" = true ]; then
            # Convert update status to icon for HTML
            if [ "$update_avail" = "X" ]; then
                update_icon="<span style='font-size: 14px;'>🔄</span>"
                # Make latest version clickable if download URL is available
                if [ -n "$url" ]; then
                    latest_revision_display="<a href='$url' style='color: #0066cc; text-decoration: none;'>$latest_revision</a>"
                else
                    latest_revision_display="$latest_revision"
                fi
            else
                update_icon="<span style='font-size: 14px; color: #51CF66;'>✅</span>"
                latest_revision_display="$latest_revision"
            fi
            HTML_OUTPUT+="<tr><td style='border: 1px solid #ddd; padding: 4px;'>$app</td><td style='border: 1px solid #ddd; padding: 4px;'>$installed_revision</td><td style='border: 1px solid #ddd; padding: 4px;'>$latest_revision_display</td><td style='border: 1px solid #ddd; padding: 4px; text-align: center;'>$update_icon</td></tr>"
        fi

        # Add download link right after the table if update is available
        if [ "$update_avail" = "X" ] && [ -n "$download_link" ]; then
            msg=$(printf "\nDownload Link: %s\n" "$download_link")
            if [ "$EMAIL_MODE" = false ]; then
                printf "%s" "$msg"
            fi
            INFO_OUTPUT+="$msg"
        fi
    else
        printf "%-30s | %-15s | %-15s | %-6s\n" "$app" "$installed_revision" "$latest_revision" "$update_avail"

        # Add download link right after the table if update is available
        if [ "$update_avail" = "X" ] && [ -n "$download_link" ]; then
            printf "\nDownload Link: %s\n" "$download_link"
        fi
    fi
done

# Print download links if any updates are available
if [[ ${#download_apps[@]} -gt 0 && ${#download_links[@]} -gt 0 ]]; then
    # check if both arrays have the same length
    if [ ${#download_apps[@]} -ne ${#download_links[@]} ]; then
        echo "Error: download_apps and download_links arrays have different lengths."
        exit 1
    fi

    if [ "$INFO_MODE" = true ]; then
        msg=$(cat <<EOF



Download Links for Available Updates:
=============================================

$(printf "%-30s | %-30s | %-30s\n" "Application" "Version" "URL")
$(printf "%-30s | %-30s | %-30s\n" "------------------------------" "------------------------------" "------------------------------")
EOF
)
        if [ "$EMAIL_MODE" = false ]; then
            printf "%s\n" "$msg"
        fi
        INFO_OUTPUT+="$msg"$'\n'
    else
        printf "\n\n\n"
        printf "Download Links for Available Updates:\n"
        printf "%s\n" "============================================="
        printf "%s\n"
        printf "%-30s | %-30s | %-30s\n" "Application" "Version" "URL"
        printf "%-30s | %-30s | %-30s\n" "------------------------------" "------------------------------" "------------------------------"
    fi

    # count the number of elements in download_apps
    amount=${#download_apps[@]}
    idx=0
    for idx in $(seq 0 $((amount - 1))); do
        app_name="${download_apps[$idx]}"
        url="${download_links[$idx]}"
        if [ "$INFO_MODE" = true ]; then
            msg=$(printf "%-30s | %-30s | %-30s\n" "$app_name" "${downlaod_revisions[$idx]}" "$url")
            if [ "$EMAIL_MODE" = false ]; then
                printf "%s\n" "$msg"
            fi
            INFO_OUTPUT+="$msg"$'\n'
        else
            printf "%-30s | %-30s | %-30s\n" "$app_name" "${downlaod_revisions[$idx]}" "$url"
        fi
    done

    if [ "$INFO_MODE" = false ]; then
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
            if [ "$DRY_RUN" = true ]; then
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
fi

# Close HTML table for packages
if [ "$EMAIL_MODE" = true ]; then
    HTML_OUTPUT+="</table>"
fi

# Display total count of packages with available updates
amount=${#download_apps[@]}
if [ "$INFO_MODE" = true ]; then
    msg=$(printf "\nTotal installed packages: %d\nTotal packages with updates available: %d" "$total_installed_packages" "$amount")
    if [ "$EMAIL_MODE" = false ]; then
        printf "%s\n" "$msg"
    fi
    INFO_OUTPUT+="$msg"$'\n'

    # Add summary to HTML
    if [ "$EMAIL_MODE" = true ]; then
        HTML_OUTPUT+="<p style='margin-top: 20px; font-weight: bold;'>Total installed packages: $total_installed_packages</p>"
        HTML_OUTPUT+="<p style='font-weight: bold;'>Total packages with updates available: $amount</p>"
    fi
else
    printf "\n"
    printf "Total installed packages: %d\n" "$total_installed_packages"
    printf "Total packages with updates available: %d\n" "$amount"
fi

# Exit if in info mode
if [ "$INFO_MODE" = true ]; then
    # Send email if EMAIL_MODE is enabled
    if [ "$EMAIL_MODE" = true ]; then
        # Extract hostname for subject line
        hostname=$(hostname)
        email_subject="Synology Update Checker Report"

        # Convert INFO_OUTPUT to plain text (interpret escape sequences)
        email_body=$(printf "%b" "$INFO_OUTPUT")

        # Save HTML email to debug directory if debug mode is enabled
        if [ "$DEBUG" = true ] && [ -n "$HTML_OUTPUT" ]; then
            # Create debug directory if it doesn't exist
            debug_dir="$script_dir/../debug"
            mkdir -p "$debug_dir"

            # Generate filename with timestamp
            timestamp=$(date +"%Y%m%d_%H%M%S")
            debug_file="$debug_dir/email_${timestamp}.html"

            # Build complete HTML document
            cat > "$debug_file" <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
    body { font-family: Arial, sans-serif; font-size: 14px; line-height: 1.6; background-color: #f5f5f5; padding: 20px; }
    .container { background-color: white; padding: 20px; border-radius: 5px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
    h2 { color: #333; border-bottom: 2px solid #0066cc; padding-bottom: 5px; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
    th { border: 1px solid #ddd; padding: 8px; background-color: #f2f2f2; text-align: left; font-weight: bold; }
    td { border: 1px solid #ddd; padding: 8px; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    a { color: #0066cc; text-decoration: none; }
    a:hover { text-decoration: underline; }
</style>
</head>
<body>
<div class="container">
$HTML_OUTPUT
</div>
</body>
</html>
EOF
            echo "[DEBUG] HTML email saved to: $debug_file"
        fi

        # Send the email
        if send_email "$email_subject" "$email_body"; then
            [ "$DEBUG" = true ] && echo "[DEBUG] Email sent successfully"
        else
            echo "Error: Failed to send email" >&2
            exit 1
        fi
    fi
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

# Print simulation mode message if dry-run is enabled
if [ "$DRY_RUN" = true ]; then
    printf "\n\n[SIMULATION MODE] Running in dry-run mode. No changes will be made.\n"
fi

printf "\n"
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
