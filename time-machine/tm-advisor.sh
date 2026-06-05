#!/usr/bin/env bash
# time-machine/tm-advisor.sh — Time Machine status advisor for Mosyle
# 2026-06-04 v2.3 — jitter sleep to prevent simultaneous Mosyle-triggered DB contention
#                   HA_URL env var for dashboard base URL
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
#   TM_ALERT_REPEAT_DAYS       — re-alert on same severity after N days (default 7)
#   HA_URL                     — HealthAdvisor base URL (Slack links + API posts)
#                                e.g. http://<healthadvisor-host>:3000
#   HA_API_TOKEN               — HealthAdvisor API token (from .env API_TOKEN)
#   MOSYLE_DEVICE_NAME         — injected by Mosyle as %DeviceName%
#   MOSYLE_USER_EMAIL          — injected by Mosyle as %Email%
#   MOSYLE_USER_FIRSTNAME      — injected by Mosyle as %FirstName%
#
# Mosyle one-liner:
#   curl -fsSL https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main/time-machine/tm-advisor.sh | bash

# -u: error on unset variables  -o pipefail: catch pipe failures
# Intentionally NO -e: grep returns 1 on no match, which is normal and should not abort
set -uo pipefail

TM_PLIST="/Library/Preferences/com.apple.TimeMachine.plist"
BASE_URL="https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main"

# Use /var/log when writable (root/Mosyle), fall back to /tmp for manual/non-root runs
if touch /var/log/tm-advisor.log 2>/dev/null; then
    LOGFILE="/var/log/tm-advisor.log"
else
    LOGFILE="/tmp/tm-advisor.log"
fi

# log → logfile only (not stdout — keeps Mosyle table clean)
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [tm-advisor] $*" >> "$LOGFILE"; }

# Sanitize a string for safe use in shell/JSON — strip control chars, keep printable ASCII + spaces
sanitize_str() { printf '%s' "$*" | tr -d '\000-\037\177' | sed "s/['\`\\\\]//g"; }
# mosyle_out → stdout only (one compact line visible in Mosyle response column)
mosyle_out() { echo "$*"; }

# ── Thresholds ────────────────────────────────────────────────────────────────
TM_THRESHOLD_NOTICE=${TM_THRESHOLD_NOTICE:-4}
TM_THRESHOLD_ALERT=${TM_THRESHOLD_ALERT:-7}
TM_THRESHOLD_URGENT=${TM_THRESHOLD_URGENT:-14}
TM_ALERT_REPEAT_DAYS=${TM_ALERT_REPEAT_DAYS:-7}
HA_URL=${HA_URL:-}

# State file — tracks last severity sent + timestamp for deduplication
STATE_FILE="/var/db/osxgroup/tm-advisor-state"
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

# ── Alert deduplication ───────────────────────────────────────────────────────
# Returns 0 (send alert) or 1 (suppress — same severity sent recently)
should_send_alert() {
    local current_severity="$1"
    [[ "$current_severity" == "OK" ]] && return 1  # never send for OK

    if [[ -f "$STATE_FILE" ]]; then
        local last_severity last_sent_epoch now_epoch elapsed_days
        last_severity=$(awk -F= '/severity/{print $2}' "$STATE_FILE" 2>/dev/null)
        last_sent_epoch=$(awk -F= '/sent_epoch/{print $2}' "$STATE_FILE" 2>/dev/null)
        now_epoch=$(date +%s)
        elapsed_days=$(( (now_epoch - ${last_sent_epoch:-0}) / 86400 ))

        # Always send if severity worsened
        if [[ "$last_severity" != "$current_severity" ]]; then
            local severities="OK NOTICE ALERT URGENT UNCONFIGURED UNKNOWN"
            local last_idx current_idx
            last_idx=$(echo "$severities" | tr ' ' '\n' | grep -n "^${last_severity}$" | cut -d: -f1)
            current_idx=$(echo "$severities" | tr ' ' '\n' | grep -n "^${current_severity}$" | cut -d: -f1)
            [[ "${current_idx:-0}" -gt "${last_idx:-0}" ]] && return 0  # worsened — send
        fi

        # Same or better severity — suppress unless repeat window elapsed
        [[ "$elapsed_days" -lt "$TM_ALERT_REPEAT_DAYS" ]] && return 1  # suppress
    fi
    return 0  # no state file yet — send
}

