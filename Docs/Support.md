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
- macOS version and Mac model
- output device name
- SonicBloom preset and sync mode
- whether the issue happens in YouTube, Spotify, Zoom, games, or all apps
- the Trust & Health diagnostics: output, latency, buffer, CPU, content, and clips
