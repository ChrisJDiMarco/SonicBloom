#!/usr/bin/env bash
set -euo pipefail

app="${1:-/Applications/SonicBloom.app}"
helper="$app/Contents/MacOS/SonicBloomRecovery"
plist="$HOME/Library/LaunchAgents/com.chrisdimarco.sonicbloom.recovery.plist"

if [[ ! -x "$helper" ]]; then
  echo "missing recovery helper: $helper" >&2
  exit 66
fi

mkdir -p "$(dirname "$plist")"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chrisdimarco.sonicbloom.recovery</string>
  <key>ProgramArguments</key>
  <array>
    <string>$helper</string>
    <string>--watch</string>
    <string>--interval</string>
    <string>2</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/SonicBloomRecovery.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/SonicBloomRecovery.err</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$plist"
echo "$plist"
