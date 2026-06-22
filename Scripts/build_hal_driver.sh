#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

driver="BuildAssets/SonicBloomHAL.driver"
trace_flag=""
if [[ "${SONICBLOOM_HAL_TRACE:-0}" == "1" ]]; then
  trace_flag="-DSONICBLOOM_HAL_TRACE=1"
fi
contents="$driver/Contents"
rm -rf "$driver"
mkdir -p "$contents/MacOS" "$contents/Resources"

cp Sources/SonicBloomHAL/Info.plist "$contents/Info.plist"

clang \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-unused-parameter \
  -fvisibility=hidden \
  ${trace_flag:+"$trace_flag"} \
  -bundle \
  -framework CoreAudio \
  -framework CoreFoundation \
  Sources/SonicBloomHAL/SonicBloomHAL.c \
  -o "$contents/MacOS/SonicBloomHAL"

codesign --force --sign - "$driver" >/dev/null
echo "$PWD/$driver"
