#!/bin/zsh
# Shared local provenance; source this from an iOS build script after cd to ios/.
source_metadata=$(python3 ../scripts/source-metadata.py "${metadata_flags[@]}")
source_commit=$(print -r -- "$source_metadata" | python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"])')
source_url=$(print -r -- "$source_metadata" | python3 -c 'import json,sys; print(json.load(sys.stdin)["source_url"])')
source_settings=("SXH_SOURCE_COMMIT=$source_commit" "SXH_SOURCE_URL=$source_url")
