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

## Driver Work Left

The HAL driver is intentionally small and source-owned. Before public release it still needs hardened signing/notarization, long-session latency/dropout work, and a lock-free audio ring buffer.
