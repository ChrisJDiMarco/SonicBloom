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
app_identity="${SONICBLOOM_APP_IDENTITY:-}"
notary_profile="${SONICBLOOM_NOTARY_PROFILE:-}"
manifest_signature="${SONICBLOOM_UPDATE_MANIFEST_SIGNATURE:-}"
manifest_private_key="${SONICBLOOM_UPDATE_MANIFEST_PRIVATE_KEY_HEX:-}"
minimum_system_version="13.0"

if [[ -n "$notary_profile" && -z "$identity" ]]; then
  echo "SONICBLOOM_NOTARY_PROFILE requires SONICBLOOM_INSTALLER_IDENTITY so the package can be signed before notarization." >&2
  exit 65
fi

if [[ -n "$notary_profile" && "$skip_build" == "0" && -z "$app_identity" ]]; then
  echo "SONICBLOOM_NOTARY_PROFILE requires SONICBLOOM_APP_IDENTITY when building the app for notarization." >&2
  exit 65
fi

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

if [[ "$package_url" != https://* ]]; then
  echo "SONICBLOOM_PACKAGE_URL must use https://" >&2
  exit 65
fi

package_url_path="${package_url%%\?*}"
package_url_path="${package_url_path%%#*}"
package_url_path_lc="$(printf '%s' "$package_url_path" | tr '[:upper:]' '[:lower:]')"
if [[ "$package_url_path_lc" != *.pkg ]]; then
  echo "SONICBLOOM_PACKAGE_URL must end in .pkg" >&2
  exit 65
fi

if [[ -n "$manifest_signature" ]] && { ! [[ "$manifest_signature" =~ ^[0-9A-Fa-f]+$ ]] || (( ${#manifest_signature} % 2 != 0 )); }; then
  echo "SONICBLOOM_UPDATE_MANIFEST_SIGNATURE must be even-length hex" >&2
  exit 65
fi

if [[ -n "$manifest_private_key" && -n "$manifest_signature" ]]; then
  echo "Use SONICBLOOM_UPDATE_MANIFEST_PRIVATE_KEY_HEX or SONICBLOOM_UPDATE_MANIFEST_SIGNATURE, not both." >&2
  exit 65
fi

if [[ -n "$manifest_private_key" ]] && { ! [[ "$manifest_private_key" =~ ^[0-9A-Fa-f]+$ ]] || (( ${#manifest_private_key} % 2 != 0 )); }; then
  echo "SONICBLOOM_UPDATE_MANIFEST_PRIVATE_KEY_HEX must be even-length hex" >&2
  exit 65
fi

run mkdir -p "$pkg_dir"
run cp Scripts/uninstall_sonicbloom.sh "$pkg_dir/SonicBloom-Uninstall.command"
run cp Scripts/install_recovery_agent.sh "$pkg_dir/SonicBloom-Install-Recovery.command"
run cp Docs/Support.md "$pkg_dir/SonicBloom-Support.md"
run chmod +x "$pkg_dir/SonicBloom-Uninstall.command"
run chmod +x "$pkg_dir/SonicBloom-Install-Recovery.command"
if [[ -n "$identity" ]]; then
  run productbuild --component "$app" /Applications --identifier com.chrisdimarco.sonicbloom.pkg --version "$version" --sign "$identity" "$pkg"
  run pkgutil --check-signature "$pkg"
else
  run productbuild --component "$app" /Applications --identifier com.chrisdimarco.sonicbloom.pkg --version "$version" "$pkg"
fi

if [[ -n "$notary_profile" ]]; then
  run xcrun notarytool submit "$pkg" --keychain-profile "$notary_profile" --wait
  run xcrun stapler staple "$pkg"
  run xcrun stapler validate "$pkg"
  run spctl -a -vv -t install "$pkg"
fi

manifest="$pkg_dir/SonicBloom-update.json"
if [[ "$dry_run" == "1" ]]; then
  echo "+ write $manifest"
else
  package_sha256="$(shasum -a 256 "$pkg" | awk '{print $1}')"
  notes="SonicBloom $version"
  if [[ -z "$manifest_signature" && -n "$manifest_private_key" ]]; then
    manifest_signature="$(SONICBLOOM_UPDATE_MANIFEST_PRIVATE_KEY_HEX="$manifest_private_key" swift run -c release SonicBloomManifestSigner sign "$version" "$minimum_system_version" "$package_url" "$package_sha256" "$notes")"
  fi
  if [[ -n "$manifest_signature" ]]; then
    cat > "$manifest" <<JSON
{
  "version": "$version",
  "minimumSystemVersion": "$minimum_system_version",
  "packageURL": "$package_url",
  "packageSHA256": "$package_sha256",
  "notes": "$notes",
  "manifestSignature": "$manifest_signature"
}
JSON
  else
    cat > "$manifest" <<JSON
{
  "version": "$version",
  "minimumSystemVersion": "$minimum_system_version",
  "packageURL": "$package_url",
  "packageSHA256": "$package_sha256",
  "notes": "$notes"
}
JSON
  fi
fi

echo "$PWD/$pkg"
