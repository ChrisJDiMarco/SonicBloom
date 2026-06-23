#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

dry_run=0
skip_build=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      ;;
    --skip-build)
      skip_build=1
      ;;
    *)
      echo "usage: Scripts/package_release.sh [--dry-run] [--skip-build]" >&2
      exit 64
      ;;
  esac
  shift
done

app="dist/SonicBloom.app"
plist="$app/Contents/Info.plist"
pkg_dir="dist/release"
identity="${SONICBLOOM_INSTALLER_IDENTITY:-}"
notary_profile="${SONICBLOOM_NOTARY_PROFILE:-}"
minimum_system_version="13.0"

quote() {
  printf "%q" "$1"
}

run() {
  if [[ "$dry_run" == "1" ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %s' "$(quote "$arg")"
    done
    printf '\n'
  else
    "$@"
  fi
}

if [[ "$skip_build" == "0" ]]; then
  run Scripts/build_app.sh
fi

if [[ "$dry_run" == "0" && ! -d "$app" ]]; then
  echo "missing $app; run Scripts/build_app.sh first" >&2
  exit 66
fi

version="0.1.0"
if [[ "$dry_run" == "0" ]]; then
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
fi
pkg="$pkg_dir/SonicBloom-$version.pkg"
package_url="${SONICBLOOM_PACKAGE_URL:-https://github.com/ChrisJDiMarco/SonicBloom/releases/download/v$version/SonicBloom-$version.pkg}"

run mkdir -p "$pkg_dir"
run cp Scripts/uninstall_sonicbloom.sh "$pkg_dir/SonicBloom-Uninstall.command"
run chmod +x "$pkg_dir/SonicBloom-Uninstall.command"
if [[ -n "$identity" ]]; then
  run productbuild --component "$app" /Applications --identifier com.chrisdimarco.sonicbloom.pkg --version "$version" --sign "$identity" "$pkg"
else
  run productbuild --component "$app" /Applications --identifier com.chrisdimarco.sonicbloom.pkg --version "$version" "$pkg"
fi

if [[ -n "$notary_profile" ]]; then
  run xcrun notarytool submit "$pkg" --keychain-profile "$notary_profile" --wait
  run xcrun stapler staple "$pkg"
fi

manifest="$pkg_dir/SonicBloom-update.json"
if [[ "$dry_run" == "1" ]]; then
  echo "+ write $manifest"
else
  package_sha256="$(shasum -a 256 "$pkg" | awk '{print $1}')"
  cat > "$manifest" <<JSON
{
  "version": "$version",
  "minimumSystemVersion": "$minimum_system_version",
  "packageURL": "$package_url",
  "packageSHA256": "$package_sha256",
  "notes": "SonicBloom $version"
}
JSON
fi

echo "$PWD/$pkg"
