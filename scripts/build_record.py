#!/usr/bin/env python3
"""Freeze build inputs, then bind completed local artifacts to that snapshot."""
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import subprocess
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SOURCE = load_module("sxh_source_metadata", ROOT / "scripts/source-metadata.py")
VERSION = load_module("sxh_version", ROOT / "ios/scripts/version.py")


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def command(*args):
    env = dict(os.environ)
    if Path("/Applications/Xcode.app/Contents/Developer").exists():
        env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    result = subprocess.run(args, capture_output=True, text=True, env=env)
    return result.stdout.strip() if result.returncode == 0 else "unavailable"


def source_tree_digest():
    """Detect source edits during a build, including changes within dirty files."""
    result = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard"], capture_output=True)
    if result.returncode:
        raise ValueError("Initialize the source Git repository before recording a build")
    digest = hashlib.sha256()
    for raw_name in sorted(set(result.stdout.split(b"\0")) - {b""}):
        path = ROOT / os.fsdecode(raw_name)
        if path.is_symlink():
            content = b"symlink\0" + os.fsencode(os.readlink(path))
        elif path.is_file():
            content = b"file\0" + path.read_bytes()
        else:
            content = b"missing-or-directory"
        digest.update(raw_name + b"\0" + str(len(content)).encode() + b"\0" + content)
    return digest.hexdigest()


def validate_metadata(record):
    if not isinstance(record, dict):
        raise ValueError("Invalid build record")
    if record.get("schema_version") != 1 or record.get("record_type") not in {"build-input", "build-output"}:
        raise ValueError("Unsupported build record")
    if record.get("module") not in {"server", "ios"} or record.get("build_channel") not in {"testing", "unsigned", "release-candidate"}:
        raise ValueError("Invalid build module or channel")
    source = record.get("source", {})
    if not isinstance(source, dict):
        raise ValueError("Invalid source metadata")
    commit = source.get("commit", "")
    if type(source.get("dirty")) is not bool or not isinstance(source.get("source_url"), str) or not isinstance(commit, str):
        raise ValueError("Invalid source metadata")
    if commit == "uncommitted":
        if source["dirty"] is not True:
            raise ValueError("Uncommitted source must remain a testing input")
    elif not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})(?:-dirty)?", commit):
        raise ValueError("Invalid source commit")
    elif commit.endswith("-dirty") != source["dirty"]:
        raise ValueError("Source commit and dirty state disagree")
    if record["build_channel"] == "release-candidate" and source["dirty"]:
        raise ValueError("Release candidates require clean committed source")
    version = record.get("version", {})
    if not isinstance(version, dict):
        raise ValueError("Invalid recorded version")
    if not re.fullmatch(r"\d{8}(?:[1-9]|0[1-9]|[1-9]\d)", str(version.get("version", ""))) or type(version.get("build")) is not int or version["build"] <= 0:
        raise ValueError("Invalid recorded release version or build")
    if not isinstance(version.get("marketing"), str) or not isinstance(record.get("environment"), dict):
        raise ValueError("Missing build-time version or environment")
    if not re.fullmatch(r"[0-9a-f]{64}", str(record.get("source_tree_sha256", ""))) or not isinstance(record.get("build_started_at"), str):
        raise ValueError("Missing build-start snapshot")
    if record["record_type"] == "build-output" and not isinstance(record.get("build_completed_at"), str):
        raise ValueError("Missing build completion time")


def capture(module, channel, source, version):
    if source != SOURCE.metadata() or version != VERSION.read():
        raise ValueError("Source/version changed before the build started")
    environment = {"go": command("go", "version")} if module == "server" else {
        "xcode": command("xcodebuild", "-version"),
        "ios_sdk": command("xcrun", "--sdk", "iphoneos", "--show-sdk-version"),
    }
    record = {"schema_version": 1, "record_type": "build-input", "module": module,
              "build_channel": channel, "build_started_at": now(), "version": version,
              "source": source, "source_tree_sha256": source_tree_digest(), "environment": environment}
    validate_metadata(record)
    return record


def artifact_identity(path, record_dir):
    path = Path(path).resolve()
    if not path.is_file():
        raise ValueError("Build artifact must be an existing file")
    try:
        relative = path.relative_to(Path(record_dir).resolve()).as_posix()
    except ValueError:
        raise ValueError("Build artifact must be inside its record directory") from None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return {"path": relative, "name": path.name, "sha256": digest.hexdigest(), "bytes": path.stat().st_size}


def finish(inputs, artifacts, record_dir):
    validate_metadata(inputs)
    if inputs["record_type"] != "build-input":
        raise ValueError("Expected the build-start snapshot")
    if inputs["source"] != SOURCE.metadata() or inputs["version"] != VERSION.read() or inputs["source_tree_sha256"] != source_tree_digest():
        raise ValueError("Source/version changed during the build; rebuild before recording artifacts")
    entries = [artifact_identity(path, record_dir) for path in artifacts]
    if len({entry["path"] for entry in entries}) != len(entries):
        raise ValueError("Duplicate build artifact")
    return {**inputs, "record_type": "build-output", "build_completed_at": now(), "artifacts": entries}


def verified_artifact(record_path, artifact):
    record_path = Path(record_path)
    record = json.loads(record_path.read_text())
    validate_metadata(record)
    if record["record_type"] != "build-output":
        raise ValueError("Artifact has no completed build record")
    expected = artifact_identity(artifact, record_path.parent)
    matches = []
    entries = record.get("artifacts")
    if not isinstance(entries, list):
        raise ValueError("Missing recorded artifacts")
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("Invalid recorded artifact")
        relative = PurePosixPath(entry.get("path", ""))
        if relative.is_absolute() or ".." in relative.parts or not relative.parts:
            raise ValueError("Invalid artifact path in build record")
        if entry.get("path") == expected["path"]:
            matches.append(entry)
    if len(matches) != 1 or matches[0] != expected:
        raise ValueError("Artifact filename/path, size or SHA-256 does not match its build record")
    return record, expected


def write_record(path, record):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    start = actions.add_parser("capture")
    start.add_argument("--module", choices=["server", "ios"], required=True)
    start.add_argument("--channel", choices=["testing", "unsigned", "release-candidate"], required=True)
    start.add_argument("--source-json", required=True)
    start.add_argument("--version-json", required=True)
    start.add_argument("--output", type=Path, required=True)
    end = actions.add_parser("finish")
    end.add_argument("--input", type=Path, required=True)
    end.add_argument("--artifact", type=Path, action="append", required=True)
    end.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == "capture":
            record = capture(args.module, args.channel, json.loads(args.source_json), json.loads(args.version_json))
        else:
            record = finish(json.loads(args.input.read_text()), args.artifact, args.output.parent)
        write_record(args.output, record)
    except (ValueError, OSError, KeyError, TypeError) as exc:
        parser.error(str(exc))
    print("Build record saved: " + str(args.output))
