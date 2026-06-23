# SonicBloom

SonicBloom is a macOS 13+ system-audio enhancer prototype: native menu bar app, open presets, and a real-time stereo DSP core with EQ, bass, width, clean loudness, and clipping protection.

The current build includes the app shell, route-state boundary, preset JSON, C++ DSP engine, Swift wrapper, tests, and a from-scratch HAL audio server plug-in prototype named `SonicBloom Output`.

## Run

```bash
swift test
swift run SonicBloom
Scripts/build_app.sh
open dist/SonicBloom.app
```

The app bundle includes `SonicBloomHAL.driver`. Press **Install SonicBloom Output** in the app to copy it into `/Library/Audio/Plug-Ins/HAL/` with the standard macOS administrator prompt and restart Core Audio.

## Package

```bash
Scripts/package_release.sh
SONICBLOOM_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)" Scripts/package_release.sh
SONICBLOOM_APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" SONICBLOOM_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)" SONICBLOOM_NOTARY_PROFILE="sonicbloom-notary" Scripts/package_release.sh
```

The package installs `SonicBloom.app` into `/Applications`. Signing and notarization are enabled by environment variables so local development still works without Apple Developer credentials.
Set `SONICBLOOM_UPDATE_MANIFEST_PUBLIC_KEY_HEX` while building the app to require signed update manifests, then set `SONICBLOOM_UPDATE_MANIFEST_PRIVATE_KEY_HEX` while packaging so the release manifest is signed after the package checksum is known.
Each release also writes `dist/release/SonicBloom-Uninstall.command`, which removes the app, SonicBloom HAL driver, and recovery LaunchAgent.
It also writes `dist/release/SonicBloom-update.json` with the package URL and SHA-256; upload that beside the `.pkg` release asset so the in-app updater can detect new builds.

## QA

Before calling a build stable, run the automated checks and live-device scenarios in [Docs/QA-Matrix.md](Docs/QA-Matrix.md).

## What Exists

- Native AppKit/SwiftUI control panel
- Menu bar status item
- Clickable `.app` bundle with generated SonicBloom icon
- `SonicBloom Output` route state model
- 10 built-in presets
- 31-band EQ API
- C++ DSP core with Swift wrapper
- Custom preset JSON store
- Unit tests for presets, DSP safety, and route defaults
- Bundled `SonicBloomHAL.driver` virtual duplex output/input prototype

## Release Work Left

The HAL driver is intentionally small and source-owned. Before public release it still needs production Developer ID credentials and broader device recovery testing. Long-session playback should be tracked with `Scripts/stability_watch.sh`.