save_alert_state() {
    local severity="$1"
    printf 'severity=%s\nsent_epoch=%s\n' "$severity" "$(date +%s)" > "$STATE_FILE" 2>/dev/null || true
}

# ── Post check result to HealthAdvisor dashboard ─────────────────────────────
# Runs after collect_tm_status + collect_device_info.
# Silently skipped if HA_URL or HA_API_TOKEN are not set.
post_to_healthadvisor() {
    [[ -z "${HA_URL:-}"       ]] && return 0
    [[ -z "${HA_API_TOKEN:-}" ]] && return 0

    local status_num=0
    case "$SEVERITY" in
        NOTICE)       status_num=1 ;;
        ALERT)        status_num=1 ;;
        URGENT)       status_num=2 ;;
        UNCONFIGURED) status_num=1 ;;
        UNKNOWN)      status_num=1 ;;
    esac

    local summary="${SEVERITY_EMOJI} ${SEVERITY}: ${TM_LAST_BACKUP_DAYS}d | drive=${TM_DRIVE_CONNECTED}/${TM_DRIVE_MOUNTED}"
    [[ "$TM_LAST_BACKUP_DAYS" -lt 0 ]] && summary="${SEVERITY_EMOJI} ${SEVERITY}: unknown | drive=${TM_DRIVE_CONNECTED}/${TM_DRIVE_MOUNTED}"

    # Build payload via Python written to a temp file.
    # Cannot use heredoc (<<) here — when run via "curl | bash", stdin is the script
    # itself and heredoc would consume it. Write to a temp file via printf instead.
    local _py; _py=$(mktemp /tmp/ha_payload.XXXXXX.py)
    # shellcheck disable=SC2016
    printf '%s\n' \
        'import json,datetime,os' \
        'e=os.environ.get' \
        'days=int(e("_HA_DAYS","-1") or -1)' \
        'raw={' \
        '  "dest_configured": e("_HA_TM_CONFIGURED")=="YES",' \
        '  "dest_name":       e("_HA_DEST_NAME",""),' \
        '  "dest_uuid":       e("_HA_DEST_UUID",""),' \
        '  "dest_kind":       e("_HA_DEST_KIND",""),' \
        '  "drive_connected": e("_HA_CONNECTED")=="YES",' \
        '  "drive_mounted":   e("_HA_MOUNTED")=="YES",' \
        '  "last_backup":     e("_HA_LAST_BACKUP",""),' \
        '  "last_backup_src": e("_HA_LAST_BACKUP_SRC",""),' \
        '  "last_attempt":    e("_HA_LAST_ATTEMPT",""),' \
        '  "days_since_backup": days if days>=0 else None,' \
        '  "result_code":     e("_HA_RESULT",""),' \
        '  "requires_ac":     e("_HA_REQUIRES_AC",""),' \
        '  "drive_used_pct":  int(e("_HA_DRIVE_PCT","0") or 0) or None,' \
        '  "on_ac":           e("_HA_ON_AC","0")=="1",' \
        '  "adapter":         e("_HA_ADAPTER",""),' \
        '  "battery_pct":     e("_HA_BATT",""),' \
        '  "magsafe":         e("_HA_MAGSAFE","No")=="Yes",' \
        '  "usb_topology":    e("_HA_USB",""),' \
        '  "tb_ports":        int(e("_HA_TB_PORTS","0") or 0),' \
        '  "tb_devices":      e("_HA_TB_DEV","none"),' \
        '  "location_ip":     e("_HA_IP",""),' \
        '  "location_city":   e("_HA_LOCATION",""),' \
        '  "location_note":   e("_HA_LOC_NOTE",""),' \
        '}' \
        'p={"machine_id":e("_HA_SERIAL","UNKNOWN"),"hostname":e("_HA_HOSTNAME","unknown"),' \
        '   "agent_version":"tm-advisor-2.1",' \
        '   "collected_at":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),' \
        '   "checks":[{"check_name":"time_machine","status":int(e("_HA_STATUS","0")),' \
        '              "summary":e("_HA_SUMMARY",""),"raw_data":raw}]}' \
        'print(json.dumps(p))' \
        > "$_py"

    local payload
    payload=$(
        export _HA_SERIAL="${DI_SERIAL:-UNKNOWN}"
        export _HA_HOSTNAME="${MOSYLE_DEVICE_NAME:-${DI_SERIAL:-unknown}}"
        export _HA_STATUS="$status_num"
        export _HA_SUMMARY="$summary"
        export _HA_TM_CONFIGURED="${TM_CONFIGURED:-NO}"
        export _HA_DEST_NAME="${TM_DEST_NAME:-}"
        export _HA_DEST_UUID="${TM_DEST_UUID:-}"
        export _HA_DEST_KIND="${TM_DEST_KIND:-}"
        export _HA_CONNECTED="${TM_DRIVE_CONNECTED:-NO}"
        export _HA_MOUNTED="${TM_DRIVE_MOUNTED:-NO}"
        export _HA_LAST_BACKUP="${TM_LAST_BACKUP:-}"
        export _HA_LAST_BACKUP_SRC="${TM_LAST_BACKUP_SRC:-}"
        export _HA_LAST_ATTEMPT="${TM_LAST_ATTEMPT:-}"
        export _HA_DAYS="${TM_LAST_BACKUP_DAYS:--1}"
        export _HA_RESULT="${TM_RESULT_CODE:-}"
        export _HA_REQUIRES_AC="${TM_REQUIRES_AC:-}"
        export _HA_DRIVE_PCT="${TM_DRIVE_USED_PCT:-}"
        export _HA_ON_AC="${DI_AC:-0}"
        export _HA_ADAPTER="${DI_ADAPTER:-}"
        export _HA_BATT="${DI_BATT_PCT:-}"
        export _HA_MAGSAFE="${DI_MAGSAFE:-No}"
        export _HA_USB="${DI_USB_TOPOLOGY:-}"
        export _HA_TB_PORTS="${DI_TB_PORTS:-0}"
        export _HA_TB_DEV="${DI_TB_DEVICES:-none}"
        export _HA_IP="${DI_PUBLIC_IP:-}"
        export _HA_LOCATION="${DI_LOCATION:-}"
        export _HA_LOC_NOTE="${DI_LOCATION_NOTE:-}"
        python3 "$_py" 2>/dev/null
    )
    rm -f "$_py"

    [[ -z "$payload" ]] && { log "HA post: failed to build payload"; return 0; }

    local http_code
    http_code=$(curl -sSL -o /dev/null -w "%{http_code}" \
        -X POST "${HA_URL}/api/v1/checkin" \
        -H "Content-Type: application/json" \
        -H "X-API-Token: ${HA_API_TOKEN}" \
        -d "$payload" 2>/dev/null)

    if [[ "$http_code" == "200" ]]; then
        log "HA checkin posted (HTTP 200)"
    else
        log "HA checkin failed (HTTP ${http_code:-000})"
    fi
}

