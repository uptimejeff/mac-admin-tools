# Mosyle Setup — Time Machine Advisor

## Environment Variables

| Variable | Source | Description |
|---|---|---|
| `SLACK_ITDEPT_ALERTS` | grafik.env | IT channel incoming webhook URL |
| `SLACK_BOT_TOKEN` | Phase 2 | xoxb- token for user DMs |
| `MOSYLE_DEVICE_NAME` | %DeviceName% | Device display name |
| `MOSYLE_USER_EMAIL` | %Email% | Console user email |
| `MOSYLE_USER_FIRSTNAME` | %FirstName% | First name for user messages |
| `TM_THRESHOLD_NOTICE` | optional | Days before NOTICE (default: 4) |
| `TM_THRESHOLD_ALERT` | optional | Days before ALERT (default: 7) |
| `TM_THRESHOLD_URGENT` | optional | Days before URGENT (default: 14) |

## Script 1: tm-advisor (Mosyle scheduled, daily)

```bash
export SLACK_ITDEPT_ALERTS="WEBHOOK_URL_HERE"
export MOSYLE_DEVICE_NAME="%DeviceName%"
export MOSYLE_USER_EMAIL="%Email%"
export MOSYLE_USER_FIRSTNAME="%FirstName%"
curl -fsSL https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main/time-machine/tm-advisor.sh | bash
```

## Script 2: tm-autobackup LaunchDaemon (one-time deploy)

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
