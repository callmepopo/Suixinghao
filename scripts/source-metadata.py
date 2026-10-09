#!/usr/bin/env python3
"""Describe the actual checked-out source without inventing a release origin."""
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    result = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def metadata():
    commit = git("rev-parse", "--verify", "HEAD")
    if not commit or not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        return {"commit": "uncommitted", "source_url": "", "dirty": True}
    status = git("status", "--porcelain", "--untracked-files=normal")
    dirty = status is None or bool(status)
    remote = git("remote", "get-url", "origin") or ""
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?", remote)
    url = ""
    if match and not dirty:
        url = "https://github.com/" + match.group(1) + "/tree/" + commit
    return {"commit": commit + ("-dirty" if dirty else ""), "source_url": url, "dirty": dirty}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-clean", action="store_true", help="Require a committed, clean source tree for a release")
    args = parser.parse_args()
    info = metadata()
    if args.require_clean and info["dirty"]:
        parser.error("Release source must be committed and clean; local builds remain available without --require-clean")
    print(json.dumps(info))
