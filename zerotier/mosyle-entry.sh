#!/bin/bash
# Mosyle entry point for update-zerotier-names.sh
# Paste THIS into Mosyle — credentials stay here, logic stays on GitHub.
# Rotate ZT_TOKEN in ZeroTier Central if compromised, then update here.
export ZT_NETWORK="REPLACE_WITH_NETWORK_ID"
export ZT_TOKEN="REPLACE_WITH_API_TOKEN"
curl -fsSL https://raw.githubusercontent.com/uptimejeff/mac-admin-tools/main/zerotier/update-zerotier-names.sh | bash
