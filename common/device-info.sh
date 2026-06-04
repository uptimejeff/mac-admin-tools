#!/usr/bin/env bash
# common/device-info.sh — Collect device hardware, power, USB, and location info
# 2026-06-04 v1.0
# Source this file; do not execute directly.
#
# After sourcing, call: collect_device_info
# Populates globals: DI_MODEL DI_SERIAL DI_OS DI_CHIP DI_MAGSAFE
#                    DI_AC DI_BATT_PCT DI_ADAPTER
#                    DI_USB_TOPOLOGY DI_TB_PORTS DI_TB_DEVICES
#                    DI_PUBLIC_IP DI_LOCATION DI_LOCATION_NOTE
#                    DI_CONSOLE_USER

collect_device_info() {
    # --- Hardware ---
    DI_MODEL=$(system_profiler SPHardwareDataType 2>/dev/null \
        | awk -F': ' '/Model Name/{print $2}' | xargs)
    DI_SERIAL=$(system_profiler SPHardwareDataType 2>/dev/null \
        | awk -F': ' '/Serial Number \(system\)/{print $2}' | xargs)
    DI_CHIP=$(system_profiler SPHardwareDataType 2>/dev/null \
        | awk -F': ' '/Chip/{print $2}' | xargs)
    DI_OS=$(sw_vers -productVersion 2>/dev/null)
    DI_CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null)

    # MagSafe capable: MacBook Pro 14/16" M1 Pro/Max and later have MagSafe
    # Model identifiers with MagSafe: MacBookPro18,x and later MBP
    local hw_model
    hw_model=$(sysctl -n hw.model 2>/dev/null)
    DI_MAGSAFE="No"
    # MagSafe returned with MacBookPro18,1+ (14/16" M1 Pro/Max) and newer MBP
    if echo "$hw_model" | grep -qE 'MacBookPro(1[89]|[2-9][0-9]),'; then
        DI_MAGSAFE="Yes"
    fi

    # --- Power ---
    local batt_output
    batt_output=$(pmset -g batt 2>/dev/null)
    DI_AC=$(echo "$batt_output" | grep -c "AC Power")
    DI_BATT_PCT=$(echo "$batt_output" | grep -oE '[0-9]+%' | head -1)

    # Adapter details from ioreg
    DI_ADAPTER=$(ioreg -r -c AppleSmartBattery 2>/dev/null \
        | grep '"AdapterDetails"' \
        | grep -oE '"Name"="[^"]*"' | head -1 \
        | sed 's/"Name"="\(.*\)"/\1/')
    [[ -z "$DI_ADAPTER" ]] && DI_ADAPTER="unknown"

    # Adapter wattage
    local adapter_watts
    adapter_watts=$(ioreg -r -c AppleSmartBattery 2>/dev/null \
        | grep '"AdapterDetails"' \
        | grep -oE '"Watts"=[0-9]+' | head -1 \
        | sed 's/"Watts"=//')
    [[ -n "$adapter_watts" ]] && DI_ADAPTER="${adapter_watts}W ${DI_ADAPTER}"

    # --- USB topology ---
    local usb_raw
    usb_raw=$(system_profiler SPUSBDataType 2>/dev/null)
    DI_USB_TOPOLOGY=$(echo "$usb_raw" \
        | grep -iE "^\s+(Product ID:|Manufacturer:|Capacity:)" \
        | grep -v "Bluetooth\|Camera\|Keyboard\|Trackpad\|Headphone\|FaceTime\|Hub\|Touch\|Wireless\|USB Receiver" \
        | sed 's/^[[:space:]]*//' | tr '\n' ' | ' | sed 's/ | $//')
    [[ -z "$DI_USB_TOPOLOGY" ]] && DI_USB_TOPOLOGY="No external USB devices detected"

    # Thunderbolt ports
    local tb_raw
    tb_raw=$(system_profiler SPThunderboltDataType 2>/dev/null)
    DI_TB_PORTS=$(echo "$tb_raw" | grep -c "Receptacle:")
    DI_TB_DEVICES=$(echo "$tb_raw" | grep "Device Name:" \
        | grep -v "MacBook\|Mac mini\|iMac\|Mac Pro\|Mac Studio" \
        | sed 's/.*Device Name: //' | xargs | tr ' ' ',' | sed 's/,/, /g')
    [[ -z "$DI_TB_DEVICES" ]] && DI_TB_DEVICES="none"

    # --- Location via public IP ---
    DI_PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null)
    DI_LOCATION="unknown"
    DI_LOCATION_NOTE=""

    if [[ -n "$DI_PUBLIC_IP" ]]; then
        local geo
        geo=$(curl -fsSL --max-time 5 "https://ipinfo.io/${DI_PUBLIC_IP}/json" 2>/dev/null)
        if [[ -n "$geo" ]]; then
            local city region org
            city=$(echo "$geo"   | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("city",""))' 2>/dev/null)
            region=$(echo "$geo" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("region",""))' 2>/dev/null)
            org=$(echo "$geo"    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("org",""))' 2>/dev/null)
            DI_LOCATION="${city}, ${region} (${org})"

            # Known office IPs — flag as office
            case "$DI_PUBLIC_IP" in
                72.203.214.*|70.191.128.*)
                    DI_LOCATION_NOTE="likely: office"
                    ;;
                *)
                    DI_LOCATION_NOTE="likely: home or remote"
                    ;;
            esac
        fi
    fi
}
