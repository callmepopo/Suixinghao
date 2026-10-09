#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
require_clean=0
if test "$#" -gt 1; then
  echo 'Usage: build.sh [--require-clean]' >&2
  exit 2
fi
case "${1:-}" in
  "") ;;
  --require-clean) require_clean=1 ;;
  *) echo 'Usage: build.sh [--require-clean]' >&2; exit 2 ;;
esac
version_metadata=$(python3 ../ios/scripts/version.py)
version=$(printf '%s' "$version_metadata" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
channel=testing
if test "$require_clean" = 1; then
  metadata=$(python3 ../scripts/source-metadata.py --require-clean)
  channel=release-candidate
else
  metadata=$(python3 ../scripts/source-metadata.py)
fi
commit=$(printf '%s' "$metadata" | python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"])')
output="$PWD/.build/$version"
mkdir -p "$output"
python3 ../scripts/build_record.py capture --module server --channel "$channel" --source-json "$metadata" --version-json "$version_metadata" --output "$output/build-input.json"
GOCACHE="$PWD/.build/go-cache" GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-X main.releaseVersion=$version -X main.sourceCommit=$commit" -o "$output/voice-web" .
python3 ../scripts/build_record.py finish --input "$output/build-input.json" --artifact "$output/voice-web" --output "$output/source.json"
echo "Server build ready: $version ($commit)"
