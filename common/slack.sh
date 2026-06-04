#!/usr/bin/env bash
# common/slack.sh — Shared Slack posting functions
# 2026-06-04 v1.0
# Source this file; do not execute directly.
#
# Required env vars (set by Mosyle or caller):
#   SLACK_ITDEPT_ALERTS   — incoming webhook URL for IT alerts channel
#
# Optional env vars:
#   SLACK_BOT_TOKEN       — xoxb- token for user DMs (Phase 2)

# Post a message to the IT alerts webhook.
# Usage: slack_post_it <text>  [<blocks_json>]
slack_post_it() {
    local text="$1"
    local blocks="$2"

    [[ -z "$SLACK_ITDEPT_ALERTS" ]] && { echo "SLACK_ITDEPT_ALERTS not set" >&2; return 1; }

    local payload
    if [[ -n "$blocks" ]]; then
        payload=$(printf '{"text":%s,"blocks":%s}' \
            "$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
            "$blocks")
    else
        payload=$(printf '{"text":%s}' \
            "$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
    fi

    curl -fsSL -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$SLACK_ITDEPT_ALERTS" > /dev/null 2>&1
}

# Post a DM to a Slack user by email (requires SLACK_BOT_TOKEN).
# Usage: slack_dm_user <email> <text>
# Phase 2 — not active until bot token is configured and tested.
slack_dm_user() {
    local email="$1"
    local text="$2"

    [[ -z "$SLACK_BOT_TOKEN" ]] && { echo "SLACK_BOT_TOKEN not set — user DM skipped" >&2; return 0; }
    [[ -z "$email" ]]           && { echo "No email provided for DM" >&2; return 1; }

    # Look up Slack user ID by email
    local user_id
    user_id=$(curl -fsSL \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        "https://slack.com/api/users.lookupByEmail?email=${email}" \
        2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["user"]["id"] if d.get("ok") else "")' 2>/dev/null)

    [[ -z "$user_id" ]] && { echo "Could not resolve Slack ID for $email" >&2; return 1; }

    # Open DM channel
    local channel_id
    channel_id=$(curl -fsSL -X POST \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"users\":\"${user_id}\"}" \
        "https://slack.com/api/conversations.open" \
        2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["channel"]["id"] if d.get("ok") else "")' 2>/dev/null)

    [[ -z "$channel_id" ]] && { echo "Could not open DM channel for $email" >&2; return 1; }

    # Send message
    curl -fsSL -X POST \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(printf '{"channel":"%s","text":%s}' \
            "$channel_id" \
            "$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")" \
        "https://slack.com/api/chat.postMessage" > /dev/null 2>&1
}
