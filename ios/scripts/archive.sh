#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mode=unsigned
configuration=Release
channel=release
signing_settings=(CODE_SIGNING_ALLOWED=NO)
provisioning_options=()
metadata_flags=()
if [[ $# -gt 1 ]]; then
  print -u2 "Usage: scripts/archive.sh [--signed | --testing]"
  exit 2
elif [[ ${1:-} == --signed ]]; then
  mode=signed
  : "${SXH_DEVELOPMENT_TEAM:?Set SXH_DEVELOPMENT_TEAM explicitly for a signed archive.}"
  signing_settings=(CODE_SIGNING_ALLOWED=YES "DEVELOPMENT_TEAM=$SXH_DEVELOPMENT_TEAM")
  metadata_flags=(--require-clean)
elif [[ ${1:-} == --testing ]]; then
  mode=testing
  configuration=Debug
  channel=testing
  : "${SXH_DEVELOPMENT_TEAM:?Set SXH_DEVELOPMENT_TEAM explicitly for a local testing IPA.}"
  signing_settings=(CODE_SIGNING_ALLOWED=YES "DEVELOPMENT_TEAM=$SXH_DEVELOPMENT_TEAM")
elif [[ $# -gt 0 ]]; then
  print -u2 "Usage: scripts/archive.sh [--signed | --testing]"
  exit 2
fi
if [[ ${SXH_ALLOW_PROVISIONING_UPDATES:-0} == 1 ]]; then
  if [[ $mode == unsigned ]]; then
    print -u2 "Provisioning updates require --signed or --testing."
    exit 2
  fi
  provisioning_options=(-allowProvisioningUpdates)
elif [[ ${SXH_ALLOW_PROVISIONING_UPDATES:-0} != 0 ]]; then
  print -u2 "SXH_ALLOW_PROVISIONING_UPDATES must be 0 or 1."
  exit 2
fi
source scripts/source-settings.sh
version_metadata=$(python3 scripts/version.py)
release=$(print -r -- "$version_metadata" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
if [[ $mode == testing ]]; then
  out="${SXH_BUILD_OUTPUT:-.build/testing-$release}"
else
  out="${SXH_BUILD_OUTPUT:-.build/release-$release-$mode}"
fi
if test -e "$out/Suixinghao.xcarchive"; then
  print -u2 "Archive already exists: $out. Keep release artifacts immutable."
  exit 1
fi
mkdir -p "$out"
record_channel=unsigned
if [[ $mode == signed ]]; then
  record_channel=release-candidate
elif [[ $mode == testing ]]; then
  record_channel=testing
fi
python3 ../scripts/build_record.py capture --module ios --channel "$record_channel" --source-json "$source_metadata" --version-json "$version_metadata" --output "$out/build-input.json"
# Existing local assets by default. Provisioning requests require explicit opt-in.
if ! xcodebuild "${provisioning_options[@]}" -project Suixinghao.xcodeproj -scheme Suixinghao -configuration "$configuration" -destination 'generic/platform=iOS' -archivePath "$out/Suixinghao.xcarchive" -derivedDataPath "$out/DerivedData" "${signing_settings[@]}" "SXH_BUILD_CHANNEL=$channel" "${source_settings[@]}" archive > "$out/archive.log" 2>&1; then
  print -u2 "Archive failed. Review local log: $out/archive.log"
  exit 1
fi
if [[ $mode != unsigned ]]; then
  codesign --verify --deep --strict "$out/Suixinghao.xcarchive/Products/Applications/Suixinghao.app"
fi
if [[ $mode != unsigned ]]; then
  export_method=app-store-connect
  if [[ $mode == testing ]]; then
    export_method=debugging
  fi
  EXPORT_TEAM_FOR_SXH="$SXH_DEVELOPMENT_TEAM" EXPORT_METHOD_FOR_SXH="$export_method" EXPORT_PATH_FOR_SXH="$out/ExportOptions.plist" python3 - <<'PY'
import os
import plistlib
from pathlib import Path
Path(os.environ['EXPORT_PATH_FOR_SXH']).write_bytes(plistlib.dumps({
    'destination': 'export', 'method': os.environ['EXPORT_METHOD_FOR_SXH'], 'signingStyle': 'automatic',
    'teamID': os.environ['EXPORT_TEAM_FOR_SXH'], 'stripSwiftSymbols': True,
    'thinning': '<none>', 'manageAppVersionAndBuildNumber': False, 'uploadSymbols': False,
}))
PY
  if ! xcodebuild "${provisioning_options[@]}" -exportArchive -archivePath "$out/Suixinghao.xcarchive" -exportPath "$out/ipa" -exportOptionsPlist "$out/ExportOptions.plist" > "$out/export.log" 2>&1; then
    print -u2 "Local IPA export failed ($mode). Review local log: $out/export.log"
    exit 1
  fi
  python3 ../scripts/build_record.py finish --input "$out/build-input.json" --artifact "$out/ipa/Suixinghao.ipa" --output "$out/source.json"
  print "Local IPA ready ($mode): $out/ipa/Suixinghao.ipa"
else
  python3 ../scripts/build_record.py finish --input "$out/build-input.json" --artifact "$out/Suixinghao.xcarchive/Products/Applications/Suixinghao.app/Suixinghao" --output "$out/source.json"
  print "Release archive ready ($mode): $out"
fi
