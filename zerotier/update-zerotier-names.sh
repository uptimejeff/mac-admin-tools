#!/usr/bin/env bash

# Script Purpose:
# This script updates the name and description of a device in the ZeroTier network.
# It is intended to be run on macOS devices managed by an MDM solution.
# 2026-06-04 v1.2 — suppress system_profiler stderr; clean API output; [old] flag support

# --- Configuration ---

# ZeroTier Network ID and API Token.
# Injected by Mosyle — do NOT hardcode here (this file is public on GitHub).
# Set in the Mosyle script header:
#   export ZT_NETWORK="your_network_id"
#   export ZT_TOKEN="your_api_token"
#   curl -fsSL https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main/zerotier/update-zerotier-names.sh | bash
if [[ -z "$ZT_NETWORK" || -z "$ZT_TOKEN" ]]; then
    echo "[FAIL] ZT_NETWORK and ZT_TOKEN must be set as environment variables"
    exit 1
fi

# --- Script Body ---

# Exit if the script is not run as root.
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Function to sanitize a string, replacing special characters with underscores.
sanitize() {
    echo "$1" | sed "s/[^a-zA-Z0-9_ .',()-]/_/g"
}

# Check if ZeroTier is installed. If not, install it.
if ! /usr/local/bin/zerotier-cli status > /dev/null 2>&1; then
    echo "Installing ZeroTier..."
    curl -sf https://install.zerotier.com | bash
fi

# Join the ZeroTier network if the device is not already a member.
if ! sudo /usr/local/bin/zerotier-cli listnetworks | grep -q "$ZT_NETWORK"; then
    echo "Joining ZeroTier network: $ZT_NETWORK"
    sudo /usr/local/bin/zerotier-cli join "$ZT_NETWORK"
    # Verify that the device successfully joined the network.
    if ! sudo /usr/local/bin/zerotier-cli listnetworks | grep -q "$ZT_NETWORK"; then
        echo "Error: Failed to join the ZeroTier network."
        exit 1
    fi
fi

# --- ZeroTier API Interaction ---

# Set the ZeroTier API URL.
ZT_URL="https://my.zerotier.com/api"

# Get the ZeroTier Node ID for this device.
ZT_NODE=$(sudo /usr/local/bin/zerotier-cli info | awk '{print $3}')

# Get the device's serial number.
ZT_SERIAL=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Serial Number/{print $NF}')

# Get the current date and time.
ZT_DATE=$(date +"%Y-%m-%d_%H%M")

# Sanitize the computer name for the 'name' field.
# If /Library/osxgroup/device-inactive exists, append [old] to mark decommissioned devices.
# Deploy that flag file via Mosyle to mark old/spare devices without changing Computer Name.
INACTIVE_FLAG="/Library/osxgroup/device-inactive"
if [[ -f "$INACTIVE_FLAG" ]]; then
    ZT_NAME=$(sanitize "$(scutil --get ComputerName) [old] ($(sw_vers --productVersion))")
else
    ZT_NAME=$(sanitize "$(scutil --get ComputerName) ($(sw_vers --productVersion))")
fi

# Check if the serial number was retrieved successfully.
# If not, create a description with an error message.
if [ -z "$ZT_SERIAL" ]; then
    ZT_DESCRIPTION="ERR: No Serial, ${ZT_DATE}"
else
    ZT_DESCRIPTION="SN:${ZT_SERIAL}, ${ZT_DATE}"
fi

# Prepare the JSON payload for the API request.
ZT_PAYLOAD=$(cat <<EOF
{
    "name": "${ZT_NAME}",
    "description": "${ZT_DESCRIPTION}",
    "config": { "authorized": true }
}
EOF
)

# Update the node details using the ZeroTier API.
echo "Updating ZeroTier: ${ZT_NAME} | ${ZT_DESCRIPTION}"
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${ZT_URL}/network/${ZT_NETWORK}/member/${ZT_NODE}" \
    -H "Authorization: Bearer ${ZT_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-ZT-Auth: ${ZT_TOKEN}" \
    -d "${ZT_PAYLOAD}")

if [ "$HTTP_CODE" = "200" ]; then
    echo "[OK] ZeroTier updated (HTTP ${HTTP_CODE})"
else
    echo "[FAIL] ZeroTier API returned HTTP ${HTTP_CODE}"
    exit 1
fi
exit 0