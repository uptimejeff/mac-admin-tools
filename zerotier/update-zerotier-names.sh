#!/usr/bin/env bash
# update-zerotier-names.sh
# Updates ZeroTier member name and description for this device via the ZeroTier API.
# Intended for MDM deployment (runs as root). Injected env vars supply credentials.
# 2026-06-05 v1.3 — Mosyle-compliant single-line output; remove redundant sudo; suppress noise

OK=$'\xe2\x9c\x85'
FAIL=$'\xe2\x9d\x8c'
WARN=$'\xe2\x9a\xa0'

# --- Credentials (injected by MDM wrapper, not stored here) ---
if [[ -z "$ZT_NETWORK" || -z "$ZT_TOKEN" ]]; then
    echo "${FAIL} [FAIL] ZT_NETWORK and ZT_TOKEN must be set as environment variables"
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "${FAIL} [FAIL] must run as root"
    exit 1
fi

sanitize() {
    echo "$1" | sed "s/[^a-zA-Z0-9_ .',()-]/_/g"
}

ZT_CLI="/usr/local/bin/zerotier-cli"

# --- Install ZeroTier if missing ---
if ! "$ZT_CLI" status >/dev/null 2>&1; then
    curl -sf https://install.zerotier.com | bash >/dev/null 2>&1
    if ! "$ZT_CLI" status >/dev/null 2>&1; then
        echo "${FAIL} [FAIL] ZeroTier install failed"
        exit 1
    fi
fi

# --- Join network if not already a member ---
if ! "$ZT_CLI" listnetworks 2>/dev/null | grep -q "$ZT_NETWORK"; then
    "$ZT_CLI" join "$ZT_NETWORK" >/dev/null 2>&1
    sleep 3
    if ! "$ZT_CLI" listnetworks 2>/dev/null | grep -q "$ZT_NETWORK"; then
        echo "${FAIL} [FAIL] could not join ZT network ${ZT_NETWORK}"
        exit 1
    fi
fi

# --- Gather device info ---
ZT_URL="https://my.zerotier.com/api"
ZT_NODE=$("$ZT_CLI" info 2>/dev/null | awk '{print $3}')
ZT_SERIAL=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Serial Number/{print $NF}')
ZT_DATE=$(date +"%Y-%m-%d_%H%M")

INACTIVE_FLAG="/Library/osxgroup/device-inactive"
COMPUTER_NAME=$(scutil --get ComputerName 2>/dev/null || echo "unknown")
OS_VER=$(sw_vers --productVersion 2>/dev/null || sw_vers -productVersion 2>/dev/null)

if [[ -f "$INACTIVE_FLAG" ]]; then
    ZT_NAME=$(sanitize "${COMPUTER_NAME} [old] (${OS_VER})")
else
    ZT_NAME=$(sanitize "${COMPUTER_NAME} (${OS_VER})")
fi

if [[ -z "$ZT_SERIAL" ]]; then
    ZT_DESCRIPTION="ERR:no_serial | ${ZT_DATE}"
else
    ZT_DESCRIPTION="SN:${ZT_SERIAL} | ${ZT_DATE}"
fi

if [[ -z "$ZT_NODE" ]]; then
    echo "${FAIL} [FAIL] could not read ZeroTier node ID"
    exit 1
fi

# --- Push to ZeroTier API ---
ZT_PAYLOAD=$(printf '{"name":"%s","description":"%s","config":{"authorized":true}}' \
    "$ZT_NAME" "$ZT_DESCRIPTION")

HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "${ZT_URL}/network/${ZT_NETWORK}/member/${ZT_NODE}" \
    -H "Authorization: Bearer ${ZT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$ZT_PAYLOAD")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "${OK} [OK] node=${ZT_NODE} | name=${ZT_NAME} | ${ZT_DESCRIPTION} | HTTP=${HTTP_CODE}"
    exit 0
else
    echo "${FAIL} [FAIL] node=${ZT_NODE} | HTTP=${HTTP_CODE} | name=${ZT_NAME}"
    exit 1
fi
