#!/usr/bin/env bash
# time-machine/tm-advisor.sh — Time Machine status advisor for Mosyle
# 2026-06-04 v1.0
#
# Collects Time Machine status and sends Slack alerts based on days since
# last successful backup to external destination.
#
# Severity thresholds:
#   NOTICE  >= TM_THRESHOLD_NOTICE  days (default 4)  → IT channel + user DM preview
#   ALERT   >= TM_THRESHOLD_ALERT   days (default 7)  → IT channel + user DM preview
#   URGENT  >= TM_THRESHOLD_URGENT  days (default 14) → IT channel + user DM preview
#
# Required env vars (set in Mosyle):
#   SLACK_ITDEPT_ALERTS        — IT channel incoming webhook URL
#
# Optional env vars:
#   SLACK_BOT_TOKEN            — xoxb- token for user DMs (Phase 2, leave blank to skip)
#   TM_THRESHOLD_NOTICE        — days before NOTICE (default 4)
#   TM_THRESHOLD_ALERT         — days before ALERT (default 7)
#   TM_THRESHOLD_URGENT        — days before URGENT (default 14)
#   MOSYLE_DEVICE_NAME         — injected by Mosyle as %DeviceName%
#   MOSYLE_USER_EMAIL          — injected by Mosyle as %Email%
#   MOSYLE_USER_FIRSTNAME      — injected by Mosyle as %FirstName%
#
# Mosyle one-liner:
#   curl -fsSL https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main/time-machine/tm-advisor.sh | bash

set -euo pipefail

# ── Thresholds ────────────────────────────────────────────────────────────────
TM_THRESHOLD_NOTICE=${TM_THRESHOLD_NOTICE:-4}
TM_THRESHOLD_ALERT=${TM_THRESHOLD_ALERT:-7}
TM_THRESHOLD_URGENT=${TM_THRESHOLD_URGENT:-14}

# ── Source common libraries ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/../common"

# When fetched via curl | bash, SCRIPT_DIR is not useful — fetch common libs
if [[ ! -f "${COMMON_DIR}/slack.sh" ]]; then
    BASE_URL="https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main"
    eval "$(curl -fsSL "${BASE_URL}/common/slack.sh")"
    eval "$(curl -fsSL "${BASE_URL}/common/device-info.sh")"
else
    # shellcheck source=../common/slack.sh
    source "${COMMON_DIR}/slack.sh"
    # shellcheck source=../common/device-info.sh
    source "${COMMON_DIR}/device-info.sh"
fi

