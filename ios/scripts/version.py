#!/usr/bin/env python3
"""Read/advance the sole release version; do not infer versions from logs."""
import argparse
import datetime as dt
import json
import re
from pathlib import Path
from zoneinfo import ZoneInfo

CONFIG = Path(__file__).resolve().parents[2] / "Version.xcconfig"

def read():
    source = CONFIG.read_text()
    def value(key):
        match = re.search(rf"^{key}\s*=\s*([\d.]+)\s*$", source, re.M)
        if not match:
            raise ValueError(f"Missing version setting: {key}")
        return match.group(1)
    version = value("SXH_RELEASE_VERSION")
    # Read historical nine-digit versions without changing their identity.
    if not re.fullmatch(r"\d{8}(?:[1-9]|0[1-9]|[1-9]\d)", version):
        raise ValueError("Release version must be YYYYMMDD plus 01..99 (legacy 1..9 accepted)")
    dt.datetime.strptime(version[:8], "%Y%m%d")
    build = int(value("CURRENT_PROJECT_VERSION"))
    if not 1 <= build <= 9999:
        raise ValueError("Apple build counter must be 1..9999")
    return dict(version=version, build=build, marketing=value("MARKETING_VERSION"))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--next", action="store_true", help="Reserve the next release before editing")
    args = parser.parse_args()
    metadata = read()
    if args.next:
        if metadata["build"] >= 9999:
            raise ValueError("Apple build counter limit reached; configure a new valid counter format first")
        today = dt.datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y%m%d")
        if today < metadata["version"][:8]:
            raise ValueError("Clock precedes current release date")
        sequence = int(metadata["version"][8:]) + 1 if today == metadata["version"][:8] else 1
        if sequence > 99:
            raise ValueError("99 releases already reserved today; wait until tomorrow")
        source = CONFIG.read_text()
        source = re.sub(r"^(SXH_RELEASE_VERSION\s*=).*", rf"\g<1> {today}{sequence:02d}", source, flags=re.M)
        source = re.sub(r"^(CURRENT_PROJECT_VERSION\s*=).*", rf"\g<1> {metadata['build'] + 1}", source, flags=re.M)
        CONFIG.write_text(source)
        metadata = read()
    print(json.dumps(metadata))
