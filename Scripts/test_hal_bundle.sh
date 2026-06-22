#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
Scripts/build_hal_driver.sh >/dev/null

driver="BuildAssets/SonicBloomHAL.driver"
test -x "$driver/Contents/MacOS/SonicBloomHAL"
plutil -lint "$driver/Contents/Info.plist" >/dev/null
plutil -extract CFPlugInFactories raw "$driver/Contents/Info.plist" >/dev/null
nm -gU "$driver/Contents/MacOS/SonicBloomHAL" | grep -q '_SonicBloomHAL_Create'
codesign --verify "$driver"

echo "SonicBloomHAL bundle OK"
