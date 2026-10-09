#!/usr/bin/env python3
"""Read component versions; product bumps and Apple build counters are independent."""
import argparse
import datetime as dt
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "Version.xcconfig"

def valid_version(version):
    if re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version):
        return True
    if re.fullmatch(r"\d{8}(?:[1-9]|0[1-9]|[1-9]\d)", version):
        try:
            dt.datetime.strptime(version[:8], "%Y%m%d")
            return True
        except ValueError:
            pass
    return False

def config(module):
    if module not in {"ios", "server"}:
        raise ValueError("Unknown component")
    return CONFIG if module == "ios" else ROOT / "server/Version.xcconfig"

def read(module="ios"):
    source = config(module).read_text()
    def value(key):
        match = re.search(rf"^{key}\s*=\s*([\d.]+)\s*$", source, re.M)
        if not match:
            raise ValueError(f"Missing version setting: {key}")
        return match.group(1)
    version = value("SXH_RELEASE_VERSION")
    if not valid_version(version):
        raise ValueError("Invalid product or historical release version")
    build = int(value("CURRENT_PROJECT_VERSION"))
    if not 1 <= build <= 9999:
        raise ValueError("Build counter must be 1..9999")
    return dict(version=version, build=build, marketing=value("MARKETING_VERSION"))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--module", choices=["ios", "server"], default="ios")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--next", action="store_true", help="Advance this component's patch version and build")
    action.add_argument("--build-only", action="store_true", help="Reserve a new build of the same product version")
    args = parser.parse_args()
    metadata = read(args.module)
    if args.next or args.build_only:
        if metadata["build"] >= 9999:
            raise ValueError("Build counter limit reached")
        source = config(args.module).read_text()
        if args.next:
            if not re.fullmatch(r"\d+\.\d+\.\d+", metadata["version"]):
                raise ValueError("Migrate historical date versions explicitly before advancing")
            major, minor, patch = map(int, metadata["version"].split("."))
            version = f"{major}.{minor}.{patch+1}"
            for key in ["SXH_RELEASE_VERSION", "MARKETING_VERSION"]:
                source = re.sub(rf"^({key}\s*=).*", rf"\g<1> {version}", source, flags=re.M)
        source = re.sub(r"^(CURRENT_PROJECT_VERSION\s*=).*", rf"\g<1> {metadata['build'] + 1}", source, flags=re.M)
        config(args.module).write_text(source)
        metadata = read(args.module)
    print(json.dumps(metadata))
