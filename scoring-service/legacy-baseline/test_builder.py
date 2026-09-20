import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).with_name("build.py")
spec = importlib.util.spec_from_file_location("baseline_builder", MODULE_PATH)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BaselineBuilderTests(unittest.TestCase):
    def test_wrong_checkout_is_rejected_before_context_creation(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "new-context"
            with mock.patch.object(builder.subprocess, "check_output", return_value="0" * 40):
                with self.assertRaisesRegex(ValueError, "Expected exact baseline"):
                    builder.prepare(Path(scratch), output, Path(scratch) / "unused.patch")
            self.assertFalse(output.exists())

    def test_existing_context_is_preserved(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "existing"
            output.mkdir()
            marker = output / "preserve.txt"
            marker.write_text("existing work")
            with mock.patch.object(builder.subprocess, "check_output", return_value=builder.BASELINE):
                with self.assertRaisesRegex(ValueError, "new directory"):
                    builder.prepare(Path(scratch), output, Path(scratch) / "unused.patch")
            self.assertEqual("existing work", marker.read_text())

    def test_numerical_patch_is_rejected_before_context_creation(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "new-context"
            numerical_path = builder.PREFIX + "main/kotlin/com/frwhoop/scoring/scoring/DayScorer.kt"
            with mock.patch.object(builder.subprocess, "check_output", side_effect=[builder.BASELINE, ("1\t1\t" + numerical_path + "\0").encode()]):
                with self.assertRaisesRegex(ValueError, "outside the transport allowlist"):
                    builder.prepare(Path(scratch), output, Path(scratch) / "unused.patch")
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
