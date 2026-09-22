#!/usr/bin/env python3
"""Import the reviewed upstream release subset; never fetch or execute archive code."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile

VERSION = "1.5.7"
COMMIT = "f8745da6ff1ad1e7bab384bd1f9d742439278e99"
ARCHIVE_SHA256 = "eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"
ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / "Packages/NoopPush/Sources/CNoopZstd/vendor/zstd"


def wanted(name):
    return name in {"LICENSE", "lib/zstd.h", "lib/zstd_errors.h"} or (
        name.startswith(("lib/common/", "lib/compress/", "lib/decompress/"))
        and Path(name).suffix in {".c", ".h"}
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if hashlib.sha256(args.archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise SystemExit("Pinned upstream archive digest mismatch")
    hashes = {}
    with tarfile.open(args.archive, "r:gz") as archive:
        for member in archive.getmembers():
            prefix = f"zstd-{VERSION}/"
            if not member.name.startswith(prefix):
                continue
            name = member.name[len(prefix):]
            if not wanted(name):
                continue
            if not member.isfile() or ".." in Path(name).parts or Path(name).is_absolute():
                raise SystemExit("Invalid upstream member")
            data = archive.extractfile(member).read()
            hashes[name] = hashlib.sha256(data).hexdigest()
            output = DESTINATION / name
            if args.check:
                if not output.is_file() or output.read_bytes() != data:
                    raise SystemExit(f"Vendor source differs: {name}")
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(data)
    manifest = {
        "version": VERSION, "commit": COMMIT, "archive_sha256": ARCHIVE_SHA256,
        "upstream": "https://github.com/facebook/zstd",
        "license": "BSD-3-Clause", "source_files_sha256": hashes,
    }
    encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    manifest_path = DESTINATION / "provenance.json"
    notice = ROOT / "Packages/NoopPush/Sources/NoopPush/Resources/Zstandard-LICENSE.txt"
    license_bytes = (DESTINATION / "LICENSE").read_bytes()
    if args.check:
        if manifest_path.read_bytes() != encoded or notice.read_bytes() != license_bytes:
            raise SystemExit("Vendor provenance or bundled license differs")
    else:
        manifest_path.write_bytes(encoded)
        notice.parent.mkdir(parents=True, exist_ok=True)
        notice.write_bytes(license_bytes)
    print(f"Verified {len(hashes)} unmodified files from zstd {VERSION}")


if __name__ == "__main__":
    main()
