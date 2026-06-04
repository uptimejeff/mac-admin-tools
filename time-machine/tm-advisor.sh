#!/usr/bin/env bash
# time-machine/tm-advisor.sh — Time Machine status advisor for Mosyle
# 2026-06-04 v1.2 — fix: "0 days" → "today"; fix adapter wattage doubling
#                        scope; fix lib loading via temp files; add logfile;
#                        fix date math; deduplicate plutil calls
#
# Collects Time Machine status and sends Slack alerts based on days since
# last successful backup to external destination.
#
# Severity thresholds:
#   NOTICE  >= TM_THRESHOLD_NOTICE  days (default 4)  → IT channel
#   ALERT   >= TM_THRESHOLD_ALERT   days (default 7)  → IT channel
#   URGENT  >= TM_THRESHOLD_URGENT  days (default 14) → IT channel
#
# Required env vars (set in Mosyle):
#   SLACK_ITDEPT_ALERTS        — IT channel incoming webhook URL
#
# Optional env vars:
#   SLACK_BOT_TOKEN            — xoxb- token for user DMs (Phase 2)
#   TM_THRESHOLD_NOTICE        — days before NOTICE (default 4)
#   TM_THRESHOLD_ALERT         — days before ALERT (default 7)
#   TM_THRESHOLD_URGENT        — days before URGENT (default 14)
#   MOSYLE_DEVICE_NAME         — injected by Mosyle as %DeviceName%
#   MOSYLE_USER_EMAIL          — injected by Mosyle as %Email%
#   MOSYLE_USER_FIRSTNAME      — injected by Mosyle as %FirstName%
#
# Mosyle one-liner:
#   curl -fsSL https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main/time-machine/tm-advisor.sh | bash

# -u: error on unset variables  -o pipefail: catch pipe failures
# Intentionally NO -e: grep returns 1 on no match, which is normal and should not abort
set -uo pipefail

LOGFILE="/var/log/tm-advisor.log"
TM_PLIST="/Library/Preferences/com.apple.TimeMachine.plist"
BASE_URL="https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [tm-advisor] $*" | tee -a "$LOGFILE"; }

# ── Thresholds ────────────────────────────────────────────────────────────────
TM_THRESHOLD_NOTICE=${TM_THRESHOLD_NOTICE:-4}
TM_THRESHOLD_ALERT=${TM_THRESHOLD_ALERT:-7}
TM_THRESHOLD_URGENT=${TM_THRESHOLD_URGENT:-14}

# ── Load common libraries ─────────────────────────────────────────────────────
# Fetch to temp files rather than eval — safer and debuggable
_LIB_DIR=$(mktemp -d)
trap 'rm -rf "$_LIB_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
COMMON_DIR="${SCRIPT_DIR}/../common"

if [[ -f "${COMMON_DIR}/slack.sh" && -f "${COMMON_DIR}/device-info.sh" ]]; then
    # Running from a local checkout
    source "${COMMON_DIR}/slack.sh"
    source "${COMMON_DIR}/device-info.sh"
else
    # Running via curl | bash — fetch libs to temp dir
    log "Fetching common libraries from GitHub"
    curl -fsSL "${BASE_URL}/common/slack.sh"       -o "${_LIB_DIR}/slack.sh"       || { log "ERROR: failed to fetch slack.sh";       exit 1; }
    curl -fsSL "${BASE_URL}/common/device-info.sh" -o "${_LIB_DIR}/device-info.sh" || { log "ERROR: failed to fetch device-info.sh"; exit 1; }
    source "${_LIB_DIR}/slack.sh"
    source "${_LIB_DIR}/device-info.sh"
fi

