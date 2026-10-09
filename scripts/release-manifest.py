#!/usr/bin/env python3
"""Record source and artifact identity; this is evidence, not proof of App Store bytes."""
import argparse
import datetime as dt
import json
from pathlib import Path
from build_record import verified_artifact


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--source-record", type=Path, required=True, help="The source.json produced alongside this build")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--testing", action="store_true", help="Allow dirty/uncommitted testing source; never mark this manifest as released")
    args = parser.parse_args()
    if not args.artifact.is_file():
        parser.error("Artifact must be a file, for example an exported IPA or server binary")
    try:
        record, artifact = verified_artifact(args.source_record, args.artifact)
    except (ValueError, OSError, KeyError, TypeError) as exc:
        parser.error(str(exc))
    if not args.testing and record["build_channel"] != "release-candidate":
        parser.error("A formal manifest requires a clean release-candidate build record; use --testing for local outputs")
    version = record["version"]
    manifest = {
        "schema_version": 2,
        "channel": "testing" if args.testing else "release-candidate",
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "release_version": version["version"],
        "app_version": version["marketing"],
        "app_build": version["build"],
        "source": {key: record["source"][key] for key in ["commit", "source_url", "dirty"]},
        "artifact": {key: artifact[key] for key in ["name", "sha256", "bytes"]},
        "environment": {key: value for key, value in record["environment"].items() if key in {"go", "xcode", "ios_sdk"}},
        "build": {"module": record["module"], "channel": record["build_channel"],
                  "started_at": record["build_started_at"], "completed_at": record["build_completed_at"],
                  "source_tree_sha256": record["source_tree_sha256"]},
        "app_store_submission": "not_submitted",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # A manifest contains only public metadata; no path, Team ID, token, or profile.
    args.output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print("Manifest written: " + str(args.output))
