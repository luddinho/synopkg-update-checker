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
EMAIL_TO=""
RUNNING_ONLY=false
VERBOSE=false
DEBUG=false
OFFICIAL_ONLY=false
COMMUNITY_ONLY=false
OS_ONLY=false
PACKAGES_ONLY=false

#-----------------------------------------------------------------------------
# USAGE FUNCTION
# Display help message for script usage and options
#-----------------------------------------------------------------------------
usage() {
    cat <<EOF
    Usage: $filename [options]

    Options:
        -i, --info          Display system and update information only,
                            like dry-run but without download messages and interactive installation
        -e, --email         Email mode - no output to stdout, only capture to variable (requires --info)
        --email-to <email>  Override recipient email address (optional, defaults to DSM configuration)
        -r, --running       Check updates only for packages that are currently running
        --official-only     Show only official Synology packages
        --community-only    Show only community/third-party packages
        --os-only           Check only for operating system updates
        --packages-only     Check only for package updates

        -n, --dry-run       Perform a dry run without downloading or installing updates
        -v, --verbose       Enable verbose output (not implemented)
        -d, --debug         Enable debug mode
        --                  End of options

      -h, --help          Display this help message

EOF
}

#-----------------------------------------------------------------------------
# Function get_package_distributor()
# Extract distributor or maintainer information from package INFO file
# Returns: distributor (if present) or maintainer name, or "Unknown" if not found
#-----------------------------------------------------------------------------
get_package_distributor() {
    local package_name="$1"
    local info_file="/var/packages/${package_name}/INFO"

    if [ -f "$info_file" ]; then
        # Extract distributor field first (present in community packages)
        local distributor=$(grep '^distributor=' "$info_file" | cut -d'=' -f2- | tr -d '"')
        if [ -n "$distributor" ]; then
            echo "$distributor"
            return
        fi

        # Fall back to maintainer field (for official packages)
        local maintainer=$(grep '^maintainer=' "$info_file" | cut -d'=' -f2- | tr -d '"')
        if [ -n "$maintainer" ]; then
            echo "$maintainer"
        else
            echo "Unknown"
        fi
    else
        echo "Unknown"
    fi
}

#-----------------------------------------------------------------------------
# Function is_official_package()
# Determine if a package is from Synology based on distributor field
# Community packages have a distributor field, official Synology packages don't
# Returns: 0 (true) if official, 1 (false) if community/third-party
#-----------------------------------------------------------------------------
is_official_package() {
    local package_name="$1"
    local info_file="/var/packages/${package_name}/INFO"

    if [ -f "$info_file" ]; then
        # Check if distributor field exists (community packages have this)
        local distributor=$(grep '^distributor=' "$info_file" | cut -d'=' -f2- | tr -d '"')
        if [ -n "$distributor" ]; then
            # Check if distributor is Synology Inc. (official)
            if [[ "$distributor" == "Synology Inc." ]]; then
                return 0  # Synology Inc. -> Official
            else
                return 1  # Other distributor -> Community/Third-party
            fi
        else
            return 0  # No distributor -> Official Synology
        fi
    else
        # If INFO file doesn't exist, assume unknown/community
        return 1
    fi
}