# ── Collect Time Machine status ───────────────────────────────────────────────
collect_tm_status() {
    TM_CONFIGURED="NO"
    TM_DEST_NAME="none"
    TM_DEST_KIND="none"
    TM_DEST_UUID=""
    TM_DRIVE_CONNECTED="NO"
    TM_DRIVE_MOUNTED="NO"
    TM_LAST_BACKUP="unknown"
    TM_LAST_BACKUP_SRC="none"
    TM_LAST_BACKUP_DAYS=-1
    TM_DRIVE_USED_PCT=""
    TM_RESULT_CODE=""
    TM_REQUIRES_AC="unknown"
    TM_RUNNING="NO"
    TM_DRIVE_LAST_SEEN=""

    [[ ! -f "$TM_PLIST" ]] && return

    # Single plutil call — parse everything from one output
    local plist_dump
    plist_dump=$(plutil -p "$TM_PLIST" 2>/dev/null)
    [[ -z "$plist_dump" ]] && return

    TM_DEST_NAME=$(echo "$plist_dump" | grep '"LastKnownVolumeName"' | awk -F'"' '{print $4}')
    [[ -z "$TM_DEST_NAME" ]] && return
    TM_CONFIGURED="YES"

    TM_DEST_KIND=$(echo "$plist_dump"    | grep '"FilesystemTypeName"'  | awk -F'"' '{print $4}')
    TM_RESULT_CODE=$(echo "$plist_dump"  | grep '"RESULT"'              | awk -F' => ' '{print $2}' | xargs)
    TM_REQUIRES_AC=$(echo "$plist_dump"  | grep '"RequiresACPower"'     | awk -F' => ' '{print $2}' | xargs)
    TM_DEST_UUID=$(echo "$plist_dump" \
        | grep '"DestinationUUIDs"' -A3 \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | head -1)

    # Drive connected?
    # NOTE: diskutil info exits 0 even when disk is missing — must check output text
    if [[ -n "$TM_DEST_UUID" ]]; then
        local disk_info
        disk_info=$(diskutil info "$TM_DEST_UUID" 2>&1)
        if ! echo "$disk_info" | grep -q "Could not find"; then
            TM_DRIVE_CONNECTED="YES"
            local mount_pt
            mount_pt=$(echo "$disk_info" \
                | awk -F':' '/Mount Point/{gsub(/^[ \t]+/,"",$2); print $2}' | xargs)
            [[ -n "$mount_pt" && "$mount_pt" != "(not mounted)" ]] && TM_DRIVE_MOUNTED="YES"
        fi
    fi

    # Drive usage % (stale from last mount, still useful for trending)
    local bytes_used bytes_avail
    bytes_used=$(echo "$plist_dump"  | grep '"BytesUsed"'     | awk -F' => ' '{print $2}' | xargs)
    bytes_avail=$(echo "$plist_dump" | grep '"BytesAvailable"' | awk -F' => ' '{print $2}' | xargs)
    if [[ -n "$bytes_used" && -n "$bytes_avail" ]] && [[ "$bytes_avail" -gt 0 ]] 2>/dev/null; then
        TM_DRIVE_USED_PCT=$(python3 -c \
            "print(round(${bytes_used}/(${bytes_used}+${bytes_avail})*100))" 2>/dev/null) || true
    fi

    # Last successful backup
    # Primary: tmutil latestbackup when drive is mounted (date in folder name = confirmed)
    # Fallback: last SnapshotDates entry in plist (persists after drive disconnect)
    if [[ "$TM_DRIVE_MOUNTED" == "YES" ]]; then
        local latest_date
        latest_date=$(tmutil latestbackup 2>/dev/null \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' | head -1) || true
        if [[ -n "$latest_date" ]]; then
            TM_LAST_BACKUP="$latest_date"
            TM_LAST_BACKUP_SRC="drive"
        fi
    fi

    if [[ "$TM_LAST_BACKUP" == "unknown" ]]; then
        local snap_date
        snap_date=$(echo "$plist_dump" \
            | grep '"SnapshotDates"' -A100 \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4}' \
            | tail -1) || true
        if [[ -n "$snap_date" ]]; then
            TM_LAST_BACKUP="$snap_date"
            TM_LAST_BACKUP_SRC="plist"
        fi
    fi

    # Days since last backup — use python3 for robust cross-format date math
    if [[ "$TM_LAST_BACKUP" != "unknown" ]]; then
        TM_LAST_BACKUP_DAYS=$(python3 - "$TM_LAST_BACKUP" <<'PYEOF' 2>/dev/null || echo -1
import sys, datetime, re

raw = sys.argv[1]
now = datetime.datetime.utcnow()
dt  = None

# Format: 2026-06-04-105838
m = re.match(r'^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})$', raw)
if m:
    dt = datetime.datetime(*map(int, m.groups()))

# Format: 2026-06-04 13:58:18 +0000
if dt is None:
    m = re.match(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})', raw)
    if m:
        dt = datetime.datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S')

if dt:
    print((now - dt).days)
else:
    print(-1)
PYEOF
        ) || TM_LAST_BACKUP_DAYS=-1
    fi

    # Drive last seen in logs (only when not connected, capped at 30d for speed)
    if [[ "$TM_DRIVE_CONNECTED" == "NO" && -n "$TM_DEST_UUID" ]]; then
        TM_DRIVE_LAST_SEEN=$(log show \
            --predicate 'process == "diskarbitrationd"' \
            --last 30d 2>/dev/null \
            | grep "created disk\|mounted disk" \
            | grep -v "disk0\|disk1\|disk2\|disk3\|disk9" \
            | tail -1 | awk '{print $1, $2}') || true
    fi

    # TM currently running?
    tmutil status 2>/dev/null | grep -q '"Running" = 1' && TM_RUNNING="YES" || true
}