# ── Load common libraries ─────────────────────────────────────────────────────
# Fetch to temp files rather than eval — safer and debuggable
_LIB_DIR=$(mktemp -d)
trap 'rm -rf "$_LIB_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
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
    TM_LAST_ATTEMPT=""

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
        # sort — plist array order is not guaranteed newest-last
        snap_date=$(echo "$plist_dump" \
            | grep '"SnapshotDates"' -A500 \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4}' \
            | sort | tail -1) || true
        if [[ -n "$snap_date" ]]; then
            TM_LAST_BACKUP="$snap_date"
            TM_LAST_BACKUP_SRC="plist"
        fi
    fi

    # Last attempt date — from AttemptDates in plist (not confirmed success, but useful for IT)
    TM_LAST_ATTEMPT=$(echo "$plist_dump" \
        | grep '"AttemptDates"' -A20 \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4}' \
        | tail -1) || true

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

    [[ "$TM_CONFIGURED" == "NO" ]] && { SEVERITY="UNCONFIGURED"; SEVERITY_EMOJI="⚫"; return; }

    # No confirmed backup date in plist
    if [[ "$TM_LAST_BACKUP_DAYS" -lt 0 ]]; then
        # Drive connected but won't mount — likely corrupt/failing drive, treat as urgent
        if [[ "$TM_DRIVE_CONNECTED" == "YES" && "$TM_DRIVE_MOUNTED" == "NO" ]]; then
            SEVERITY="URGENT"; SEVERITY_EMOJI="🔴"
        elif [[ "$TM_DRIVE_CONNECTED" == "NO" ]]; then
            SEVERITY="URGENT"; SEVERITY_EMOJI="🔴"
        else
            SEVERITY="UNKNOWN"; SEVERITY_EMOJI="❓"
        fi
        return
    fi

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
    [[ "$TM_LAST_BACKUP_DAYS" -lt  0 ]] && days_str="an unknown amount of time"
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
    [[ "$TM_LAST_BACKUP_DAYS" -lt  0 ]] && days_str="unknown"
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
Last attempt:     ${TM_LAST_ATTEMPT:-n/a}
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

    # Append dashboard link if HA_URL is configured
    if [[ -n "${HA_URL:-}" && -n "${DI_SERIAL:-}" ]]; then
        SLACK_MESSAGE="${SLACK_MESSAGE}

