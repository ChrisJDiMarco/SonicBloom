#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

driver="BuildAssets/SonicBloomHAL.driver"
trace_flag=""
sign_identity="${SONICBLOOM_APP_IDENTITY:--}"
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

codesign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
  codesign_args+=(--options runtime --timestamp)
fi
codesign "${codesign_args[@]}" "$driver" >/dev/null
echo "$PWD/$driver"