# ── Determine severity ────────────────────────────────────────────────────────
determine_severity() {
    SEVERITY="OK"
    SEVERITY_EMOJI="✅"

    [[ "$TM_CONFIGURED"      == "NO" ]] && { SEVERITY="UNCONFIGURED"; SEVERITY_EMOJI="⚫"; return; }
    [[ "$TM_LAST_BACKUP_DAYS" -lt  0 ]] && { SEVERITY="UNKNOWN";      SEVERITY_EMOJI="❓"; return; }

    if   [[ "$TM_LAST_BACKUP_DAYS" -ge "$TM_THRESHOLD_URGENT" ]]; then
        SEVERITY="URGENT"; SEVERITY_EMOJI="🔴"
    elif [[ "$TM_LAST_BACKUP_DAYS" -ge "$TM_THRESHOLD_ALERT"  ]]; then
        SEVERITY="ALERT";  SEVERITY_EMOJI="⚠️"
    elif [[ "$TM_LAST_BACKUP_DAYS" -ge "$TM_THRESHOLD_NOTICE" ]]; then
        SEVERITY="NOTICE"; SEVERITY_EMOJI="📋"
    fi
}

# ── Build user notification copy ─────────────────────────────────────────────
# Sets global USER_MSG — used in IT Slack preview and (Phase 2) user DM
build_user_msg() {
    local user_first="${MOSYLE_USER_FIRSTNAME:-User}"
    local days_str="${TM_LAST_BACKUP_DAYS} days"
    [[ "$TM_LAST_BACKUP_DAYS" -eq 0 ]] && days_str="today"
    [[ "$TM_LAST_BACKUP_DAYS" -eq 1 ]] && days_str="1 day"

    if [[ "$TM_DRIVE_CONNECTED" == "NO" ]]; then
        USER_MSG="Hi ${user_first} — your last Time Machine backup was ${days_str} ago, and your backup drive isn't connected.

Please connect your backup drive *directly* to your Mac (not through a dock) and leave your Mac plugged in to power. Time Machine will run automatically.

If you need help, message us in #it-support."

    elif [[ "$TM_DRIVE_CONNECTED" == "YES" && "$TM_DRIVE_MOUNTED" == "NO" ]]; then
        USER_MSG="Hi ${user_first} — your last Time Machine backup was ${days_str} ago. Your backup drive is connected but isn't responding correctly.

Try unplugging it and plugging it back in directly to your Mac. If the problem continues, message us in #it-support — the drive may need attention."

    elif [[ "${TM_REQUIRES_AC:-}" == "1" && "${DI_AC:-0}" -eq 0 ]]; then
        USER_MSG="Hi ${user_first} — your Mac isn't plugged in to power, and Time Machine is set to only back up when on AC power.

Please plug your Mac in to run a backup."

    else
        USER_MSG="Hi ${user_first} — your last Time Machine backup was ${days_str} ago.

To back up now, click the Time Machine icon in your menu bar and choose *Back Up Now*. Make sure your backup drive is connected and your Mac is plugged in."
    fi
}

