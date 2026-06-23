# SonicBloom QA Matrix

Use this before calling any build release-ready. Record the macOS version, Mac model, output device, SonicBloom commit, and result for every pass.

## Automated Gate

Run these first:

```bash
swift test --filter SonicBloomCoreTests
Scripts/build_app.sh
Scripts/test_hal_bundle.sh
```

Pass means the DSP, preset, routing planner, installer script, recovery planner, and packaged HAL bundle checks are green. It does not prove live-device stability.

## Live Audio Matrix

| Area | Scenario | Expected Result | Result |
| --- | --- | --- | --- |
| Built-in output | YouTube video, enhancement on/off 5 times | Audio stays synced, no silence, no stutter |  |
| Built-in output | Spotify playback for 30 minutes | No crackle/dropout, CPU stays under target |  |
| Bluetooth | AirPods connect while processing | Route recovers or asks for one clear action |  |
| Bluetooth | AirPods disconnect while processing | System output returns to a real device |  |
| USB | USB DAC selected, enhancement on/off | Audio resumes immediately on both transitions |  |
| HDMI | HDMI display audio selected | Route and meters stay valid |  |
| Sleep/wake | Sleep while processing, wake | Default output is not stranded on SonicBloom Output |  |
| Core Audio | `sudo killall coreaudiod` while processing | App recovers route and processing state |  |
| Video apps | YouTube, Netflix, Zoom | Video mode stays lip-synced |  |
| Music apps | Spotify, Music, browser audio | Music mode sounds clean, no clipping |  |
| Games | Full-screen game audio | No persistent underruns or route loss |  |
| Quit/crash | Force quit SonicBloom while active | Recovery helper restores the physical output |  |
| Uninstall | Run release uninstaller | App, HAL driver, and recovery agent are removed |  |

## Release Notes

- Test Music, Video, and Gaming sync modes separately.
- Check at 44.1 kHz and 48 kHz when the device allows it.
- Save any failing route state, output name, and last app action with the bug.
