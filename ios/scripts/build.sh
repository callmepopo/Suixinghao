#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
configuration=Debug
metadata_flags=()
if [[ $# -gt 1 ]]; then
  print -u2 "Usage: scripts/build.sh [--release]"
  exit 2
elif [[ ${1:-} == --release ]]; then
  configuration=Release
elif [[ $# -gt 0 ]]; then
  print -u2 "Usage: scripts/build.sh [--release]"
  exit 2
fi
source scripts/source-settings.sh
xcodebuild -project Suixinghao.xcodeproj -scheme Suixinghao -configuration "$configuration" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO SXH_BUILD_CHANNEL=simulator "${source_settings[@]}" build
