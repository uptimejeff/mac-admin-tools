#!/usr/bin/env bash
# common/slack.sh — Shared Slack posting functions
# 2026-06-04 v1.2 — add DRY_RUN=1 support
# Source this file; do not execute directly.
#
# Required env vars (set by Mosyle or caller):
#   SLACK_ITDEPT_ALERTS   — incoming webhook URL for IT alerts channel
#
# Optional env vars:
#   SLACK_BOT_TOKEN       — xoxb- token for user DMs (Phase 2)

# Post a message to the IT alerts webhook.
# Usage: slack_post_it <text>
slack_post_it() {
    local text="$1"

    # DRY_RUN=1 — print to stdout instead of posting to Slack (for testing)
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "--- DRY RUN: Slack message would be ---"
        echo "$text"
        echo "--- end ---"
        return 0
    fi

    if [[ -z "${SLACK_ITDEPT_ALERTS:-}" ]]; then
        echo "SLACK_ITDEPT_ALERTS not set — skipping Slack post" >&2
        return 1
    fi

    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}))' <<< "$text")

    local response
    response=$(curl -sSL -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$SLACK_ITDEPT_ALERTS" 2>&1)

    if [[ "$response" != "ok" ]]; then
        echo "Slack post response: $response" >&2
    fi
}

# Post a DM to a Slack user by email (requires SLACK_BOT_TOKEN).
# Usage: slack_dm_user <email> <text>
# Phase 2 — not active until bot token is configured and tested.
slack_dm_user() {
    local email="$1"
    local text="$2"

    if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
        echo "SLACK_BOT_TOKEN not set — user DM skipped" >&2
        return 0
    fi
    [[ -z "$email" ]] && { echo "No email provided for DM" >&2; return 1; }

    # Look up Slack user ID by email
    local user_id
    user_id=$(curl -sSL \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        "https://slack.com/api/users.lookupByEmail?email=${email}" \
        2>/dev/null | python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(d["user"]["id"] if d.get("ok") else "")' \
        2>/dev/null)

    if [[ -z "$user_id" ]]; then
        echo "Could not resolve Slack ID for $email" >&2
        return 1
    fi

    # Open DM channel
    local channel_id
    channel_id=$(curl -sSL -X POST \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"users\":\"${user_id}\"}" \
        "https://slack.com/api/conversations.open" \
        2>/dev/null | python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(d["channel"]["id"] if d.get("ok") else "")' \
        2>/dev/null)

    if [[ -z "$channel_id" ]]; then
        echo "Could not open DM channel for $email" >&2
        return 1
    fi

    # Send message
    local payload
    payload=$(python3 -c \
        'import json,sys; args=sys.argv; print(json.dumps({"channel":args[1],"text":args[2]}))' \
        "$channel_id" "$text")

    curl -sSL -X POST \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://slack.com/api/chat.postMessage" > /dev/null 2>&1
}
