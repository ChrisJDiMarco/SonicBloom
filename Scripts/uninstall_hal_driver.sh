#!/usr/bin/env bash
set -euo pipefail

sudo rm -rf /Library/Audio/Plug-Ins/HAL/SonicBloomHAL.driver
sudo killall coreaudiod
echo "Removed SonicBloomHAL.driver"
