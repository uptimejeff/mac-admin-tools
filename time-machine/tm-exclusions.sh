#!/usr/bin/env bash
# time-machine/tm-exclusions.sh — TM settings enforcement + smart exclusions
# 2026-06-09 v1.0
#
# Usage (as root):
#   bash tm-exclusions.sh           # live run
#   DRY_RUN=1 bash tm-exclusions.sh # audit only, no changes
#
# What this does:
#   1. Disables RequiresACPower (allow backup on battery)
#   2. Detects the real human user (skips gadmin/root)
#   3. Adds per-user TM exclusions via 'tmutil addexclusion -p' (sticky xattr)
#      - CloudStorage (Google Drive, iCloud Drive, OneDrive, etc.)
#      - Mobile Documents (iCloud Drive legacy path)
#      - Mail message cache — account folders only; MailData/ is KEPT
#        (preserves signatures, rules, smart mailboxes for migration)
#      - MobileSync/Backup (iPhone/iPad backups via Finder)
#      - ~/Library/Caches
#      - Adobe media cache (if present)
#      - ~/.Trash

set -uo pipefail

DRY_RUN="${DRY_RUN:-0}"
OK=$'\xe2\x9c\x85'    # ✅
FAIL=$'\xe2\x9d\x8c'  # ❌
WARN=$'\xe2\x9a\xa0'  # ⚠

# Admin accounts to never use as the "real user"
SKIP_USERS="gadmin root _mbsetupuser daemon nobody"

# ── Require root ──────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo "[FAIL] must run as root" >&2; exit 1
fi

# ── Detect real user ──────────────────────────────────────────────────────────
# Priority: console user (if not admin) → most frequent login in last 7 days
get_real_user() {
    local cu
    cu=$(stat -f '%Su' /dev/console 2>/dev/null | tr -d ' ')
    if [[ -n "$cu" ]] && ! echo "$SKIP_USERS" | grep -qw "$cu"; then
        echo "$cu"; return
    fi

    # Fall back: most frequent non-admin user from 'last' (7-day window)
    last 2>/dev/null \
        | awk 'NF>2 && !/reboot|shutdown|wtmp begins/ {print $1}' \
        | grep -vwE "$(echo "$SKIP_USERS" | tr ' ' '|')" \
        | sort | uniq -c | sort -rn \
        | awk 'NR==1 {print $2}'
}

REAL_USER="$(get_real_user)"

if [[ -z "$REAL_USER" ]]; then
    echo "[${WARN}] Could not determine real user — skipping per-user exclusions"
    USER_HOME=""
else
    USER_HOME="$(dscl . -read /Users/"${REAL_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [[ -z "$USER_HOME" ]] && USER_HOME="/Users/${REAL_USER}"
fi

# ── Helper: add exclusion ─────────────────────────────────────────────────────
added=0; skipped_missing=0; already=0; dry_listed=""

add_excl() {
    local path="$1"
    if [[ ! -e "$path" ]]; then
        (( skipped_missing++ )); return
    fi
    # Check if already excluded (xattr com.apple.timemachine.donotbackup)
    if xattr "$path" 2>/dev/null | grep -q "com.apple.timemachine.donotbackup"; then
        (( already++ )); return
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        dry_listed+="  WOULD EXCLUDE: ${path}\n"
    else
        tmutil addexclusion -p "$path" 2>/dev/null
        (( added++ ))
    fi
}

# ── 1. RequiresACPower ────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
    cur_ac=$(defaults read /Library/Preferences/com.apple.TimeMachine RequiresACPower 2>/dev/null || echo "0")
    [[ "$cur_ac" == "1" ]] && ac_note="WOULD set to false" || ac_note="already false"
else
    defaults write /Library/Preferences/com.apple.TimeMachine RequiresACPower -bool false
    ac_val=$(defaults read /Library/Preferences/com.apple.TimeMachine RequiresACPower 2>/dev/null)
    [[ "$ac_val" == "0" ]] && ac_note="now false ${OK}" || ac_note="FAILED ${FAIL}"
fi

# ── 2. Per-user exclusions ────────────────────────────────────────────────────
if [[ -n "$USER_HOME" ]]; then

    # Cloud storage (Google Drive, iCloud Drive, OneDrive, Box, Dropbox, etc.)
    add_excl "${USER_HOME}/Library/CloudStorage"

    # iCloud Drive legacy path
    add_excl "${USER_HOME}/Library/Mobile Documents"

    # Mail — exclude per-account message folders; KEEP MailData (signatures, rules)
    # Structure: ~/Library/Mail/V10/<UUID or account name>/  (re-downloadable IMAP cache)
    #            ~/Library/Mail/V10/MailData/                 (keep — signatures, rules)
    MAIL_V10="${USER_HOME}/Library/Mail/V10"
    if [[ -d "$MAIL_V10" ]]; then
        for subdir in "${MAIL_V10}"/*/; do
            [[ ! -d "$subdir" ]] && continue
            basename="$(basename "$subdir")"
            if [[ "$basename" == "MailData" ]]; then
                : # keep — contains signatures (.mailsignature), rules, smart mailboxes
            else
                add_excl "$subdir"  # account message cache — safe to exclude
            fi
        done
    fi

    # iPhone/iPad backups via Finder
    add_excl "${USER_HOME}/Library/Application Support/MobileSync/Backup"

    # App caches (all rebuild on launch)
    add_excl "${USER_HOME}/Library/Caches"

    # Adobe media cache (Premiere, After Effects, Audition)
    add_excl "${USER_HOME}/Library/Application Support/Adobe/Common/Media Cache Files"
    add_excl "${USER_HOME}/Library/Application Support/Adobe/Common/Media Cache"
    add_excl "${USER_HOME}/Library/Caches/Adobe"

    # Trash
    add_excl "${USER_HOME}/.Trash"

fi

# ── Report ────────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
    echo "=== DRY RUN — no changes made ==="
    echo "RequiresACPower: ${ac_note}"
    echo "Real user: ${REAL_USER:-unknown} (home: ${USER_HOME:-n/a})"
    echo "Would exclude (${added} new | ${already} already set | ${skipped_missing} not present):"
    printf "${dry_listed}"
else
    if [[ -z "$REAL_USER" ]]; then
        ICON="$WARN"
    else
        ICON="$OK"
    fi
    echo "[OK] ${ICON} user=${REAL_USER:-unknown} | ac_pwr=off | excl_added=${added} | already=${already} | missing=${skipped_missing}"
fi
