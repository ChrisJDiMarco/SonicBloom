#!/usr/bin/env bash
set -euo pipefail

app="/Applications/SonicBloom.app"
driver="/Library/Audio/Plug-Ins/HAL/SonicBloomHAL.driver"
plist="$HOME/Library/LaunchAgents/com.chrisdimarco.sonicbloom.recovery.plist"
support="$HOME/Library/Application Support/SonicBloom"
preferences="$HOME/Library/Preferences/com.chrisdimarco.sonicbloom.plist"
caches="$HOME/Library/Caches/com.chrisdimarco.sonicbloom"
saved_state="$HOME/Library/Saved Application State/com.chrisdimarco.sonicbloom.savedState"

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

rm -rf "$support" "$caches" "$saved_state"
rm -f "$preferences" /tmp/SonicBloomHAL.log /tmp/SonicBloomRecovery.log /tmp/SonicBloomRecovery.err

echo "SonicBloom app, HAL driver, recovery agent, preferences, and support files removed."
