#!/usr/bin/env python3
"""Guard handwritten service imports; Gradle verifies the extracted kernel dependency scope."""
from pathlib import Path
import re
import sys

FORBIDDEN = re.compile(
    r"^\s*import\s+(?:android\.|androidx\.|com\.noop\.ingest(?:\.|$)|"
    r"com\.noop\.data\.(?:WhoopRepository|WhoopDao|WhoopDatabase|DeviceRegistry|"
    r"DeviceRegistryDao|PairedDeviceRow|DeviceStatus|MetricSeriesRow)(?:\b|\.))"
)


def violations(root):
    source = root / "scoring-service/service/src"
    if not source.is_dir():
        raise ValueError("scoring service source tree missing")
    return [f"{path.relative_to(root)}:{number}" for path in source.rglob("*.kt")
            for number, line in enumerate(path.read_text().splitlines(), 1)
            if FORBIDDEN.search(line)]


if __name__ == "__main__":
    found = violations(Path(sys.argv[1]))
    for location in found:
        print(f"Forbidden platform/repository import: {location}", file=sys.stderr)
    sys.exit(bool(found))
