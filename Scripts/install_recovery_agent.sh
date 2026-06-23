#!/usr/bin/env bash
set -euo pipefail

write_only=0
if [[ "${1:-}" == "--write-only" ]]; then
  write_only=1
  shift
fi

app="${1:-/Applications/SonicBloom.app}"
helper="$app/Contents/MacOS/SonicBloomRecovery"
plist="$HOME/Library/LaunchAgents/com.chrisdimarco.sonicbloom.recovery.plist"
interval="${SONICBLOOM_RECOVERY_INTERVAL:-2}"

if [[ ! -x "$helper" ]]; then
  echo "missing recovery helper: $helper" >&2
  exit 66
fi

if ! [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "SONICBLOOM_RECOVERY_INTERVAL must be numeric" >&2
  exit 64
fi

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

escaped_helper="$(xml_escape "$helper")"

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
    <string>$escaped_helper</string>
    <string>--watch</string>
    <string>--interval</string>
    <string>$interval</string>
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

/usr/bin/plutil -lint "$plist" >/dev/null
if [[ "$write_only" == "0" ]]; then
  launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$plist"
fi
echo "$plist"