# ── Build and send IT Slack message ──────────────────────────────────────────
build_slack_message() {
    local device_name="${MOSYLE_DEVICE_NAME:-${DI_SERIAL:-unknown}}"
    local days_str="${TM_LAST_BACKUP_DAYS} days"
    [[ "$TM_LAST_BACKUP_DAYS" -eq 0 ]] && days_str="today"
    [[ "$TM_LAST_BACKUP_DAYS" -eq 1 ]] && days_str="1 day"

    local usage_note=""
    if [[ -n "$TM_DRIVE_USED_PCT" ]] && [[ "$TM_DRIVE_USED_PCT" -ge 90 ]] 2>/dev/null; then
        usage_note=$'\n'"⚠️ *Drive usage: ${TM_DRIVE_USED_PCT}%* — consider replacing with a larger drive"
    elif [[ -n "$TM_DRIVE_USED_PCT" ]] && [[ "$TM_DRIVE_USED_PCT" -ge 75 ]] 2>/dev/null; then
        usage_note=$'\n'"Drive usage: ${TM_DRIVE_USED_PCT}% (monitor)"
    fi

    local power_note=""
    if [[ "${DI_MAGSAFE:-No}" == "Yes" && "${DI_AC:-0}" -eq 1 ]]; then
        power_note="AC connected — ${DI_ADAPTER:-unknown} (MagSafe in use — USB-C free for direct drive)"
    elif [[ "${DI_AC:-0}" -eq 1 ]]; then
        power_note="AC connected — ${DI_ADAPTER:-unknown}"
    else
        power_note="⚠️ On battery (${DI_BATT_PCT:-?})"
    fi

    local last_seen_line=""
    [[ -n "$TM_DRIVE_LAST_SEEN" ]] && last_seen_line=$'\n'"Drive last seen:  ${TM_DRIVE_LAST_SEEN}"

    SLACK_MESSAGE="${SEVERITY_EMOJI} *TM ${SEVERITY}* | ${device_name} | ${days_str} without backup
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💬 *USER NOTIFICATION* _(pending — will send via DM when enabled)_

${USER_MSG}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔧 *TECHNICAL DETAILS*

Last backup:      ${TM_LAST_BACKUP} (${days_str} ago, src: ${TM_LAST_BACKUP_SRC})
Drive status:     connected=${TM_DRIVE_CONNECTED}  mounted=${TM_DRIVE_MOUNTED}${last_seen_line}
Drive name:       ${TM_DEST_NAME} (${TM_DEST_KIND})
Drive UUID:       ${TM_DEST_UUID:-n/a}${usage_note}
Last result:      ${TM_RESULT_CODE:-n/a}
Requires AC:      ${TM_REQUIRES_AC:-unknown}
TM running now:   ${TM_RUNNING}

Power:            ${power_note}
Battery:          ${DI_BATT_PCT:-?}
USB devices:      ${DI_USB_TOPOLOGY:-none}
Thunderbolt:      ${DI_TB_PORTS:-0} port(s) — devices: ${DI_TB_DEVICES:-none}
MagSafe:          ${DI_MAGSAFE:-No}

Location:         ${DI_PUBLIC_IP:-unknown} → ${DI_LOCATION:-unknown}
                  ${DI_LOCATION_NOTE:-}

Device:           ${device_name} | macOS ${DI_OS:-?} | ${DI_CHIP:-?}
Serial:           ${DI_SERIAL:-unknown}
Console user:     ${DI_CONSOLE_USER:-unknown}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    log "Starting TM advisor check"
    collect_tm_status
    collect_device_info
    determine_severity

    log "Status: SEVERITY=${SEVERITY} DAYS=${TM_LAST_BACKUP_DAYS} CONNECTED=${TM_DRIVE_CONNECTED} MOUNTED=${TM_DRIVE_MOUNTED}"

    if [[ "$SEVERITY" == "OK" ]]; then
        log "TM OK — last backup ${TM_LAST_BACKUP_DAYS} days ago, no action needed"
        exit 0
    fi

    build_user_msg
    build_slack_message

    log "Sending ${SEVERITY} alert to IT Slack channel"
    slack_post_it "$SLACK_MESSAGE"

    # User DM — Phase 2, only fires when SLACK_BOT_TOKEN is set
    if [[ -n "${SLACK_BOT_TOKEN:-}" && -n "${MOSYLE_USER_EMAIL:-}" ]]; then
        log "Sending DM to ${MOSYLE_USER_EMAIL}"
        slack_dm_user "$MOSYLE_USER_EMAIL" "$USER_MSG"
    fi

    log "Done"
}

main "$@"
