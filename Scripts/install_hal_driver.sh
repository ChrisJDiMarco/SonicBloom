#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
Scripts/build_hal_driver.sh >/dev/null

target="/Library/Audio/Plug-Ins/HAL/SonicBloomHAL.driver"
sudo rm -rf "$target"
sudo ditto BuildAssets/SonicBloomHAL.driver "$target"
sudo chown -R root:wheel "$target"
sudo killall coreaudiod

echo "$target"