# ── Collect Time Machine status ───────────────────────────────────────────────
TM_PLIST="/Library/Preferences/com.apple.TimeMachine.plist"

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

    # Destination configured?
    TM_DEST_NAME=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"LastKnownVolumeName"' | awk -F'"' '{print $4}')
    [[ -z "$TM_DEST_NAME" ]] && return
    TM_CONFIGURED="YES"

    TM_DEST_KIND=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"FilesystemTypeName"' | awk -F'"' '{print $4}')

    TM_RESULT_CODE=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"RESULT"' | awk -F' => ' '{print $2}' | xargs)

    TM_REQUIRES_AC=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"RequiresACPower"' | awk -F' => ' '{print $2}' | xargs)

    # Volume UUID
    TM_DEST_UUID=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"DestinationUUIDs"' -A3 \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | head -1)

    # Drive connected?
    # NOTE: diskutil info exits 0 even when disk is missing — check output text
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

    # Drive usage %
    local bytes_used bytes_avail
    bytes_used=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"BytesUsed"' | awk -F' => ' '{print $2}' | xargs)
    bytes_avail=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"BytesAvailable"' | awk -F' => ' '{print $2}' | xargs)
    if [[ -n "$bytes_used" && -n "$bytes_avail" && "$bytes_avail" -gt 0 ]]; then
        local total=$(( bytes_used + bytes_avail ))
        TM_DRIVE_USED_PCT=$(python3 -c "print(round(${bytes_used}/${total}*100))" 2>/dev/null)
    fi

    # Last successful backup date
    # Primary: tmutil latestbackup when drive is mounted (date embedded in path)
    # Fallback: last SnapshotDates entry from plist (persists after disconnect)
    if [[ "$TM_DRIVE_MOUNTED" == "YES" ]]; then
        local latest_path
        latest_path=$(tmutil latestbackup 2>/dev/null)
        local latest_date
        latest_date=$(echo "$latest_path" \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' | head -1)
        if [[ -n "$latest_date" ]]; then
            TM_LAST_BACKUP="$latest_date"
            TM_LAST_BACKUP_SRC="drive"
        fi
    fi

    if [[ "$TM_LAST_BACKUP" == "unknown" ]]; then
        local snap_date
        snap_date=$(plutil -p "$TM_PLIST" 2>/dev/null \
            | grep '"SnapshotDates"' -A100 \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4}' \
            | tail -1)
        if [[ -n "$snap_date" ]]; then
            TM_LAST_BACKUP="$snap_date"
            TM_LAST_BACKUP_SRC="plist"
        fi
    fi

    # Days since last backup
    if [[ "$TM_LAST_BACKUP" != "unknown" ]]; then
        local backup_epoch now_epoch
        # Normalize both date formats to epoch
        if echo "$TM_LAST_BACKUP" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$'; then
            # Format: 2026-06-04-105838
            local d t
            d=$(echo "$TM_LAST_BACKUP" | cut -d- -f1-3)
            t=$(echo "$TM_LAST_BACKUP" | cut -d- -f4 | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/')
            backup_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "${d} ${t}" "+%s" 2>/dev/null)
        else
            # Format: 2026-06-04 13:58:18 +0000
            backup_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$TM_LAST_BACKUP" "+%s" 2>/dev/null)
        fi
        now_epoch=$(date "+%s")
        if [[ -n "$backup_epoch" && -n "$now_epoch" ]]; then
            TM_LAST_BACKUP_DAYS=$(( (now_epoch - backup_epoch) / 86400 ))
        fi
    fi

    # Drive last seen (last time diskarbitrationd showed it) — useful when not connected
    if [[ "$TM_DRIVE_CONNECTED" == "NO" && -n "$TM_DEST_UUID" ]]; then
        TM_DRIVE_LAST_SEEN=$(log show --predicate 'process == "diskarbitrationd"' --last 90d 2>/dev/null \
            | grep -i "created disk\|mounted disk" \
            | grep -v "disk0\|disk1\|disk2\|disk3\|disk9" \
            | tail -1 | awk '{print $1, $2}')
    fi

    # TM currently running?
    tmutil status 2>/dev/null | grep -q '"Running" = 1' && TM_RUNNING="YES"
}

# ── Determine severity ────────────────────────────────────────────────────────
determine_severity() {
    SEVERITY="OK"
    SEVERITY_EMOJI="✅"

    [[ "$TM_CONFIGURED" == "NO" ]] && { SEVERITY="UNCONFIGURED"; SEVERITY_EMOJI="⚫"; return; }
    [[ "$TM_LAST_BACKUP_DAYS" -lt 0 ]] && { SEVERITY="UNKNOWN"; SEVERITY_EMOJI="❓"; return; }

    if [[ "$TM_LAST_BACKUP_DAYS" -ge "$TM_THRESHOLD_URGENT" ]]; then
        SEVERITY="URGENT"; SEVERITY_EMOJI="🔴"
    elif [[ "$TM_LAST_BACKUP_DAYS" -ge "$TM_THRESHOLD_ALERT" ]]; then
        SEVERITY="ALERT"; SEVERITY_EMOJI="⚠️"
    elif [[ "$TM_LAST_BACKUP_DAYS" -ge "$TM_THRESHOLD_NOTICE" ]]; then
        SEVERITY="NOTICE"; SEVERITY_EMOJI="📋"
    fi
}

