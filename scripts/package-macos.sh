#!/usr/bin/env bash
set -euo pipefail

# Release mode deliberately requires both signing identities and notarization.
mode="${1:---release}"
include_aax="${2:-}"
if [[ ( "$mode" != --release && "$mode" != --unsigned ) || ( -n "$include_aax" && "$include_aax" != --include-aax ) ]]; then
  echo "Usage: bash scripts/package-macos.sh [--release|--unsigned] [--include-aax]" >&2
  exit 2
fi
[[ "$(uname -s)" == Darwin ]] || { echo "Requires macOS." >&2; exit 1; }
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${project_dir}/dist/macos"
output_dir="${project_dir}/dist/installers"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${source_dir}/MoteField.vst3/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid bundle version." >&2; exit 1; }
if [[ "$mode" == --release ]]; then
  : "${DEVELOPER_ID_APPLICATION:?Set your Developer ID Application identity}"
  : "${DEVELOPER_ID_INSTALLER:?Set your Developer ID Installer identity}"
  : "${NOTARY_PROFILE:?Set the name of your notarytool keychain profile}"
fi
mkdir -p "$output_dir"
work_dir="$(mktemp -d "${output_dir}/.macos-package-XXXXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
payloads="${work_dir}/payloads"
components=(au vst3)
for format in vst3 component; do
  bundle="MoteField.${format}"
  destination=VST3
  component=vst3
  if [[ "$format" == component ]]; then
    destination=Components
    component=au
  fi
  original="${source_dir}/${bundle}"
  [[ -d "$original" ]] || { echo "Missing ${original}; run build-macos.sh first." >&2; exit 1; }
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${original}/Contents/Info.plist")"
  [[ "$bundle_version" == "$version" ]] || { echo "Bundle versions differ." >&2; exit 1; }
  lipo "${original}/Contents/MacOS/MoteField" -verify_arch arm64 x86_64
  target="${payloads}/${component}/Library/Audio/Plug-Ins/${destination}/${bundle}"
  mkdir -p "$(dirname "$target")"
  ditto "$original" "$target"
  if [[ "$mode" == --release ]]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$target"
  else
    codesign --force --sign - "$target"
  fi
  codesign --verify --deep --strict "$target"
done

if [[ "$include_aax" == --include-aax ]]; then
  components+=(aax)
  original="${MOTEFIELD_SIGNED_AAX_PATH:-${source_dir}/MoteField.aaxplugin}"
  [[ -d "$original" ]] || { echo "Missing AAX bundle: $original" >&2; exit 1; }
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${original}/Contents/Info.plist")"
  [[ "$bundle_version" == "$version" ]] || { echo "AAX version differs." >&2; exit 1; }
  lipo "${original}/Contents/MacOS/MoteField" -verify_arch arm64 x86_64
  target="${payloads}/aax/Library/Application Support/Avid/Audio/Plug-Ins/MoteField.aaxplugin"
  mkdir -p "$(dirname "$target")"
  ditto "$original" "$target"
  if [[ "$mode" == --release ]]; then
    # Eden covers the whole bundle. Never re-sign/modify it with codesign here.
    : "${MOTEFIELD_SIGNED_AAX_PATH:?Set the path of the final PACE-signed AAX bundle}"
    "${PACE_WRAPTOOL:-wraptool}" verify --in "$target"
    codesign --verify --deep --strict "$target"
    # Capture all output: grep -q can close the pipe early and make codesign
    # fail with SIGPIPE under pipefail even when the expected signer is present.
    signature_details="$(codesign -dvv "$target" 2>&1)"
    [[ "$signature_details" == *'Authority=Developer ID Application:'* ]] || {
      echo "AAX must also carry a Developer ID Application signature." >&2; exit 1;
    }
  fi
fi

# Keep notices in their own required component so every format selection includes them.
python3 "${project_dir}/scripts/collect-notices.py" \
  --juce-dir "${project_dir}/build-macos/_deps/juce-src" \
  --output "${payloads}/notices/Library/Application Support/Rango Labs/MoteField/Notices"
for component in "${components[@]}" notices; do
  payload="${payloads}/${component}"
  # Each format has a stable receipt and payload. Deselection never removes old copies.
  # Disable relocation so a previous per-user copy cannot redirect installation.
  pkgbuild --analyze --root "$payload" "${work_dir}/components.plist"