🖥 <${HA_URL}/device/${DI_SERIAL}|View in HealthAdvisor dashboard>"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    # Jitter: random 0-60s sleep to spread simultaneous Mosyle-triggered runs
    # Prevents SQLite write contention when all 60 devices fire at once on script save
    sleep $(( RANDOM % 60 ))
    log "Starting TM advisor check"
    collect_tm_status
    collect_device_info
    determine_severity

    # Sanitize device name — Mosyle substitutes %DeviceName% directly into shell;
    # names with $, backticks, or backslashes would be interpreted by bash
    MOSYLE_DEVICE_NAME=$(sanitize_str "${MOSYLE_DEVICE_NAME:-}")

    log "Status: SEVERITY=${SEVERITY} DAYS=${TM_LAST_BACKUP_DAYS} CONNECTED=${TM_DRIVE_CONNECTED} MOUNTED=${TM_DRIVE_MOUNTED} HA_URL=${HA_URL:+set}"

    # Always post to HealthAdvisor dashboard regardless of severity
    post_to_healthadvisor

    if [[ "$SEVERITY" == "OK" ]]; then
        log "TM OK — last backup ${TM_LAST_BACKUP_DAYS} days ago, no action needed"
        [[ -f "$STATE_FILE" ]] && printf 'severity=OK\nsent_epoch=%s\n' "$(date +%s)" > "$STATE_FILE" || true
        mosyle_out "[OK] ${MOSYLE_DEVICE_NAME:-${DI_SERIAL:-unknown}} | ${TM_LAST_BACKUP_DAYS}d ago | drive=${TM_DRIVE_CONNECTED}/${TM_DRIVE_MOUNTED} | ${DI_LOCATION_NOTE:-?}"
        exit 0
    fi

    build_user_msg
    build_slack_message

    if should_send_alert "$SEVERITY"; then
        log "Sending ${SEVERITY} alert to IT Slack channel"
        slack_post_it "$SLACK_MESSAGE"
        save_alert_state "$SEVERITY"
    else
        log "Suppressing Slack — ${SEVERITY} already sent recently (repeat window: ${TM_ALERT_REPEAT_DAYS}d)"
    fi

    # User DM — Phase 2, only fires when SLACK_BOT_TOKEN is set
    if [[ -n "${SLACK_BOT_TOKEN:-}" && -n "${MOSYLE_USER_EMAIL:-}" ]]; then
        log "Sending DM to ${MOSYLE_USER_EMAIL}"
        slack_dm_user "$MOSYLE_USER_EMAIL" "$USER_MSG"
    fi

    log "Done"

    # Compact single-line summary for Mosyle response column
    local days_disp="${TM_LAST_BACKUP_DAYS}d"
    [[ "$TM_LAST_BACKUP_DAYS" -lt 0 ]] && days_disp="unknown"
    mosyle_out "[${SEVERITY}] ${MOSYLE_DEVICE_NAME:-${DI_SERIAL:-unknown}} | ${days_disp} | drive=${TM_DRIVE_CONNECTED}/${TM_DRIVE_MOUNTED} | ${DI_LOCATION_NOTE:-?}"
}

main "$@"
