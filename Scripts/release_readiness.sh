#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

warnings=0
failures=0
strict=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      strict=1
      ;;
    *)
      echo "usage: Scripts/release_readiness.sh [--strict]" >&2
      exit 64
      ;;
  esac
  shift
done

pass() { printf 'PASS %s\n' "$1"; }
warn() { warnings=$((warnings + 1)); printf 'WARN %s\n' "$1"; }
fail() { failures=$((failures + 1)); printf 'FAIL %s\n' "$1"; }

require_file() {
  if [[ -e "$1" ]]; then
    pass "$1 exists"
  else
    fail "$1 missing"
  fi
}

require_file "dist/SonicBloom.app"
require_file "dist/release/SonicBloom-Support.md"
require_file "dist/release/SonicBloom-Uninstall.command"
require_file "dist/release/SonicBloom-update.json"
require_file "Docs/Support.md"
require_file "Docs/QA-Matrix.md"
require_file "Scripts/stability_watch.sh"
require_file "Scripts/uninstall_sonicbloom.sh"

if [[ -n "${SONICBLOOM_APP_IDENTITY:-}" ]]; then
  pass "SONICBLOOM_APP_IDENTITY configured"
else
  warn "SONICBLOOM_APP_IDENTITY not set; app bundle will not be Developer ID signed"
fi

if [[ -n "${SONICBLOOM_INSTALLER_IDENTITY:-}" ]]; then
  pass "SONICBLOOM_INSTALLER_IDENTITY configured"
else
  warn "SONICBLOOM_INSTALLER_IDENTITY not set; installer will not be Developer ID signed"
fi

if [[ -n "${SONICBLOOM_NOTARY_PROFILE:-}" ]]; then
  pass "SONICBLOOM_NOTARY_PROFILE configured"
else
  warn "SONICBLOOM_NOTARY_PROFILE not set; package will not be notarized"
fi

if [[ -n "${SONICBLOOM_UPDATE_MANIFEST_PUBLIC_KEY_HEX:-}" || -n "${SONICBLOOM_UPDATE_MANIFEST_PRIVATE_KEY_HEX:-}" ]]; then
  pass "update manifest signing variables present"
else
  warn "update manifest signing variables not set"
fi

if [[ "$failures" -gt 0 ]]; then
  printf 'Release readiness failed: %d failure(s), %d warning(s)\n' "$failures" "$warnings" >&2
  exit 1
fi

if [[ "$strict" == "1" && "$warnings" -gt 0 ]]; then
  printf 'Strict release readiness failed: %d warning(s)\n' "$warnings" >&2
  exit 1
fi

printf 'Release readiness passed with %d warning(s)\n' "$warnings"