#-----------------------------------------------------------------------------
# Function convert_urls_to_html_links()
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

        # Try multiple field names for recipient
        recipient=$(grep "^eventmails=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        if [ -z "$recipient" ]; then
            recipient=$(grep "^mail_to=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        fi
        if [ -z "$recipient" ]; then
            recipient=$(grep "^recipient=" /usr/syno/etc/synosmtp.conf | cut -d'=' -f2 | tr -d '"')
        fi
    fi

    # Override with command line argument if provided
    if [ -n "$EMAIL_TO" ]; then
        recipient="$EMAIL_TO"
        [ "$DEBUG" = true ] && echo "[DEBUG] Using command line recipient override: $recipient"
    fi

    # Debug: Show parsed configuration and dump config file if recipient is missing
    [ "$DEBUG" = true ] && echo "[DEBUG] SMTP Configuration:"
    [ "$DEBUG" = true ] && echo "[DEBUG]   Server: $smtp_server"
    [ "$DEBUG" = true ] && echo "[DEBUG]   Port: $smtp_port"
    [ "$DEBUG" = true ] && echo "[DEBUG]   Use SSL: $smtp_use_ssl"
    [ "$DEBUG" = true ] && echo "[DEBUG]   Auth: $smtp_auth"
    [ "$DEBUG" = true ] && echo "[DEBUG]   User: $smtp_user"
    [ "$DEBUG" = true ] && echo "[DEBUG]   From: $smtp_from_mail"
    [ "$DEBUG" = true ] && echo "[DEBUG]   Recipient: $recipient"

    if [ "$DEBUG" = true ] && [ -z "$recipient" ]; then
        echo "[DEBUG] Recipient is empty. Dumping /usr/syno/etc/synosmtp.conf:"
        cat /usr/syno/etc/synosmtp.conf 2>/dev/null | grep -E "mail|recipient|to=" || echo "[DEBUG] Could not read config file"
    fi

    # Check if required SMTP configuration is available (user/pass only required if auth is enabled)
    if [ -z "$smtp_server" ] || [ -z "$smtp_port" ]; then
        echo "Error: SMTP server not configured in DSM."
        echo "Please configure email notifications in DSM: Control Panel > Notification > Email"
        [ "$DEBUG" = true ] && echo "[DEBUG] Missing: server='$smtp_server' port='$smtp_port'"
        return 1
    fi

    if [ -z "$recipient" ]; then
        echo "Error: Recipient email address not configured."
        echo "Solution 1: Configure recipient in DSM: Control Panel > Notification > Email > Email tab"
        echo "            Make sure to enter an email address in the 'Email' field and click 'Apply'"
        echo "Solution 2: Use --email-to option: $filename --email --email-to your@email.com"
        [ "$DEBUG" = true ] && echo "[DEBUG] eventmails field in config is: '$(grep '^eventmails=' /usr/syno/etc/synosmtp.conf | cut -d'=' -f2)'"
        return 1
    fi

    # Check auth credentials only if authentication is enabled
    if [ "$smtp_auth" = "yes" ] || [ "$smtp_auth" = "true" ]; then
        if [ -z "$smtp_user" ] || [ -z "$smtp_pass" ]; then
            echo "Error: SMTP authentication is enabled but credentials are missing."
            echo "Please configure email notifications in DSM: Control Panel > Notification > Email"
            [ "$DEBUG" = true ] && echo "[DEBUG] Missing: user='$smtp_user' pass='[hidden]'"
            return 1
        fi
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

#-----------------------------------------------------------------------------
# Parse the command line arguments using getopt
#-----------------------------------------------------------------------------
filename=$(basename "$0")
PARSED_OPTIONS=$(getopt -n "$filename" -o ienvrdh --long info,email,email-to:,dry-run,running,verbose,debug,official-only,community-only,os-only,packages-only,help -- "$@")
retcode=$?
if [ $retcode != 0 ]; then
    usage
    exit 1
fi

#-----------------------------------------------------------------------------
# Extract the options and their arguments into variables
#-----------------------------------------------------------------------------
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
        --email-to)
            EMAIL_TO="$2"; shift 2 ;;
        -r|--running)
            RUNNING_ONLY=true; shift ;;

        --official-only)
            OFFICIAL_ONLY=true; shift ;;

        --community-only)
            COMMUNITY_ONLY=true; shift ;;

        --os-only)
            OS_ONLY=true; shift ;;

        --packages-only)
            PACKAGES_ONLY=true; shift ;;

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
# Validate that both filter options are not used together
#-----------------------------------------------------------------------------
if [ "$OFFICIAL_ONLY" = true ] && [ "$COMMUNITY_ONLY" = true ]; then
    echo "Error: Cannot use --official-only and --community-only together"
    usage
    exit 1
