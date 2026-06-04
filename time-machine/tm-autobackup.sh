#!/usr/bin/env bash
# time-machine/tm-autobackup.sh — Auto-backup and clean eject on drive connect
# 2026-06-04 v1.0
#
# Deployed as a LaunchDaemon via Mosyle. Triggered by StartOnMount watching
# the TM destination volume. Reads destination dynamically from TM plist so
# it works regardless of drive name or replacement drives.
#
# Behavior:
#   1. Confirm mounted volume is the registered TM destination
#   2. Wait briefly for TM to settle after mount
#   3. Run: caffeinate -i tmutil startbackup --block
#   4. Wait for all TM phases to complete (poll currentphase)
#   5. Eject destination cleanly via diskutil
#   6. Log result + send Slack summary to IT channel
#
# Required env vars (set in Mosyle or LaunchDaemon):
#   SLACK_ITDEPT_ALERTS    — IT channel webhook
#
# Optional:
#   MOSYLE_DEVICE_NAME     — device display name
#   SLACK_BOT_TOKEN        — for user DM (Phase 2)
#   MOSYLE_USER_EMAIL      — for user DM (Phase 2)

set -uo pipefail

TM_PLIST="/Library/Preferences/com.apple.TimeMachine.plist"
LOGFILE="/var/log/tm-autobackup.log"
MAX_WAIT_SECONDS=7200   # 2 hours max before we give up waiting

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [tm-autobackup] $*" | tee -a "$LOGFILE"
}

# ── Source common libraries ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/../common"

if [[ ! -f "${COMMON_DIR}/slack.sh" ]]; then
    BASE_URL="https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main"
    eval "$(curl -fsSL "${BASE_URL}/common/slack.sh")"
else
    source "${COMMON_DIR}/slack.sh"
fi

# ── Get TM destination volume UUID from plist ─────────────────────────────────
get_tm_dest_uuid() {
    plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"DestinationUUIDs"' -A3 \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | head -1
}

# ── Wait for all TM phases to finish ─────────────────────────────────────────
wait_for_tm_complete() {
    local waited=0
    local phase

    # Give TM a moment to start after drive mounts
    sleep 10

    while [[ $waited -lt $MAX_WAIT_SECONDS ]]; do
        phase=$(tmutil currentphase 2>/dev/null | tr -d '\n')
        [[ "$phase" == "BackupNotRunning" ]] && return 0
        log "TM phase: ${phase} (${waited}s elapsed)"
        sleep 15
        waited=$(( waited + 15 ))
    done

    log "WARNING: Timed out waiting for TM to complete after ${MAX_WAIT_SECONDS}s"
    return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    local device_name="${MOSYLE_DEVICE_NAME:-$(scutil --get ComputerName 2>/dev/null)}"

    log "Drive mount event detected — checking TM destination"

    [[ ! -f "$TM_PLIST" ]] && { log "No TM plist — TM not configured, exiting"; exit 0; }

    local dest_uuid
    dest_uuid=$(get_tm_dest_uuid)
    [[ -z "$dest_uuid" ]] && { log "No TM destination UUID found, exiting"; exit 0; }

    # Confirm TM destination is actually mounted
    local disk_info
    disk_info=$(diskutil info "$dest_uuid" 2>&1)
    if echo "$disk_info" | grep -q "Could not find"; then
        log "TM destination not mounted — not our drive, exiting"
        exit 0
    fi

    local dest_name
    dest_name=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"LastKnownVolumeName"' | awk -F'"' '{print $4}')
    log "TM destination mounted: ${dest_name} (${dest_uuid})"

    # ── Run backup ────────────────────────────────────────────────────────────
    log "Starting backup (caffeinate + tmutil startbackup --block)"
    local backup_start
    backup_start=$(date '+%s')

    caffeinate -i tmutil startbackup --block 2>>"$LOGFILE"
    local backup_exit=$?

    # Poll until fully done (--block returns after copy but TM may still be finishing)
    wait_for_tm_complete
    local wait_exit=$?

    local backup_end
    backup_end=$(date '+%s')
    local duration=$(( backup_end - backup_start ))
    local duration_min=$(( duration / 60 ))

    # ── Get result ────────────────────────────────────────────────────────────
    local result_code
    result_code=$(plutil -p "$TM_PLIST" 2>/dev/null \
        | grep '"RESULT"' | awk -F' => ' '{print $2}' | xargs)

    local last_backup
    last_backup=$(tmutil latestbackup 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' | head -1)

    local status_emoji="✅"
    local status_word="completed"
    if [[ "$backup_exit" -ne 0 || "$result_code" != "0" ]]; then
        status_emoji="⚠️"
        status_word="may have errors"
    fi

    log "Backup ${status_word} in ${duration_min}m — result=${result_code} — last=${last_backup}"

    # ── Eject destination ─────────────────────────────────────────────────────
    log "Ejecting TM destination: ${dest_name}"
    local eject_out
    eject_out=$(diskutil eject "$dest_uuid" 2>&1)
    local eject_exit=$?

    if [[ $eject_exit -eq 0 ]]; then
        log "Drive ejected cleanly"
    else
        log "Eject failed: ${eject_out}"
        # Try unmount as fallback
        diskutil unmount force "$dest_uuid" 2>>"$LOGFILE" || true
    fi

    # ── Notify IT via Slack ───────────────────────────────────────────────────
    local slack_msg
    slack_msg="${status_emoji} *TM autobackup ${status_word}* | ${device_name}

Drive:       ${dest_name}
Duration:    ${duration_min} min
Last backup: ${last_backup:-unknown}
Result code: ${result_code:-unknown}
Eject:       $([ $eject_exit -eq 0 ] && echo 'clean ✅' || echo "failed ⚠️  (${eject_out})")"

    slack_post_it "$slack_msg"
}

main "$@"
