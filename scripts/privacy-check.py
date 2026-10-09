#!/usr/bin/env python3
"""Check public files or the complete Git index, printing paths but never secrets."""
import argparse
import fnmatch
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {".git", ".build", "__pycache__", "node_modules", ".gocache", ".gotmp"}
FORBIDDEN_DIRS = {"private", "legacy", "data", "logs", "recordings", "backups", "xcuserdata"}
FORBIDDEN_SUFFIXES = {".p8", ".p12", ".pfx", ".pem", ".key", ".mobileprovision", ".ipa", ".ko", ".txz", ".wav", ".s16le", ".db", ".apk"}
FORBIDDEN_NAMES = {"config.yaml", "hideck.yaml", "service.env", "apns.env", "app-keys.json", "voip-tokens.json", "sms-push-tokens.json", "sms-push-cursor.json", "recording.json", "relay-grants.json"}
PATTERNS = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\r?\n[A-Za-z0-9+/=]{16,}\r?\n"),
    "personal home path": re.compile(rb"/Users/[A-Za-z0-9_.-]+/"),
    "private IPv4": re.compile(rb"\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b"),
    "literal App Key": re.compile(rb"\bhdk_[0-9a-fA-F]{64}\b"),
    "literal relay key": re.compile(rb"\bsxr_[0-9a-fA-F]{64}\b"),
    "GitHub token": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
}


def git(*args):
    result = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True)
    if result.returncode:
        raise RuntimeError("Git index is unavailable; initialize the public repository first")
    return result.stdout


def files(staged):
    if staged:
        for raw in git("ls-files", "-z").split(b"\0"):
            if not raw:
                continue
            name = raw.decode("utf-8")
            mode = git("ls-files", "--stage", "--", name).split(b" ", 1)[0]
            if mode == b"120000":
                yield name, None
            else:
                yield name, git("show", ":" + name)
    else:
        for path in sorted(ROOT.rglob("*")):
            rel = path.relative_to(ROOT)
            if any(part in EXCLUDED for part in rel.parts):
                continue
            if path.is_symlink():
                yield rel.as_posix(), None
            elif path.is_file():
                yield rel.as_posix(), path.read_bytes()


def check(name, data):
    path = Path(name)
    if data is None:
        return "symlink requires manual review"
    if any(part in FORBIDDEN_DIRS or part.endswith((".xcarchive", ".dSYM")) for part in path.parts):
        return "private/runtime directory"
    if path.suffix.lower() in FORBIDDEN_SUFFIXES or path.suffix.lower().startswith(".sqlite"):
        return "private or generated artifact type"
    if path.name in FORBIDDEN_NAMES or path.name == ".env" or path.name.endswith(".env"):
        return "live configuration file"
    if path.suffix.lower() == ".png" and "/Assets.xcassets/" in name:
        return None
    if b"\0" in data:
        return "unexpected binary file"
    for reason, pattern in PATTERNS.items():
        if pattern.search(data):
            return reason
    if fnmatch.fnmatch(path.name, "*result.json") or path.name in {"pre-convert.txt", "post-convert.txt"}:
        return "field test or device dump"
    return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="Scan all Git index blobs, rather than working files")
    args = parser.parse_args()
    findings = []
    count = 0
    try:
        for name, data in files(args.staged):
            count += 1
            reason = check(name, data)
            if reason:
                findings.append((name, reason))
    except (RuntimeError, OSError, UnicodeError) as error:
        print("Privacy check could not complete: " + str(error), file=sys.stderr)
        sys.exit(2)
    for name, reason in findings:
        print(name + ": " + reason)
    print(f"Checked {count} public files; findings: {len(findings)}. Manual review is still required.")
    sys.exit(bool(findings))
