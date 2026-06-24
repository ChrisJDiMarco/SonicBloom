#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

strict=0
if [[ "${1:-}" == "--strict" ]]; then
  strict=1
  shift
fi
if [[ $# -gt 0 ]]; then
  echo "usage: Scripts/qa_gate.sh [--strict]" >&2
  exit 64
fi

swift test
swift build -c release --product SonicBloomManifestSigner
Scripts/build_app.sh
Scripts/test_hal_bundle.sh
Scripts/package_release.sh --skip-build
if [[ "$strict" == "1" ]]; then
  Scripts/release_readiness.sh --strict
else
  Scripts/release_readiness.sh
fi
