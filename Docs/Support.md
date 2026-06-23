# SonicBloom Support

SonicBloom routes Mac audio through `SonicBloom Output`, processes it, then sends it to your selected speakers or headphones. If anything feels wrong, recover the Mac output first.

## If audio goes silent

1. Open macOS Control Center > Sound.
2. Choose your real output device, such as MacBook Speakers, AirPods, HDMI, or a USB DAC.
3. Reopen SonicBloom and click `Refresh Route`.
4. If audio is still silent, quit SonicBloom and run `SonicBloom-Uninstall.command` from the release download.

## Reset Mac Output

Use this when macOS is still set to `SonicBloom Output` after a crash, failed driver install, or uninstall.

```bash
/Applications/SonicBloom.app/Contents/MacOS/SonicBloomRecovery --once
```

If SonicBloom is no longer installed, pick a real output manually in macOS Sound settings.

## Microphone permission

macOS may show a microphone permission prompt because virtual system-audio devices can appear as input devices to Core Audio. SonicBloom uses `SonicBloom Output` to process app audio; it does not need your physical microphone for music enhancement.

## Install, update, uninstall

- Install: open `SonicBloom.pkg`, then open SonicBloom and install `SonicBloom Output` when prompted.
- Update: use Settings > Maintenance > Check for Updates. SonicBloom verifies the package checksum before opening the installer.
- Uninstall: run `SonicBloom-Uninstall.command`. It quits SonicBloom, restores Mac output, removes the app, removes `SonicBloomHAL.driver`, unloads the recovery agent, and deletes SonicBloom preferences/support files.

## Diagnostics

When reporting an issue, include:

- the text from Settings > Maintenance > Copy Diagnostics
- the text from Settings > Maintenance > Copy Support Bundle
- macOS version and Mac model
- output device name
- SonicBloom preset and sync mode
- Spatial Profile from diagnostics, especially after importing BRIR / SOFA JSON
- whether the issue happens in YouTube, Spotify, Zoom, games, or all apps
- the Trust & Health diagnostics: output, latency, buffer, CPU, content, and clips

Copy Support Bundle includes diagnostics, recent route/driver events, HAL logs, recovery logs, and a known-issues checklist.

## Known Issues Checklist

- Bluetooth and AirPods can briefly disappear during macOS device switches. Use Repair Audio if playback does not recover.
- Some third-party Audio Units can crackle or fail to render. Remove the effect and retry before blaming the main route.
- Binary `.sofa` files need conversion to JSON before import.
- Unsigned local builds may show macOS security prompts until the app is signed and notarized.

## BRIR / SOFA Imports

SonicBloom imports BRIR/HRTF profiles from JSON or SOFA-style JSON exports. Binary `.sofa` files are HDF5 containers; convert them to JSON first with your SOFA/HDF5 toolchain, then import the JSON from the Calibration Wizard.

After import, Copy Diagnostics should show `Spatial Profile: <profile name>`. If it still says `Synthetic HRTF`, the imported profile is not active.

## Per-App Profiles

Per-app processing uses macOS process taps when an app exposes a running audio process. If a row says waiting, silent, or unavailable, keep the master preset as the source of truth and use Refresh Route after the app starts playing audio.