python3 - "${work_dir}/components.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    components = plistlib.load(f)
for component in components:
    component['BundleIsRelocatable'] = False
    component['BundleOverwriteAction'] = 'upgrade'
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(components, f)
PY
  pkgbuild --root "$payload" --component-plist "${work_dir}/components.plist" \
    --identifier "com.rangolabs.motefield.pkg.${component}" --version "$version" \
    --install-location / --ownership recommended "${work_dir}/${component}.pkg"
done
python3 - "${work_dir}/distribution.xml" "$version" "${components[@]}" <<'PY'
import sys
import xml.etree.ElementTree as ET

output, version, *formats = sys.argv[1:]
labels = {
    'au': ('Audio Unit (AU)', 'For Logic Pro, GarageBand and other Audio Unit hosts.'),
    'vst3': ('VST3', 'For Ableton Live, Cubase, REAPER, Reason and other VST3 hosts.'),
    'aax': ('AAX Native (Pro Tools)', 'For Pro Tools. Install this format to use MoteField in Pro Tools.'),
}
root = ET.Element('installer-gui-script', minSpecVersion='2')
ET.SubElement(root, 'title').text = 'MoteField — Rango Labs'
ET.SubElement(root, 'welcome', file='welcome.html', **{'mime-type': 'text/html'})
ET.SubElement(root, 'conclusion', file='conclusion.html', **{'mime-type': 'text/html'})
ET.SubElement(root, 'options', customize='always', hostArchitectures='arm64,x86_64')
ET.SubElement(root, 'domains', enable_localSystem='true', enable_currentUserHome='false', enable_anywhere='false')
check = ET.SubElement(root, 'volume-check', script='true')
ET.SubElement(ET.SubElement(check, 'allowed-os-versions'), 'os-version', min='11.0')
outline = ET.SubElement(root, 'choices-outline')
for component in [*formats, 'notices']:
    ET.SubElement(outline, 'line', choice=component)
    if component == 'notices':
        # Do not offer an empty, notices-only install when all formats are unchecked.
        choice = ET.SubElement(root, 'choice', id=component, title='License notices',
            description='Third-party license notices required for the selected plug-ins.',
            visible='false', enabled='false',
            selected=' || '.join(f"choices['{f}'].selected" for f in formats))
    else:
        title, description = labels[component]
        choice = ET.SubElement(root, 'choice', id=component, title=title,
            description=description + ' Unchecking skips installation; existing copies are kept.',
            start_selected='true')
    package_id = f'com.rangolabs.motefield.pkg.{component}'
    ET.SubElement(choice, 'pkg-ref', id=package_id)
    ET.SubElement(root, 'pkg-ref', id=package_id, version=version,
        onConclusion='None').text = f'{component}.pkg'
ET.ElementTree(root).write(output, encoding='utf-8', xml_declaration=True)
PY
suffix=""
sign_args=()
if [[ "$mode" == --release ]]; then
  sign_args=(--sign "$DEVELOPER_ID_INSTALLER" --timestamp)
else
  suffix="-UNSIGNED"
fi
# Preserve the previously shared, nonselectable 0.3.13 candidates.
package="${output_dir}/MoteField-${version}-macOS-universal${include_aax:+-AAX}-Selectable${suffix}.pkg"
resources="${project_dir}/packaging/macos"
[[ -z "$include_aax" ]] || resources="${resources}/aax"
productbuild --distribution "${work_dir}/distribution.xml" --package-path "$work_dir" \
  --resources "$resources" ${sign_args[@]+"${sign_args[@]}"} "${work_dir}/installer.pkg"
if [[ "$mode" == --release ]]; then
  notary_result="${output_dir}/MoteField-${version}${include_aax:+-AAX}-Selectable-notary.json"
  xcrun notarytool submit "${work_dir}/installer.pkg" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$notary_result"
  python3 - "$notary_result" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    result = json.load(f)
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization failed; inspect the notary JSON and fetch the submission log.')
PY
  xcrun stapler staple "${work_dir}/installer.pkg"
  xcrun stapler validate "${work_dir}/installer.pkg"
  pkgutil --check-signature "${work_dir}/installer.pkg"
  spctl --assess --type install --verbose "${work_dir}/installer.pkg"
fi
mv "${work_dir}/installer.pkg" "$package"
shasum -a 256 "$package" > "${package}.sha256"
echo "Created ${package}"
[[ "$mode" != --unsigned ]] || echo "Development installer only: unsigned and not notarized."
