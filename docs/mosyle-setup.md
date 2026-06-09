# Mosyle Setup — Time Machine Advisor

## Environment Variables

| Variable | Source | Description |
|---|---|---|
| `SLACK_ITDEPT_ALERTS` | your env file | IT channel incoming webhook URL |
| `SLACK_BOT_TOKEN` | Phase 2 | xoxb- token for user DMs |
| `MOSYLE_DEVICE_NAME` | %DeviceName% | Device display name |
| `MOSYLE_USER_EMAIL` | %Email% | Console user email |
| `MOSYLE_USER_FIRSTNAME` | %FirstName% | First name for user messages |
| `TM_THRESHOLD_NOTICE` | optional | Days before NOTICE (default: 4) |
| `TM_THRESHOLD_ALERT` | optional | Days before ALERT (default: 7) |
| `TM_THRESHOLD_URGENT` | optional | Days before URGENT (default: 14) |

## Script 1: tm-advisor (Mosyle scheduled, daily)

Scope: All Devices | Trigger: Every 4h + on script save
Sends Slack alert to IT if backup is stale (4/7/14d thresholds).
Posts status to HealthAdvisor dashboard if HA_URL is set.

```bash
# tm-advisor — TM status check, Slack alerts, HealthAdvisor POST
# Scope: All Devices | Schedule: every 4h
# Secrets: SLACK_ITDEPT_ALERTS webhook from grafik.env; never commit to GitHub
export SLACK_ITDEPT_ALERTS="WEBHOOK_URL_HERE"
export MOSYLE_DEVICE_NAME="%DeviceName%"
export MOSYLE_USER_EMAIL="%Email%"
export MOSYLE_USER_FIRSTNAME="%FirstName%"
# Optional: POST to HealthAdvisor dashboard
# export HA_URL="http://100.99.1.123:3000"
# export HA_API_TOKEN="TOKEN_HERE"
curl -fsSL https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main/time-machine/tm-advisor.sh | bash
```

## Script 2: tm-exclusions (Mosyle scheduled, every checkin)

Scope: All Devices | Trigger: Every checkin (idempotent — safe to repeat)
Sets RequiresACPower=false fleet-wide. Adds sticky TM exclusions per user:
CloudStorage, Mail message cache (keeps signatures/rules), MobileSync backups,
~/Library/Caches, Adobe media cache, Trash. No secrets required.

```bash
# tm-exclusions — TM settings enforcement + per-user exclusions
# Scope: All Devices | Schedule: every checkin
# No secrets needed — no vars to set
export MOSYLE_DEVICE_NAME="%DeviceName%"
curl -fsSL https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main/time-machine/tm-exclusions.sh | bash
```

## Script 3: tm-autobackup LaunchDaemon (one-time deploy)

```bash
WEBHOOK="WEBHOOK_URL_HERE"
DEVICE="%DeviceName%"
EMAIL="%Email%"
INSTALL_DIR="/usr/local/osxgroup"
mkdir -p "$INSTALL_DIR"
curl -fsSL https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main/time-machine/tm-autobackup.sh \
    -o "${INSTALL_DIR}/tm-autobackup.sh"
chmod +x "${INSTALL_DIR}/tm-autobackup.sh"
curl -fsSL https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main/time-machine/com.osxgroup.tm-autobackup.plist \
    | sed "s|REPLACE_SLACK_WEBHOOK|${WEBHOOK}|" \
    | sed "s|REPLACE_DEVICE_NAME|${DEVICE}|" \
    | sed "s|REPLACE_USER_EMAIL|${EMAIL}|" \
    > /Library/LaunchDaemons/com.osxgroup.tm-autobackup.plist
chmod 644 /Library/LaunchDaemons/com.osxgroup.tm-autobackup.plist
chown root:wheel /Library/LaunchDaemons/com.osxgroup.tm-autobackup.plist
launchctl bootout system/com.osxgroup.tm-autobackup 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.osxgroup.tm-autobackup.plist
echo "[OK] tm-autobackup installed"
```

## Mosyle Profile — TM Menu Bar

Domain: com.apple.TimeMachine
Key: ShowMenuExtra  Type: Boolean  Value: true

## Alert levels

| Level | Days | Sent to |
|---|---|---|
| NOTICE | 4-6 | IT channel |
| ALERT | 7-13 | IT channel |
| URGENT | 14+ | IT channel |
| (user DM) | Phase 2 | User via bot |
