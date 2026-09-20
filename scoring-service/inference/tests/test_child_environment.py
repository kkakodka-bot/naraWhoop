"""Disposable import caches are deployment mechanics, not physiological qualification."""
import os
from pathlib import Path
import stat
import unittest
from unittest.mock import patch

from physiology_inference.runtime import isolated_child_environment


class ChildEnvironmentTest(unittest.TestCase):
    def test_credentials_and_host_cache_paths_do_not_survive(self):
        with patch.dict(os.environ, {"DATABASE_URL": "private-db", "B2_KEY": "private-key",
                                    "NUMBA_CACHE_DIR": "/private-host-cache"}):
            with isolated_child_environment() as environment:
                for key in ("DATABASE_URL", "B2_KEY", "HOME", "USER", "LOGNAME"):
                    self.assertNotIn(key, environment)
                self.assertEqual(environment["HF_HUB_OFFLINE"], "1")
                self.assertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")
                caches = [Path(environment[key]) for key in ("NUMBA_CACHE_DIR", "XDG_CACHE_HOME", "MPLCONFIGDIR",
                                                            "TORCH_HOME", "TORCHINDUCTOR_CACHE_DIR", "HF_HOME")]
                self.assertEqual(len({path.parent for path in caches}), 1)
                for path in caches:
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
                    self.assertNotEqual(str(path), "/private-host-cache")
                    (path / "synthetic-cache").write_bytes(b"fixture")
            self.assertTrue(all(not path.exists() for path in caches))

    def test_jobs_have_separate_cache_roots_and_cleanup_after_failure(self):
        with isolated_child_environment() as first:
            first_path = Path(first["NUMBA_CACHE_DIR"])
            with self.assertRaisesRegex(RuntimeError, "fixture"):
                with isolated_child_environment() as second:
                    second_path = Path(second["NUMBA_CACHE_DIR"])
                    self.assertNotEqual(first_path.parent, second_path.parent)
                    raise RuntimeError("fixture")
            self.assertFalse(second_path.parent.exists())
            self.assertTrue(first_path.exists())
        self.assertFalse(first_path.parent.exists())


if __name__ == "__main__":
    unittest.main()
