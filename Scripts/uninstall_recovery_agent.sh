#!/usr/bin/env bash
set -euo pipefail

plist="$HOME/Library/LaunchAgents/com.chrisdimarco.sonicbloom.recovery.plist"
launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
rm -f "$plist"
echo "Removed SonicBloom recovery agent"
