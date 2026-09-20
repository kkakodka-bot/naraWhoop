import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-scoring-imports.py"
spec = importlib.util.spec_from_file_location("scoring_imports", SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class ScoringImportsTest(unittest.TestCase):
    def test_pure_shared_data_is_allowed_but_platform_and_room_are_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "scoring-service/service/src/main/kotlin/Fixture.kt"
            source.parent.mkdir(parents=True)
            source.write_text("import com.noop.data.HrSample\nimport com.noop.data.RrInterval\n")
            self.assertEqual(guard.violations(root), [])
            for name in ("android.content.Context", "androidx.room.Room", "com.noop.ingest.Writer",
                         "com.noop.data.WhoopRepository", "com.noop.data.WhoopDao",
                         "com.noop.data.DeviceRegistryDao"):
                with self.subTest(name=name):
                    source.write_text("import " + name + "\n")
                    self.assertEqual(len(guard.violations(root)), 1)

    def test_missing_source_is_not_a_passing_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                guard.violations(Path(directory))
