"""Build and verify an offline, hash-locked Linux CPU model bundle; never issue activation approval."""
import argparse
from email.parser import BytesParser
from hashlib import sha256
import json
from pathlib import Path
import re
import shutil
from zipfile import ZipFile

from .contracts import Abstain, canonical_hash, implementation_hash, verify_asset


def digest(path):
    with path.open("rb") as stream:
        value = sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def normalized(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def wheel_inventory(directory, pins):
    """No arbitrary wheel may enter the bundle; pip enforces ABI and dependency compatibility later."""
    found = {}
    for path in sorted(Path(directory).iterdir()):
        if not path.is_file() or path.is_symlink() or path.suffix != ".whl":
            raise Abstain("bundle_unexpected_wheelhouse_entry")
        if path.stat().st_size > 1024 * 1024 * 1024:
            raise Abstain("bundle_wheel_size_limit")
        with ZipFile(path) as archive:
            metadata = [entry for entry in archive.infolist() if entry.filename.count("/") == 1 and
                        entry.filename.endswith(".dist-info/METADATA")]
            if len(metadata) != 1 or metadata[0].file_size > 1024 * 1024:
                raise Abstain("bundle_wheel_metadata_invalid")
            values = BytesParser().parsebytes(archive.read(metadata[0]))
        name, version = normalized(values.get("Name", "")), values.get("Version")
        if name in found or pins.get(name) != version:
            raise Abstain("bundle_wheel_version_or_identity_mismatch")
        platform = path.stem.rsplit("-", 1)[-1]
        if platform != "any" and not all(tag.endswith("_x86_64") and "linux" in tag for tag in platform.split(".")):
            raise Abstain("bundle_wheel_platform_mismatch")
        found[name] = {"version": version, "filename": path.name, "sha256": digest(path)}
    if set(found) != set(pins):
        raise Abstain("bundle_wheels_missing")
    return found


def file_inventory(root):
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise Abstain("bundle_symlink_forbidden")
        if path.is_file() and path != root / "bundle-manifest.json":
            result[str(path.relative_to(root))] = digest(path)
    return result


def verify(root):
    root = Path(root)
    manifest = json.loads((root / "bundle-manifest.json").read_text())
    if manifest.get("schema_version") != 1 or manifest.get("canonical_outputs_allowed") is not False:
        raise Abstain("bundle_manifest_invalid")
    if manifest.get("manifest_sha256") != canonical_hash({k: v for k, v in manifest.items() if k != "manifest_sha256"}):
        raise Abstain("bundle_manifest_digest_mismatch")
    if file_inventory(root) != manifest.get("files"):
        raise Abstain("bundle_file_inventory_mismatch")
    return manifest


def build(source, checkpoint_root, wheelhouse, output):
    source, output = Path(source), Path(output)
    package = Path(__file__).resolve().parent
    lock = json.loads((package / "upstream-lock.json").read_text())["models"]["wav2sleep-cardiorespiratory"]
    upstream = source / "src" / "wav2sleep"
    inventory = {str(p.relative_to(upstream)): digest(p) for p in sorted(upstream.rglob("*.py"))}
    if canonical_hash(inventory) != lock["package_tree_sha256"]:
        raise Abstain("bundle_upstream_source_mismatch")
    # Preserve and bind the upstream rights notice; no self-issued production license approval.
    license_path = source / "LICENSE"
    if not license_path.is_file() or license_path.is_symlink():
        raise Abstain("bundle_license_notice_missing")
    assets = {filename: verify_asset({"path": filename, "sha256": lock[key]}, checkpoint_root) for filename, key in
              (("state_dict.pth", "checkpoint_sha256"), ("config.yaml", "config_sha256"))}
    pins_path = package.parent / "requirements-wav2sleep-linux-amd64.lock"
    pins = {}
    for line in pins_path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        name, version = line.split("==")
        if normalized(name) in pins:
            raise Abstain("bundle_duplicate_version_pin")
        pins[normalized(name)] = version
    wheels = wheel_inventory(wheelhouse, pins)
    output.mkdir(parents=False, exist_ok=False)
    (output / "wheelhouse").mkdir(); (output / "assets").mkdir(); (output / "notices").mkdir()
    shutil.copytree(upstream, output / "upstream" / "src" / "wav2sleep", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copytree(package, output / "inference" / "physiology_inference", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copyfile(license_path, output / "notices" / "wav2sleep-LICENSE")
    shutil.copyfile(pins_path, output / "version-pins.lock")
    for filename, path in assets.items():
        shutil.copyfile(path, output / "assets" / filename)
    for wheel in wheels.values():
        shutil.copyfile(Path(wheelhouse) / wheel["filename"], output / "wheelhouse" / wheel["filename"])
    with (output / "requirements.lock").open("x") as stream:
        for name, wheel in sorted(wheels.items()):
            stream.write(f'{name}=={wheel["version"]} --hash=sha256:{wheel["sha256"]}\n')
    manifest = {"schema_version": 1, "model_id": "wav2sleep-cardiorespiratory", "target": "cp311-linux-x86_64-cpu",
        "python_base": "python:3.11-slim-bookworm@sha256:4b4c524dc3dce996864e030c7bd9c6b0e517597189fee48f48e05b499442444b",
        "checkpoint_sha256": lock["checkpoint_sha256"], "upstream_revision": lock["code_revision"],
        "implementation_sha256": implementation_hash(), "canonical_outputs_allowed": False,
        "activation_qualified": False, "files": file_inventory(output)}
    manifest["manifest_sha256"] = canonical_hash(manifest)
    with (output / "bundle-manifest.json").open("x") as stream:
        json.dump(manifest, stream, sort_keys=True, indent=2); stream.write("\n")
    return verify(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    verify_parser = commands.add_parser("verify"); verify_parser.add_argument("--root", required=True)
    build_parser = commands.add_parser("build")
    for name in ("source", "checkpoint-root", "wheelhouse", "output"):
        build_parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    manifest = verify(args.root) if args.command == "verify" else build(args.source, args.checkpoint_root, args.wheelhouse, args.output)
    print(json.dumps({"manifest_sha256": manifest["manifest_sha256"], "canonical_outputs_allowed": False}, sort_keys=True))


if __name__ == "__main__":
    main()
