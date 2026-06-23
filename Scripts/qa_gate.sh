#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift test
swift build -c release --product SonicBloomManifestSigner
Scripts/build_app.sh
Scripts/test_hal_bundle.sh
Scripts/package_release.sh --skip-build
Scripts/release_readiness.sh
