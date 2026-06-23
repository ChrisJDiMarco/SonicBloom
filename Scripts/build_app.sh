#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

sign_identity="${SONICBLOOM_APP_IDENTITY:--}"

swift build -c release --product SonicBloom
swift build -c release --product SonicBloomRecovery
Scripts/build_hal_driver.sh >/dev/null

app="dist/SonicBloom.app"
contents="$app/Contents"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"

cp .build/release/SonicBloom "$contents/MacOS/SonicBloom"
cp .build/release/SonicBloomRecovery "$contents/MacOS/SonicBloomRecovery"
cp Sources/SonicBloomApp/Resources/SonicBloom.icns "$contents/Resources/SonicBloom.icns"
ditto Sources/SonicBloomApp/Resources/en.lproj "$contents/Resources/en.lproj"
cp Scripts/install_recovery_agent.sh "$contents/Resources/install_recovery_agent.sh"
chmod +x "$contents/Resources/install_recovery_agent.sh"
ditto BuildAssets/SonicBloomHAL.driver "$contents/Resources/SonicBloomHAL.driver"

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>SonicBloom</string>
  <key>CFBundleIconFile</key>
  <string>SonicBloom</string>
  <key>CFBundleIdentifier</key>
  <string>com.chrisdimarco.sonicbloom</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>SonicBloom</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>macOS labels SonicBloom Output as an input device. SonicBloom uses it to enhance system audio from apps like Spotify and YouTube, not to listen to your physical microphone.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$contents/PkgInfo"
codesign_args=(--force --deep --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
  codesign_args+=(--options runtime --timestamp)
fi
codesign "${codesign_args[@]}" "$app" >/dev/null
echo "$PWD/$app"