fi

#-----------------------------------------------------------------------------
# Validate that both OS and package filter options are not used together
#-----------------------------------------------------------------------------
if [ "$OS_ONLY" = true ] && [ "$PACKAGES_ONLY" = true ]; then
    echo "Error: Cannot use --os-only and --packages-only together"
    usage
    exit 1
fi

#-----------------------------------------------------------------------------
# Initialize output capture variable for INFO_MODE
#-----------------------------------------------------------------------------
INFO_OUTPUT=""
HTML_OUTPUT=""

#-----------------------------------------------------------------------------
# Print simulation mode message if dry-run is enabled
#-----------------------------------------------------------------------------
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

#-----------------------------------------------------------------------------
# Print system information
#-----------------------------------------------------------------------------
if [ "$INFO_MODE" = true ]; then
    msg=$(cat <<EOF

System Information
=============================================================================================================

$(printf "%-63s | %s\n" "Property" "Value")
$(printf "%-63s|%s\n" "----------------------------------------------------------------" "-------------------")
$(printf "%-63s | %s\n" "Product" "$product")
$(printf "%-63s | %s\n" "Model" "$model")
$(printf "%-63s | %s\n" "Architecture" "$arch")
$(printf "%-63s | %s\n" "Platform Name" "$platform_name")
$(printf "%-63s | %s\n" "Operating System" "$os_name")
$(printf "%-63s | %s\n" "Version" "$os_display_version")
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
        HTML_OUTPUT+="<tr><th style='border: 1px solid #ddd; padding: 8px; background-color: #90EE90; text-align: left; width: 48%;'>Property</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #90EE90; text-align: left; width: 52%;'>Value</th></tr>"
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
    printf "%s\n" "============================================================================================================="
    printf "\n"
    printf "%-63s | %s\n" "Property" "Value"
    printf "%-63s|%s\n" "----------------------------------------------------------------" "-------------------"
    printf "%-63s | %s\n" "Product" "$product"
    printf "%-63s | %s\n" "Model" "$model"
    printf "%-63s | %s\n" "Architecture" "$arch"
    printf "%-63s | %s\n" "Platform Name" "$platform_name"
    printf "%-63s | %s\n" "Operating System" "$os_name"
    printf "%-63s | %s\n" "Version" "$os_display_version"
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
if [ "$PACKAGES_ONLY" = false ]; then
if [ "$INFO_MODE" = true ]; then
    msg=$(cat <<EOF



Operating System Update Check
=============================================================================================================

$(printf "%-63s | %-15s | %-15s | %-6s\n" "Operating System" "Installed" "Latest" "Update")
$(printf "%-63s|%-15s|%-15s|%-6s\n" "----------------------------------------------------------------" "-----------------" "-----------------" "--------")
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
        HTML_OUTPUT+="<tr><th style='border: 1px solid #ddd; padding: 8px; background-color: #ADD8E6; text-align: left; width: 48%;'>Operating System</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #ADD8E6; text-align: left; width: 18%;'>Installed</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #ADD8E6; text-align: left; width: 16%;'>Latest</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #ADD8E6; text-align: left; width: 18%;'>Update</th></tr>"
    fi
else
    printf "\n\n\n"
    printf "%s\n" "Operating System Update Check"
    printf "%s\n" "============================================================================================================="
    printf "%s\n"
    # Print header for OS update table
    printf "%-63s | %-15s | %-15s | %-6s\n" "Operating System" "Installed" "Latest" "Update"
    printf "%-63s|%-15s|%-15s|%-6s\n" "----------------------------------------------------------------" "-----------------" "-----------------" "--------"
fi

#-----------------------------------------------------------------------------
# Fetch the OS archive page and parse for available versions
#-----------------------------------------------------------------------------
os_archive_url="https://archive.synology.com/download/Os/$os_name"
os_archive_html=$(curl -s "$os_archive_url")

#-----------------------------------------------------------------------------
# Initialize variables before the loop
#-----------------------------------------------------------------------------
os_url=""
os_latest=""
os_update_avail="-"
os_pat=""

#-----------------------------------------------------------------------------
# Parse available OS versions and check for updates
#-----------------------------------------------------------------------------
if [ $? -eq 0 ] && echo "$os_archive_html" | grep -q "href=\"/download/Os/$os_name/"; then
    all_os_versions=$(echo "$os_archive_html" | sed -n 's|.*href="/download/Os/'$os_name'/\([0-9][0-9.+-]*\)".*|\1|p' | sort -V -r)

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

                # Debug: show extracted model info
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
        msg=$(printf "%-63s | %-15s | %-15s | %-6s\n" "$os_name" "$os_display_version" "$os_latest" "$os_update_avail")
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
            msg=$(printf "\n*** OPERATING SYSTEM UPDATE AVAILABLE ***\n")
            if [ "$EMAIL_MODE" = false ]; then
                printf "%s" "$msg"
            fi
            INFO_OUTPUT+="$msg"$'\n'
            if [ "$EMAIL_MODE" = true ]; then
                HTML_OUTPUT+="<p style='margin-top: 10px; font-weight: bold; color: #FF0000; font-size: 16px;'>⚠️ OPERATING SYSTEM UPDATE AVAILABLE</p>"
            fi
            msg=$(printf "\nDownload Link: %s\n" "$os_url")
            if [ "$EMAIL_MODE" = false ]; then
                printf "%s" "$msg"
            fi
            INFO_OUTPUT+="$msg"$'\n'
        else
            # No OS update available
            msg=$(printf "\nNo operating system updates available. System is up to date.\n")
            if [ "$EMAIL_MODE" = false ]; then
                printf "%s" "$msg"
            fi
            INFO_OUTPUT+="$msg"$'\n'
            if [ "$EMAIL_MODE" = true ]; then
                HTML_OUTPUT+="<p style='margin-top: 10px; font-weight: bold; color: #228B22;'>✅ No operating system updates available. System is up to date.</p>"
            fi
        fi
    else
        printf "%-63s | %-15s | %-15s | %-6s\n" "$os_name" "$os_display_version" "$os_latest" "$os_update_avail"
        # Add download link or status message right after the table row
        if [ "$os_update_avail" = "X" ] && [ -n "$os_url" ]; then
            printf "\n*** OPERATING SYSTEM UPDATE AVAILABLE ***\n"
            printf "\nDownload Link: %s\n" "$os_url"
        else
            printf "\nNo operating system updates available. System is up to date.\n"
        fi
    fi
fi

fi  # End of OS_ONLY check

#-----------------------------------------------------------------------------
# PACKAGE UPDATE CHECK
# For each installed package:
# 1. First check via synopkg checkupdate (official update channel)
# 2. If no update found, query Synology archive server for newer versions
# 3. Verify architecture and OS compatibility (DSM vs BSM)
# 4. Collect packages with available updates for later download
# 5. Display results in table format with version comparison
#-----------------------------------------------------------------------------
if [ "$OS_ONLY" = false ]; then
if [ "$INFO_MODE" = true ]; then
    msg=$(cat <<EOF



Package Update Check
=============================================================================================================

$(printf "%-30s | %-30s | %-15s | %-15s | %-6s\n" "Package" "Source" "Installed" "Latest" "Update")
$(printf "%-30s|%-30s|%-15s|%-15s|%-6s\n" "-------------------------------" "--------------------------------" "-----------------" "-----------------" "--------")
EOF
)
    if [ "$EMAIL_MODE" = false ]; then
        printf "%s\n" "$msg"
    fi
    INFO_OUTPUT+="$msg"$'\n'

    # Build HTML table for email
    if [ "$EMAIL_MODE" = true ]; then
        # Determine chapter number: 2 if OS check was skipped (--packages-only), otherwise 3
        if [ "$PACKAGES_ONLY" = true ]; then
            chapter_num="2"
        else
            chapter_num="3"
        fi
        HTML_OUTPUT+="<h2>${chapter_num}. Packages</h2>"
        HTML_OUTPUT+="<table style='border-collapse: collapse; width: 100%; margin-bottom: 20px;'>"
        HTML_OUTPUT+="<tr><th style='border: 1px solid #ddd; padding: 8px; background-color: #FFA500; text-align: left; width: 31%;'>Package</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #FFA500; text-align: left; width: 17%;'>Source</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #FFA500; text-align: left; width: 18%;'>Installed</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #FFA500; text-align: left; width: 16%;'>Latest</th><th style='border: 1px solid #ddd; padding: 8px; background-color: #FFA500; text-align: left; width: 18%;'>Update</th></tr>"
    fi
else
    printf "\n\n\n"
    printf "Package Update Check\n"
    printf "%s\n" "============================================================================================================="
    printf "%s\n"
    # Print header for package update table
    printf "%-30s | %-30s | %-15s | %-15s | %-6s\n" "Package" "Source" "Installed" "Latest" "Update"
    printf "%-30s|%-30s|%-15s|%-15s|%-6s\n" "-------------------------------" "--------------------------------" "-----------------" "-----------------" "--------"
fi

#-----------------------------------------------------------------------------
# Initialize arrays to track packages with available updates:
# - download_apps: package names
# - downlaod_revisions: new version numbers
# - download_links: download URLs for .spk files
# - downlaod_files: local file paths after download
#-----------------------------------------------------------------------------
declare -a download_apps=()
declare -a downlaod_revisions=()
declare -a download_links=()
declare -a downlaod_files=()

# Count total installed packages
total_installed_packages=0

# Count total running packages (when RUNNING_ONLY is enabled)
total_running_packages=0

# Iterate through all installed packages and check for updates
for app in $(synopkg list --name | sort); do
    # Get package maintainer/source
    pkg_distributor=$(get_package_distributor "$app")
    [ "$DEBUG" = true ] && echo "[DEBUG] Package: $app, Maintainer: $pkg_distributor"

    # Apply source filters
    if [ "$OFFICIAL_ONLY" = true ]; then
        if ! is_official_package "$app"; then
            [ "$DEBUG" = true ] && echo "[DEBUG] Skipping $app (not official, maintainer: $pkg_distributor)"
            continue
        fi
    fi

    if [ "$COMMUNITY_ONLY" = true ]; then
        if is_official_package "$app"; then
            [ "$DEBUG" = true ] && echo "[DEBUG] Skipping $app (not community, maintainer: $pkg_distributor)"
            continue
        fi
    fi

    # Skip non-running packages if RUNNING_ONLY is enabled
    if [ "$RUNNING_ONLY" = true ]; then
        pkg_status_output=$(synopkg status "$app" 2>/dev/null)
        pkg_status=$(echo "$pkg_status_output" | jq -r '.status')
        if [ "$pkg_status" != "running" ]; then
            [ "$DEBUG" = true ] && echo "[DEBUG] Skipping $app (status: $pkg_status)"
            continue
        fi
        # Count running packages
        ((total_running_packages++))
    fi

    # Count packages after filters are applied
    ((total_installed_packages++))

    # Identify currently installed revision
    installed_revision=$(synopkg version $app)

    # Initialize variables for this package iteration
    latest_revision="$installed_revision"
    url=""
    spk=""
    update_avail="-"
    found=""

    # Check Synology archive server for available updates if distributor is Synology itself
    if is_official_package "$app"; then
        archive_url="https://archive.synology.com/download/Package/$app"
        [ "$DEBUG" = true ] && echo "[DEBUG] Checking Synology archive server: $archive_url"
        archive_html=$(curl -s "$archive_url")
    else
        # For community packages, skip Synology archive check
        archive_html=""
    fi

    if [ -n "$archive_html" ] && echo "$archive_html" | grep -q "href=\"/download/Package/$app/"; then
        # Extract all version folders, sort numerically descending (latest first)
        all_versions=$(echo "$archive_html" | sed -n 's|.*href="/download/Package/'$app'/\([0-9][0-9.+-]*\)".*|\1|p' | sort -V -r)
        found=""
        for version in $all_versions; do
            [ "$DEBUG" = true ] && echo "[DEBUG] Checking version: $version (installed: $installed_revision)"

            # Check if version is newer than current installed_revision
            if [[ "$version" != "$installed_revision" ]] && [[ $(printf '%s\n%s' "$installed_revision" "$version" | sort -V | head -1) == "$installed_revision" ]]; then
                [ "$DEBUG" = true ] && echo "[DEBUG] Version $version is newer than $installed_revision"

                # Check if there's an SPK for the current architecture and OS
                version_url="https://archive.synology.com/download/Package/$app/$version"
                version_html=$(curl -s "$version_url")

                [ "$DEBUG" = true ] && echo "[DEBUG] Looking for SPK with arch=$arch OR platform=$platform_name"

                if [ "$os_name" = "BSM" ]; then
                    if echo "$version_html" | grep -qiE "BSM.*(${arch}|${platform_name}).*\.spk"; then
                        latest_revision="$version"
                        # grep the name of the spk file - check both arch and platform
                        spk=$(echo "$version_html" | grep -oiE "[^/\"']*BSM[^/\"']*(${arch}|${platform_name})[^\"']*\.spk" | head -1)
                        url=$(echo "$version_html" | grep -oE "href=\"[^\"']*/download/Package/spk/[^\"']*BSM[^\"']*(${arch}|${platform_name})[^\"']*\.spk\"" | head -1 | sed 's|href="||;s|"||')
                        download_apps+=("$app")
                        downlaod_revisions+=("$latest_revision")
                        download_links+=("$url")
                        update_avail="X"
                        found="yes"
                        [ "$DEBUG" = true ] && echo "[DEBUG] Found BSM SPK: $spk"
                        break
                    fi
                else
                    # Check for DSM packages - look for arch OR platform_name, but exclude BSM
                    if echo "$version_html" | grep -qiE "(${arch}|${platform_name}).*\.spk" && ! echo "$version_html" | grep -q "BSM"; then
                        latest_revision="$version"
                        # grep the name of the spk file - check both arch and platform
                        spk=$(echo "$version_html" | grep -oiE "[^/\"']*[-](${arch}|${platform_name})[-][^\"']*\.spk" | head -1)
                        url=$(echo "$version_html" | grep -oE "href=\"[^\"']*/download/Package/spk/[^\"']*(${arch}|${platform_name})[^\"']*\.spk\"" | head -1 | sed 's|href="||;s|"||')

                        # If URL is found, prepend domain if relative
                        if [ -n "$url" ] && [[ "$url" =~ ^/ ]]; then
                            url="https://archive.synology.com${url}"
                        fi

                        download_apps+=("$app")
                        downlaod_revisions+=("$latest_revision")
                        download_links+=("$url")
                        update_avail="X"
                        found="yes"
                        [ "$DEBUG" = true ] && echo "[DEBUG] Found DSM SPK: $spk (URL: $url)"
                        break
                    else
                        [ "$DEBUG" = true ] && echo "[DEBUG] No SPK found for arch=$arch or platform=$platform_name in version $version"
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
        # No update found on Synology archive or this is a community package - check community repositories
        if ! is_official_package "$app"; then
            [ "$DEBUG" = true ] && echo "[DEBUG] Checking community repositories for $app..."

            # Determine community repository based on distributor field
            # Convert distributor to lowercase for matching
            community=$(echo "$pkg_distributor" | tr '[:upper:]' '[:lower:]')
            [ "$DEBUG" = true ] && echo "[DEBUG] Checking community: $community (from distributor: $pkg_distributor)"

            case "$community" in
                SynoCommunity*|synocommunity*|SynoCommunity|synocommunity)
                        # Check SynoCommunity package page
                        synocommunity_pkg_url="https://synocommunity.com/package/$app"
                        [ "$DEBUG" = true ] && echo "[DEBUG] Checking SynoCommunity server: $synocommunity_pkg_url"
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
                                        url="$spk_url"
                                        download_apps+=("$app")
                                        downlaod_revisions+=("$latest_revision")
                                        download_links+=("$spk_url")
                                        update_avail="X"
                                        found="yes"
                                        break  # Break out of version loop
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
                        [ "$DEBUG" = true ] && echo "[DEBUG] No matching community server for distributor: $pkg_distributor"
                        ;;
            esac
        fi

        if [ -z "$found" ]; then
            spk=""
            download_link=""
            update_avail="-"
            latest_revision="$installed_revision"
        fi
    fi
    if [ "$INFO_MODE" = true ]; then
        msg=$(printf "%-30s | %-30s | %-15s | %-15s | %-6s\n" "$app" "$pkg_distributor" "$installed_revision" "$latest_revision" "$update_avail")
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

            # Add visual indicator for package source
            if is_official_package "$app"; then
                # Official package - blue badge with source name
                source_display="<span style='background-color: #1E90FF; color: white; padding: 2px 6px; border-radius: 3px; font-size: 11px; font-weight: bold;'>🏢 OFFICIAL</span><br><span style='font-size: 10px; color: #666;'>$pkg_distributor</span>"
            else
                # Community package - purple badge with source name
                source_display="<span style='background-color: #9B59B6; color: white; padding: 2px 6px; border-radius: 3px; font-size: 11px; font-weight: bold;'>👥 COMMUNITY</span><br><span style='font-size: 10px; color: #666;'>$pkg_distributor</span>"
            fi

            HTML_OUTPUT+="<tr><td style='border: 1px solid #ddd; padding: 4px;'>$app</td><td style='border: 1px solid #ddd; padding: 4px;'>$source_display</td><td style='border: 1px solid #ddd; padding: 4px;'>$installed_revision</td><td style='border: 1px solid #ddd; padding: 4px;'>$latest_revision_display</td><td style='border: 1px solid #ddd; padding: 4px; text-align: center;'>$update_icon</td></tr>"
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
        printf "%-30s | %-30s | %-15s | %-15s | %-6s\n" "$app" "$pkg_distributor" "$installed_revision" "$latest_revision" "$update_avail"

        # Add download link right after the table if update is available
        if [ "$update_avail" = "X" ] && [ -n "$download_link" ]; then
            printf "\nDownload Link: %s\n" "$download_link"
        fi
    fi
done

#-----------------------------------------------------------------------------
# DOWNLOAD UPDATEABLE PACKAGES
# If any packages have updates available, print download links and download .spk files
#-----------------------------------------------------------------------------

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
                printf "[DRY RUN MODE] Skipping download of %s\n" $(basename "$url")
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

#-----------------------------------------------------------------------------
# FINAL STATUS MESSAGES
#-----------------------------------------------------------------------------
# Close HTML table for packages
if [ "$EMAIL_MODE" = true ]; then
    HTML_OUTPUT+="</table>"
fi

# Display status message after package table
if [ ${#download_apps[@]} -gt 0 ]; then
    # Updates available
    if [ "$INFO_MODE" = true ]; then
        msg=$(printf "\n*** PACKAGE UPDATES AVAILABLE ***\n")
        if [ "$EMAIL_MODE" = false ]; then
            printf "%s" "$msg"
        fi
        INFO_OUTPUT+="$msg"$'\n'
        if [ "$EMAIL_MODE" = true ]; then
            HTML_OUTPUT+="<p style='margin-top: 10px; font-weight: bold; color: #FF0000; font-size: 16px;'>⚠️ PACKAGE UPDATES AVAILABLE</p>"
        fi
    else
        printf "\n*** PACKAGE UPDATES AVAILABLE ***\n"
    fi
elif [ ${#download_apps[@]} -eq 0 ]; then
    if [ "$INFO_MODE" = true ]; then
        # No package updates available
        msg=$(printf "\nNo package updates available. All packages are up to date.\n")
        if [ "$EMAIL_MODE" = false ]; then
            printf "%s" "$msg"
        fi
        INFO_OUTPUT+="$msg"$'\n'
        if [ "$EMAIL_MODE" = true ]; then
            HTML_OUTPUT+="<p style='margin-top: 10px; font-weight: bold; color: #228B22;'>✅ No package updates available. All packages are up to date.</p>"
        fi
    else
        printf "\nNo package updates available. All packages are up to date.\n"
    fi
fi

# Display total count of packages with available updates
amount=${#download_apps[@]}
if [ "$INFO_MODE" = true ]; then
    if [ "$RUNNING_ONLY" = true ]; then
        if [ "$amount" -eq 0 ]; then
            msg=$(printf "\nTotal running packages: %d" "$total_running_packages")
        else
            msg=$(printf "\nTotal running packages: %d\nTotal packages with updates available: %d" "$total_running_packages" "$amount")
        fi
    else
        if [ "$amount" -eq 0 ]; then
            msg=$(printf "\nTotal installed packages: %d" "$total_installed_packages")
        else
            msg=$(printf "\nTotal installed packages: %d\nTotal packages with updates available: %d" "$total_installed_packages" "$amount")
        fi
    fi
    if [ "$EMAIL_MODE" = false ]; then
        printf "%s\n" "$msg"
    fi
    INFO_OUTPUT+="$msg"$'\n'

    # Add summary to HTML
    if [ "$EMAIL_MODE" = true ]; then
        if [ "$RUNNING_ONLY" = true ]; then
            HTML_OUTPUT+="<p style='margin-top: 20px; font-weight: bold;'>Total running packages: $total_running_packages</p>"
        else
            HTML_OUTPUT+="<p style='margin-top: 20px; font-weight: bold;'>Total installed packages: $total_installed_packages</p>"
        fi
        if [ "$amount" -gt 0 ]; then
            HTML_OUTPUT+="<p style='font-weight: bold;'>Total packages with updates available: $amount</p>"
        fi
    fi
else
    printf "\n"
    if [ "$RUNNING_ONLY" = true ]; then
        printf "Total running packages: %d\n" "$total_running_packages"
    else
        printf "Total installed packages: %d\n" "$total_installed_packages"
    fi
    if [ "$amount" -gt 0 ]; then
        printf "Total packages with updates available: %d\n" "$amount"
    fi
fi

fi  # End of PACKAGES_ONLY check

#-----------------------------------------------------------------------------
# INFO MODE EMAIL REPORTING
# If INFO_MODE is enabled, send email report with update information
#-----------------------------------------------------------------------------

# Exit if in info mode
if [ "$INFO_MODE" = true ]; then
    # Ensure proper termination with newline for non-email mode
    if [ "$EMAIL_MODE" = false ]; then
        printf "\n"
    fi
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
    # Only print message if not in OS_ONLY mode (message already shown after OS table)
    # and not in INFO_MODE (message already shown after package table)
    if [ "$INFO_MODE" = false ] && [ "$OS_ONLY" = false ]; then
        printf "\n\n"
        printf "No packages to update. Exiting.\n"
    fi
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
                                printf "[DRY RUN MODE] Skipping installation of %s\n" $(basename "$selected_file")
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
                                printf "[DRY RUN MODE] Skipping installation of %s\n" $(basename "$selected_file")
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