# ── Build Slack message ───────────────────────────────────────────────────────
build_slack_message() {
    local device_name="${MOSYLE_DEVICE_NAME:-${DI_SERIAL}}"
    local user_first="${MOSYLE_USER_FIRSTNAME:-User}"
    local days_str="${TM_LAST_BACKUP_DAYS} days"
    [[ "$TM_LAST_BACKUP_DAYS" -eq 1 ]] && days_str="1 day"

    # ── User notification copy (shown in IT message as preview) ──
    local user_msg=""
    if [[ "$TM_DRIVE_CONNECTED" == "NO" ]]; then
        user_msg="Hi ${user_first} — your last Time Machine backup was ${days_str} ago, and your backup drive isn't connected.\n\nPlease connect your backup drive *directly* to your Mac (not through a dock) and leave your Mac plugged in to power. Time Machine will run automatically.\n\nIf you need help, message us in #it-support."
    elif [[ "$TM_DRIVE_CONNECTED" == "YES" && "$TM_DRIVE_MOUNTED" == "NO" ]]; then
        user_msg="Hi ${user_first} — your last Time Machine backup was ${days_str} ago. Your backup drive is connected but isn't responding correctly.\n\nTry unplugging it and plugging it back in directly to your Mac. If the problem continues, message us in #it-support — the drive may need attention."
    elif [[ "$TM_REQUIRES_AC" == "1" && "$DI_AC" -eq 0 ]]; then
        user_msg="Hi ${user_first} — your Mac isn't plugged in to power, and Time Machine is set to only back up on AC power.\n\nPlease plug in your Mac to run a backup."
    else
        user_msg="Hi ${user_first} — your last Time Machine backup was ${days_str} ago.\n\nTo back up now, click the Time Machine icon in your menu bar and choose *Back Up Now*. Make sure your backup drive is connected and your Mac is plugged in."
    fi

    # ── Drive usage warning ──
    local usage_note=""
    if [[ -n "$TM_DRIVE_USED_PCT" && "$TM_DRIVE_USED_PCT" -ge 90 ]]; then
        usage_note="\n⚠️ *Drive usage: ${TM_DRIVE_USED_PCT}%* — consider replacing with a larger drive"
    elif [[ -n "$TM_DRIVE_USED_PCT" && "$TM_DRIVE_USED_PCT" -ge 75 ]]; then
        usage_note="\nDrive usage: ${TM_DRIVE_USED_PCT}% (monitor)"
    fi

    # ── MagSafe / power note ──
    local power_note=""
    if [[ "$DI_MAGSAFE" == "Yes" && "$DI_AC" -eq 1 ]]; then
        power_note="AC connected (MagSafe capable — USB-C port free for direct drive)"
    elif [[ "$DI_AC" -eq 1 ]]; then
        power_note="AC connected — ${DI_ADAPTER}"
    else
        power_note="⚠️ On battery (${DI_BATT_PCT})"
    fi

    # ── Assemble full IT message ──
    SLACK_MESSAGE="${SEVERITY_EMOJI} *TM ${SEVERITY}* | ${device_name} | ${days_str} without backup
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💬 *USER NOTIFICATION* _(pending — will send via DM when enabled)_

${user_msg}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔧 *TECHNICAL DETAILS*

Last backup:      ${TM_LAST_BACKUP} (${days_str} ago, src: ${TM_LAST_BACKUP_SRC})
Drive status:     connected=${TM_DRIVE_CONNECTED}  mounted=${TM_DRIVE_MOUNTED}
Drive name:       ${TM_DEST_NAME} (${TM_DEST_KIND})
Drive UUID:       ${TM_DEST_UUID:-n/a}${usage_note}
Last result:      ${TM_RESULT_CODE:-n/a}
Requires AC:      ${TM_REQUIRES_AC}
TM running now:   ${TM_RUNNING}
$([ -n "$TM_DRIVE_LAST_SEEN" ] && echo "Drive last seen:  ${TM_DRIVE_LAST_SEEN}")

Power:            ${power_note}
Battery:          ${DI_BATT_PCT}
USB devices:      ${DI_USB_TOPOLOGY}
Thunderbolt:      ${DI_TB_PORTS} port(s) — devices: ${DI_TB_DEVICES}
MagSafe:          ${DI_MAGSAFE}

Location:         ${DI_PUBLIC_IP} → ${DI_LOCATION}
                  ${DI_LOCATION_NOTE}

Device:           ${device_name} | macOS ${DI_OS} | ${DI_CHIP}
Serial:           ${DI_SERIAL}
Console user:     ${DI_CONSOLE_USER}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    collect_tm_status
    collect_device_info
    determine_severity

    # Always exit quietly if backup is healthy
    if [[ "$SEVERITY" == "OK" ]]; then
        echo "TM OK — last backup ${TM_LAST_BACKUP_DAYS} days ago"
        exit 0
    fi

    build_slack_message

    echo "TM ${SEVERITY} — ${TM_LAST_BACKUP_DAYS} days — sending to Slack IT channel"
    slack_post_it "$SLACK_MESSAGE"

    # User DM — Phase 2, only fires when SLACK_BOT_TOKEN is set
    if [[ -n "${SLACK_BOT_TOKEN:-}" && -n "${MOSYLE_USER_EMAIL:-}" ]]; then
        # Build plain user message (no IT-specific detail)
        local user_plain
        user_plain=$(printf '%s' "$user_msg" | sed 's/\\n/\n/g')
        slack_dm_user "$MOSYLE_USER_EMAIL" "$user_plain"
    fi
}

main "$@"
