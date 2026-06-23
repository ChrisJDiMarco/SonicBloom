#!/usr/bin/env bash
set -euo pipefail

app="/Applications/SonicBloom.app"
driver="/Library/Audio/Plug-Ins/HAL/SonicBloomHAL.driver"
plist="$HOME/Library/LaunchAgents/com.chrisdimarco.sonicbloom.recovery.plist"

launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
rm -f "$plist"

osascript -e 'quit app "SonicBloom"' >/dev/null 2>&1 || true
pkill -x SonicBloom >/dev/null 2>&1 || true
"$app/Contents/MacOS/SonicBloomRecovery" --once >/dev/null 2>&1 || true
pkill -x SonicBloomRecovery >/dev/null 2>&1 || true

if [[ -d "$app" ]]; then
  sudo rm -rf "$app"
fi

if [[ -d "$driver" ]]; then
  sudo rm -rf "$driver"
  sudo killall coreaudiod >/dev/null 2>&1 || true
fi

echo "SonicBloom app, HAL driver, and recovery agent removed."
