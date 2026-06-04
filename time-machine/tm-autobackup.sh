#!/usr/bin/env bash
# time-machine/tm-autobackup.sh — Auto-backup and clean eject on drive connect
# 2026-06-04 v1.1 — fix: caffeinate -dis (was -i, missed system sleep);
#                        eject by disk identifier not UUID; improve lib loading
#
# Deployed as a LaunchDaemon via Mosyle. Triggered by StartOnMount.
# Reads TM destination dynamically from plist — works regardless of drive
# name changes or drive replacements.
#
# Behavior:
#   1. Confirm the mounted volume is the registered TM destination
#   2. Run: caffeinate -dis tmutil startbackup --block
#   3. Poll tmutil currentphase until BackupNotRunning
#   4. Eject the physical disk (not just the volume) cleanly
#   5. Log result + notify IT via Slack
#
# Required env vars (set in LaunchDaemon plist via Mosyle deploy):
#   SLACK_ITDEPT_ALERTS    — IT channel webhook
#
# Optional:
#   MOSYLE_DEVICE_NAME     — device display name
#   SLACK_BOT_TOKEN        — for user DM (Phase 2)
#   MOSYLE_USER_EMAIL      — for user DM (Phase 2)

# No set -e — intentional, see tm-advisor.sh header
set -uo pipefail

TM_PLIST="/Library/Preferences/com.apple.TimeMachine.plist"
LOGFILE="/var/log/tm-autobackup.log"
BASE_URL="https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main"
MAX_WAIT_SECONDS=7200   # 2 hours max before giving up

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [tm-autobackup] $*" | tee -a "$LOGFILE"; }

# ── Load common libraries ─────────────────────────────────────────────────────
_LIB_DIR=$(mktemp -d)
trap 'rm -rf "$_LIB_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
COMMON_DIR="${SCRIPT_DIR}/../common"

if [[ -f "${COMMON_DIR}/slack.sh" ]]; then
    source "${COMMON_DIR}/slack.sh"
else
    curl -fsSL "${BASE_URL}/common/slack.sh" -o "${_LIB_DIR}/slack.sh" \
        || { log "ERROR: failed to fetch slack.sh"; exit 1; }
    source "${_LIB_DIR}/slack.sh"
fi

# ── Get TM destination info from plist ───────────────────────────────────────
get_tm_dest_uuid() {
    plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"DestinationUUIDs"' -A3 \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | head -1
}

# ── Get parent disk identifier (e.g. disk4) for a volume UUID ────────────────
# Ejecting by UUID only ejects the APFS volume, not the physical disk.
# We need the whole-disk identifier to power off the USB device.
get_parent_disk() {
    local uuid="$1"
    local disk_id
    disk_id=$(diskutil info "$uuid" 2>/dev/null \
        | awk -F': ' '/Part of Whole:/{print $2}' | xargs)
    # Fall back to the volume's own identifier if parent not found
    if [[ -z "$disk_id" ]]; then
        disk_id=$(diskutil info "$uuid" 2>/dev/null \
            | awk -F': ' '/Device Identifier:/{print $2}' | xargs)
    fi
    echo "$disk_id"
}

# ── Poll until all TM phases finish ──────────────────────────────────────────
wait_for_tm_complete() {
    local waited=0
    local phase

    sleep 10   # Give TM a moment to start after drive mounts

    while [[ $waited -lt $MAX_WAIT_SECONDS ]]; do
        phase=$(tmutil currentphase 2>/dev/null | tr -d '\n') || phase="unknown"
        [[ "$phase" == "BackupNotRunning" ]] && return 0
        log "TM phase: ${phase} (${waited}s elapsed)"
        sleep 15
        (( waited += 15 ))
    done

    log "WARNING: Timed out waiting for TM after ${MAX_WAIT_SECONDS}s"
    return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    local device_name="${MOSYLE_DEVICE_NAME:-$(scutil --get ComputerName 2>/dev/null || echo unknown)}"
    log "Volume mount event — checking if TM destination"

    [[ ! -f "$TM_PLIST" ]] && { log "TM not configured — exiting"; exit 0; }

    local dest_uuid
    dest_uuid=$(get_tm_dest_uuid)
    [[ -z "$dest_uuid" ]] && { log "No TM destination UUID in plist — exiting"; exit 0; }

    # Confirm TM destination is mounted
    local disk_info
    disk_info=$(diskutil info "$dest_uuid" 2>&1)
    if echo "$disk_info" | grep -q "Could not find"; then
        log "TM destination not mounted — this is a different volume, exiting"
        exit 0
    fi

    local dest_name
    dest_name=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"LastKnownVolumeName"' | awk -F'"' '{print $4}')
    log "TM destination confirmed: ${dest_name} (${dest_uuid})"

    # Get parent disk identifier for clean eject later
    local parent_disk
    parent_disk=$(get_parent_disk "$dest_uuid")
    log "Parent disk: ${parent_disk:-unknown}"

    # ── Run backup ────────────────────────────────────────────────────────────
    log "Starting backup — caffeinate -dis tmutil startbackup --block"
    local backup_start
    backup_start=$(date '+%s')

    # -d: prevent display sleep  -i: prevent idle sleep  -s: prevent system sleep
    caffeinate -dis tmutil startbackup --block 2>>"$LOGFILE"
    local backup_exit=$?

    # --block returns when copy is done but TM may still be in Finishing/Thinning phases
    wait_for_tm_complete || true

    local backup_end duration_min
    backup_end=$(date '+%s')
    duration_min=$(( (backup_end - backup_start) / 60 ))

    # ── Capture result ────────────────────────────────────────────────────────
    local result_code last_backup
    result_code=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"RESULT"' | awk -F' => ' '{print $2}' | xargs) || result_code="unknown"
    last_backup=$(tmutil latestbackup 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' | head -1) || last_backup="unknown"

    local status_emoji="✅" status_word="completed"
    if [[ "$backup_exit" -ne 0 || "${result_code}" != "0" ]]; then
        status_emoji="⚠️"; status_word="completed with errors"
    fi
    log "Backup ${status_word} in ${duration_min}m — result=${result_code} — last=${last_backup}"

    # ── Eject physical disk ───────────────────────────────────────────────────
    local eject_status="clean ✅"
    if [[ -n "$parent_disk" ]]; then
        log "Ejecting /dev/${parent_disk}"
        local eject_out
        eject_out=$(diskutil eject "$parent_disk" 2>&1)
        if [[ $? -ne 0 ]]; then
            eject_status="failed ⚠️ (${eject_out})"
            log "Eject failed: ${eject_out} — trying force unmount"
            diskutil unmount force "$dest_uuid" 2>>"$LOGFILE" || true
        fi
    else
        eject_status="skipped (parent disk unknown)"
        log "Could not determine parent disk — skipping eject"
    fi
    log "Eject: ${eject_status}"

    # ── Notify IT ─────────────────────────────────────────────────────────────
    local slack_msg
    slack_msg="${status_emoji} *TM autobackup ${status_word}* | ${device_name}

Drive:       ${dest_name}
Duration:    ${duration_min} min
Last backup: ${last_backup}
Result code: ${result_code}
Eject:       ${eject_status}"

    slack_post_it "$slack_msg"
    log "Slack notification sent"
}

main "$@"
