#!/usr/bin/env bash
# common/device-info.sh — Collect device hardware, power, USB, and location info
# 2026-06-04 v1.4 — office IP detection via OFFICE_IP_PREFIXES env var (client-configurable)
# Source this file; do not execute directly.
#
# After sourcing, call: collect_device_info
# Populates globals: DI_MODEL DI_SERIAL DI_OS DI_CHIP DI_MAGSAFE
#                    DI_AC DI_BATT_PCT DI_ADAPTER
#                    DI_USB_TOPOLOGY DI_TB_PORTS DI_TB_DEVICES
#                    DI_PUBLIC_IP DI_LOCATION DI_LOCATION_NOTE
#                    DI_CONSOLE_USER

collect_device_info() {
    # --- Hardware (single system_profiler call) ---
    local hw_info
    hw_info=$(system_profiler SPHardwareDataType 2>/dev/null)
    DI_MODEL=$(echo "$hw_info"  | awk -F': ' '/Model Name/{print $2}' | xargs)
    DI_SERIAL=$(echo "$hw_info" | awk -F': ' '/Serial Number \(system\)/{print $2}' | xargs)
    DI_CHIP=$(echo "$hw_info"   | awk -F': ' '/Chip/{print $2}' | xargs)
    DI_OS=$(sw_vers -productVersion 2>/dev/null)
    DI_CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null)

    # MagSafe detection
    # MacBook Pro 14"/16" M1 Pro/Max (2021+) use MacBookPro18,x and later identifiers.
    # Apple shifted to Mac1x,x format with M4 (2024+). Check both.
    # Most reliable: look for MagSafe in SPPowerDataType.
    DI_MAGSAFE="No"
    if system_profiler SPPowerDataType 2>/dev/null | grep -q "MagSafe"; then
        DI_MAGSAFE="Yes"
    fi

    # --- Power ---
    local batt_output
    batt_output=$(pmset -g batt 2>/dev/null)
    DI_AC=0
    echo "$batt_output" | grep -q "AC Power" && DI_AC=1
    DI_BATT_PCT=$(echo "$batt_output" | grep -oE '[0-9]+%' | head -1)

    # Adapter details from ioreg (single call)
    local ioreg_batt
    ioreg_batt=$(ioreg -r -c AppleSmartBattery 2>/dev/null | grep '"AdapterDetails"')
    # Try "Name" first (M1-M3), fall back to "Description" (M4+)
    DI_ADAPTER=$(echo "$ioreg_batt" | grep -oE '"Name"="[^"]*"' | head -1 \
        | sed 's/"Name"="\(.*\)"/\1/')
    if [[ -z "$DI_ADAPTER" ]]; then
        DI_ADAPTER=$(echo "$ioreg_batt" | grep -oE '"Description"="[^"]*"' | head -1 \
            | sed 's/"Description"="\(.*\)"/\1/')
    fi
    local adapter_watts
    adapter_watts=$(echo "$ioreg_batt" | grep -oE '"Watts"=[0-9]+' | head -1 \
        | sed 's/"Watts"=//')
    [[ -z "$DI_ADAPTER" ]] && DI_ADAPTER="unknown"
    # Prepend actual wattage, stripping any existing wattage prefix from the name
    if [[ -n "$adapter_watts" ]]; then
        DI_ADAPTER=$(echo "$DI_ADAPTER" | sed 's/^[0-9]*W //')
        DI_ADAPTER="${adapter_watts}W ${DI_ADAPTER}"
    fi

    # --- USB topology (single call) ---
    local usb_raw
    usb_raw=$(system_profiler SPUSBDataType 2>/dev/null)
    DI_USB_TOPOLOGY=$(echo "$usb_raw" \
        | grep -iE "^\s+(Product ID:|Manufacturer:|Capacity:)" \
        | grep -v "Bluetooth\|Camera\|Keyboard\|Trackpad\|Headphone\|FaceTime\|Hub\|Touch\|Wireless\|USB Receiver" \
        | sed 's/^[[:space:]]*//' | tr '\n' ' | ' | sed 's/ | $//') || true
    [[ -z "$DI_USB_TOPOLOGY" ]] && DI_USB_TOPOLOGY="No external USB devices detected"

    # --- Thunderbolt (single call) ---
    local tb_raw
    tb_raw=$(system_profiler SPThunderboltDataType 2>/dev/null)
    DI_TB_PORTS=$(echo "$tb_raw" | grep -c "Receptacle:" || true)
    DI_TB_DEVICES=$(echo "$tb_raw" \
        | grep "Device Name:" \
        | grep -v "MacBook\|Mac mini\|iMac\|Mac Pro\|Mac Studio" \
        | sed 's/.*Device Name: //' | xargs | tr ' ' ',' | sed 's/,/, /g') || true
    [[ -z "$DI_TB_DEVICES" ]] && DI_TB_DEVICES="none"

    # --- Location via public IP (single call, IPv4 forced) ---
    DI_PUBLIC_IP="unknown"
    DI_LOCATION="unknown"
    DI_LOCATION_NOTE=""

    local geo
    geo=$(curl -4 -fsSL --max-time 5 https://ipinfo.io/json 2>/dev/null || true)

    if [[ -n "$geo" ]]; then
        local ip city region org
        ip=$(python3 -c     'import json,sys; d=json.load(sys.stdin); print(d.get("ip",""))' \
            <<< "$geo" 2>/dev/null || true)
        city=$(python3 -c   'import json,sys; d=json.load(sys.stdin); print(d.get("city",""))' \
            <<< "$geo" 2>/dev/null || true)
        region=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("region",""))' \
            <<< "$geo" 2>/dev/null || true)
        org=$(python3 -c    'import json,sys; d=json.load(sys.stdin); print(d.get("org",""))' \
            <<< "$geo" 2>/dev/null || true)

        [[ -n "$ip" ]] && DI_PUBLIC_IP="$ip"

        # Build location string — fall back gracefully if geo data is sparse
        if [[ -n "$city" && -n "$region" ]]; then
            DI_LOCATION="${city}, ${region}"
            [[ -n "$org" ]] && DI_LOCATION="${DI_LOCATION} (${org})"
        elif [[ -n "$org" ]]; then
            DI_LOCATION="$org"
        elif [[ -n "$ip" ]]; then
            DI_LOCATION="$ip (no geo data)"
        fi

        # OFFICE_IP_PREFIXES: space-separated list of IP prefixes that identify
        # your office network (e.g. "203.0.113. 198.51.100."). Leave unset for
        # generic remote/home classification only.
        DI_LOCATION_NOTE="likely: remote"
        if [[ -n "${OFFICE_IP_PREFIXES:-}" ]]; then
            for _pfx in $OFFICE_IP_PREFIXES; do
                if [[ "$DI_PUBLIC_IP" == ${_pfx}* ]]; then
                    DI_LOCATION_NOTE="likely: office"
                    break
                fi
            done
        fi
    fi
}
