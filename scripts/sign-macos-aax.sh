#!/usr/bin/env bash
# Sign AAX with PACE and Developer ID; notarization happens in package-macos.sh.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Requires macOS.' >&2; exit 1; }
: "${DEVELOPER_ID_APPLICATION:?Set your Developer ID Application identity}"
: "${PACE_CUSTOMER_NUMBER:?Set the customer number from PACE Central Company Details}"
: "${PACE_CUSTOMER_NAME:?Set the exact company name from PACE Central Company Details}"
wraptool="${PACE_WRAPTOOL:-/Applications/PACEAntiPiracy/Eden/Fusion/Versions/6/bin/wraptool}"
[[ -x "$wraptool" ]] || { echo "Missing PACE SDK tool: $wraptool" >&2; exit 1; }
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_bundle="${MOTEFIELD_UNSIGNED_AAX_PATH:-${project_dir}/dist/macos/MoteField.aaxplugin}"
[[ -d "$source_bundle" ]] || { echo "Missing AAX bundle: $source_bundle" >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${source_bundle}/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid bundle version.' >&2; exit 1; }
lipo "${source_bundle}/Contents/MacOS/MoteField" -verify_arch arm64 x86_64
signing_dir="${project_dir}/dist/signing"
output_dir="${signing_dir}/MoteField-${version}-macOS-AAX-SIGNED-NOT-NOTARIZED"
[[ ! -e "$output_dir" ]] || { echo "Already exists: $output_dir" >&2; exit 1; }
mkdir -p "$signing_dir"
work_dir="$(mktemp -d "${signing_dir}/.aax-sign-XXXXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
target="${work_dir}/MoteField.aaxplugin"
# SDK 6 can use the current iLok License Manager session. Never put passwords here.
# The physical iLok must already be certified for this publisher.
"$wraptool" sign --customernumber "$PACE_CUSTOMER_NUMBER" \
  --customername "$PACE_CUSTOMER_NAME" --productname MoteField \
  --signid "$DEVELOPER_ID_APPLICATION" --dsigharden \
  --in "$source_bundle" --out "$target"
"$wraptool" verify --in "$target"
codesign --verify --deep --strict "$target"
codesign -dvv "$target" 2> "${work_dir}/MoteField.aaxplugin.signature.txt"
grep -q 'Authority=Developer ID Application:' "${work_dir}/MoteField.aaxplugin.signature.txt"
grep -q 'runtime' "${work_dir}/MoteField.aaxplugin.signature.txt"
grep -q '^Timestamp=' "${work_dir}/MoteField.aaxplugin.signature.txt"
lipo "${target}/Contents/MacOS/MoteField" -verify_arch arm64 x86_64
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${target}/Contents/Info.plist")" == "$version" ]]
echo 'PACE and Developer ID signed. Installer notarization and retail Pro Tools QA remain required.' > "${work_dir}/STATUS.txt"
mv "$work_dir" "$output_dir"
echo "Signed AAX: ${output_dir}/MoteField.aaxplugin"
