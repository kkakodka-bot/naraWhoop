#!/usr/bin/env python3
"""Inspect a signed development IPA without network access or installation."""

from __future__ import annotations

import json
from pathlib import Path, PurePosixPath
import plistlib
import stat
import subprocess
import sys
import tempfile
import zipfile


MAX_ENTRY_BYTES = 2 * 1024 * 1024 * 1024
MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024


def run(*argv: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(argv, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def safe_members(archive: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
    seen: set[str] = set()
    total = 0
    members = archive.infolist()
    if not members or len(members) > 100_000:
        raise ValueError("IPA member inventory is empty or excessive")
    for item in members:
        name = item.filename
        path = PurePosixPath(name)
        if (
            not name
            or "\\" in name
            or "\x00" in name
            or path.is_absolute()
            or any(part in ("", ".", "..") for part in path.parts)
            or name in seen
        ):
            raise ValueError(f"unsafe or duplicate IPA member: {name!r}")
        seen.add(name)
        if item.file_size < 0 or item.file_size > MAX_ENTRY_BYTES:
            raise ValueError(f"IPA member exceeds size bound: {name}")
        total += item.file_size
        if total > MAX_TOTAL_BYTES:
            raise ValueError("IPA expands beyond the reviewed bound")
        mode = (item.external_attr >> 16) & 0o170000
        if mode not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise ValueError(f"IPA contains a non-regular member: {name}")
    return members


def display_signature(bundle: Path) -> dict[str, object]:
    run("/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(bundle))
    display = run("/usr/bin/codesign", "--display", "--verbose=4", str(bundle)).stderr.decode(
        "utf-8", "strict"
    )
    fields: dict[str, str] = {}
    authorities: list[str] = []
    for line in display.splitlines():
        if line.startswith("Authority="):
            authorities.append(line.split("=", 1)[1])
        elif "=" in line:
            key, value = line.split("=", 1)
            if key in ("Identifier", "TeamIdentifier", "CDHash"):
                fields[key] = value
    if not all(fields.get(key) for key in ("Identifier", "TeamIdentifier", "CDHash")):
        raise ValueError(f"incomplete code-sign identity for {bundle.name}")
    entitlement_bytes = run(
        "/usr/bin/codesign", "--display", "--entitlements", ":-", str(bundle)
    ).stdout
    entitlements = plistlib.loads(entitlement_bytes) if entitlement_bytes else {}
    return {
        "identifier": fields["Identifier"],
        "teamIdentifier": fields["TeamIdentifier"],
        "cdhash": fields["CDHash"].lower(),
        "authorities": authorities,
        "entitlements": {
            "applicationGroups": sorted(
                entitlements.get("com.apple.security.application-groups", [])
            ),
            "healthKit": bool(entitlements.get("com.apple.developer.healthkit", False)),
            "getTaskAllow": bool(entitlements.get("get-task-allow", False)),
        },
    }


def profile(bundle: Path) -> dict[str, object]:
    filename = bundle / "embedded.mobileprovision"
    if not filename.is_file():
        raise ValueError(f"missing embedded provisioning profile: {bundle.name}")
    raw = run("/usr/bin/security", "cms", "-D", "-i", str(filename)).stdout
    value = plistlib.loads(raw)
    entitlements = value.get("Entitlements", {})
    expiration = value.get("ExpirationDate")
    if expiration is None:
        raise ValueError(f"profile has no expiration: {bundle.name}")
    return {
        "uuid": value.get("UUID"),
        "name": value.get("Name"),
        "teamIdentifier": (value.get("TeamIdentifier") or [None])[0],
        "applicationIdentifier": entitlements.get("application-identifier"),
        "applicationGroups": sorted(
            entitlements.get("com.apple.security.application-groups", [])
        ),
        "healthKit": bool(entitlements.get("com.apple.developer.healthkit", False)),
        "getTaskAllow": bool(entitlements.get("get-task-allow", False)),
        "deviceCount": len(value.get("ProvisionedDevices", [])),
        "expiration": expiration.isoformat(),
    }


def inspect(filename: Path) -> dict[str, object]:
    with zipfile.ZipFile(filename) as archive:
        members = safe_members(archive)
        info_names = sorted(
            item.filename
            for item in members
            if item.filename.startswith("Payload/")
            and (
                item.filename.endswith(".app/Info.plist")
                or item.filename.endswith(".appex/Info.plist")
            )
        )
        main = [
            name
            for name in info_names
            if len(PurePosixPath(name).parts) == 3 and name.endswith(".app/Info.plist")
        ]
        if len(main) != 1:
            raise ValueError("IPA must contain exactly one top-level application")
        plist_values = {
            name: plistlib.loads(archive.read(name))
            for name in info_names
        }
        with tempfile.TemporaryDirectory(prefix="frwhoop-ipa-inspect-") as temporary:
            root = Path(temporary)
            archive.extractall(root, members)
            main_bundle = root / str(PurePosixPath(main[0]).parent)
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(main_bundle))
            bundles = []
            for name in info_names:
                relative_bundle = str(PurePosixPath(name).parent)
                bundle = root / relative_bundle
                info = plist_values[name]
                bundles.append(
                    {
                        "path": relative_bundle,
                        "bundleIdentifier": info.get("CFBundleIdentifier"),
                        "version": info.get("CFBundleShortVersionString"),
                        "build": str(info.get("CFBundleVersion", "")),
                        "sourceRevision": info.get("NOOPSourceRevision"),
                        "finalHostedCompute": info.get("NOOPFinalHostedCompute"),
                        "signature": display_signature(bundle),
                        "profile": profile(bundle),
                    }
                )
            return {"bundles": bundles}


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: inspect_ipa.py IPA")
    filename = Path(sys.argv[1]).resolve()
    if not filename.is_file() or filename.is_symlink():
        raise SystemExit("IPA must be a regular file")
    print(json.dumps(inspect(filename), sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
