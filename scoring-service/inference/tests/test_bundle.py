import json
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

from physiology_inference.bundle import file_inventory, verify, wheel_inventory
from physiology_inference.contracts import Abstain, canonical_hash


class BundleTest(unittest.TestCase):
    def test_wheel_version_platform_and_omission_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "numpy-2.3.1-cp311-cp311-manylinux_2_28_x86_64.whl"
            with ZipFile(path, "w") as archive:
                archive.writestr("numpy-2.3.1.dist-info/METADATA", "Name: numpy\nVersion: 2.3.1\n")
                archive.writestr("numpy/vendor/something-1.dist-info/METADATA", "Name: something\nVersion: 1\n")
            self.assertEqual(wheel_inventory(directory, {"numpy": "2.3.1"})["numpy"]["version"], "2.3.1")
            with self.assertRaisesRegex(Abstain, "identity_mismatch"):
                wheel_inventory(directory, {"numpy": "2.3.2"})
            with self.assertRaisesRegex(Abstain, "wheels_missing"):
                wheel_inventory(directory, {"numpy": "2.3.1", "torch": "2.7.1+cpu"})
            path.rename(Path(directory) / "numpy-2.3.1-cp311-cp311-macosx_14_0_arm64.whl")
            with self.assertRaisesRegex(Abstain, "platform_mismatch"):
                wheel_inventory(directory, {"numpy": "2.3.1"})

    def test_every_bundle_file_is_bound_and_extra_files_reject(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "weights").write_bytes(b"synthetic-not-model")
            manifest = {"schema_version": 1, "canonical_outputs_allowed": False, "files": file_inventory(root)}
            manifest["manifest_sha256"] = canonical_hash(manifest)
            (root / "bundle-manifest.json").write_text(json.dumps(manifest))
            self.assertEqual(verify(root), manifest)
            (root / "extra").write_bytes(b"unbound")
            with self.assertRaisesRegex(Abstain, "file_inventory_mismatch"):
                verify(root)


if __name__ == "__main__":
    unittest.main()
