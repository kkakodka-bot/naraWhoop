"""Environment/measurement plumbing only, not model rights or target-VPS qualification."""

import copy
from importlib.machinery import ModuleSpec
from importlib.metadata import PackagePath
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

from physiology_inference.contracts import Abstain, canonical_hash
from physiology_inference.environment import MODEL_DISTRIBUTIONS, capture, import_origins, verify
from physiology_inference.resource_benchmark import benchmark, within_tolerance


class EnvironmentTests(unittest.TestCase):
    def test_capture_never_qualifies_and_unreviewed_environment_is_rejected(self):
        manifest = capture("feature-sleep-learner")
        self.assertEqual(manifest["qualification_status"], "unqualified_observed_environment")
        with self.assertRaisesRegex(Abstain, "environment_review_required"):
            verify(manifest, "feature-sleep-learner", {})
        review = {"status": "reviewed_for_shadow", "identifier": "synthetic", "evidence": "functional fixture only"}
        with self.assertRaisesRegex(Abstain, "qualified_environment_manifest_required"):
            verify(manifest, "feature-sleep-learner", review)

    def test_qualified_fixture_binds_interpreter_and_installed_package_bytes(self):
        manifest = capture("feature-sleep-learner")
        manifest["qualification_status"] = "qualified_shadow_environment"
        self.assertIn("numpy", [package["name"] for package in manifest["packages"]])
        self.assertIn("numpy", [origin["module"] for origin in manifest["import_origins"]])
        review = {"status": "reviewed_for_shadow", "identifier": "synthetic", "evidence": "functional fixture only"}
        verify(manifest, "feature-sleep-learner", review)
        for field in ("executable_sha256", "stdlib_sha256", "version"):
            changed = copy.deepcopy(manifest); changed["python"][field] = "changed"
            with self.assertRaisesRegex(Abstain, "runtime_environment_mismatch"):
                verify(changed, "feature-sleep-learner", review)
        changed = copy.deepcopy(manifest); changed["model_id"] = "correncoder"
        with self.assertRaisesRegex(Abstain, "required_packages_missing"):
            verify(changed, "correncoder", review)

    def test_package_content_drift_and_missing_review_evidence_fail_closed(self):
        manifest = capture("feature-sleep-learner")
        manifest.update(qualification_status="qualified_shadow_environment")
        review = {"status": "reviewed_for_shadow", "identifier": "synthetic", "evidence": "functional fixture only"}
        actual = copy.deepcopy(manifest); actual["packages"][0]["content_sha256"] = "b" * 64
        with patch("physiology_inference.environment.capture", return_value=actual):
            with self.assertRaisesRegex(Abstain, "runtime_environment_mismatch"):
                verify(manifest, "feature-sleep-learner", review)
        with self.assertRaisesRegex(Abstain, "environment_review_required"):
            verify(manifest, "feature-sleep-learner", {**review, "evidence": " "})

    def test_mandatory_source_import_dependencies_cannot_be_omitted(self):
        self.assertTrue({"numpy", "scipy"}.issubset(MODEL_DISTRIBUTIONS["rrest"]))
        self.assertTrue({"requests", "setuptools", "numpy"}.issubset(MODEL_DISTRIBUTIONS["neurokit2"]))
        self.assertTrue({"hydra-core", "huggingface-hub", "pandas", "pyarrow", "pyedflib", "omegaconf", "PyYAML",
                         "tqdm", "numba", "setuptools"}.issubset(MODEL_DISTRIBUTIONS["wav2sleep-cardiorespiratory"]))

    def test_import_resolution_must_use_inventoried_distribution_not_alternate_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); installed = root / "installed"; alternate = root / "alternate"
            installed.mkdir(); alternate.mkdir()
            name = "physiology_environment_fixture_dependency"
            recorded = installed / (name + ".py"); recorded.write_text("VALUE = 'recorded'\n")
            other = alternate / (name + ".py"); other.write_text("VALUE = 'alternate'\n")
            distribution = SimpleNamespace(files=[PackagePath(name + ".py")], locate_file=lambda p: installed / str(p))
            with patch.object(sys, "path", [str(installed), *sys.path]):
                origins = import_origins({"fixture": distribution})
                self.assertEqual(origins[0]["selected"]["origin"], str(recorded.resolve()))
            with patch.object(sys, "path", [str(alternate), str(installed), *sys.path]):
                with self.assertRaisesRegex(Abstain, "import_origin_not_in_inventory"):
                    import_origins({"fixture": distribution})
            loaded = ModuleType(name); loaded.__file__ = str(other)
            loaded.__spec__ = ModuleSpec(name, loader=None, origin=str(other))
            with patch.object(sys, "path", [str(installed), *sys.path]), patch.dict(sys.modules, {name: loaded}):
                with self.assertRaisesRegex(Abstain, "import_origin_not_in_inventory"):
                    import_origins({"fixture": distribution})


class ResourceTests(unittest.TestCase):
    def job(self):
        value = {"user_id": "owner", "device_id": "device", "input_revision": "1", "mode": "retrospective", "signals": []}
        return {**value, "input_hash": canonical_hash(value)}

    def test_serial_metrics_normalize_rss_and_preserve_unreviewed_status(self):
        class Runtime:
            def run(self, *args):
                return {"status": "complete", "output": {"value": 12}, "cpu_user_seconds": 0.2,
                        "cpu_system_seconds": 0.1, "peak_rss_platform_units": 1024, "rss_unit": "kilobytes"}
        report = benchmark(self.job(), "synthetic", {}, ".", iterations=3, runtime=Runtime())
        self.assertEqual(report["concurrency"], 1)
        self.assertEqual(report["resources"]["maximum_rss_bytes"], 1024**2)
        self.assertAlmostEqual(report["resources"]["cpu_seconds_per_record"], 0.3)
        self.assertGreater(report["resources"]["records_per_hour"], 0)
        self.assertTrue(report["repeatability_passed"])
        self.assertEqual(report["actual_target_qualification"], "not_attested")
        self.assertFalse(report["canonical_publication_enabled"])

    def test_failures_and_nondeterminism_cannot_become_qualified_resource_evidence(self):
        class Failed:
            def run(self, *args):
                return {"status": "abstained", "reason": "environment_manifest_missing"}
        report = benchmark(self.job(), "synthetic", {}, ".", iterations=2, runtime=Failed())
        self.assertEqual(report["status"], "not_ready")
        self.assertEqual(report["resources"]["records_per_hour"], 0)
        self.assertIsNone(report["resources"]["maximum_rss_bytes"])
        self.assertFalse(within_tolerance({"rate": 12}, {"rate": 13}, 0.1))
        self.assertTrue(within_tolerance({"rate": 12}, {"rate": 12.01}, 0.1))
        self.assertFalse(within_tolerance({"rate": None}, {"rate": 0}, 0.1))
        self.assertFalse(within_tolerance([True], [1], 0))

    def test_missing_or_nonfinite_cpu_rss_cannot_report_complete_measurement(self):
        for invalid in ({}, {"cpu_user_seconds": float("nan"), "cpu_system_seconds": 0,
                            "peak_rss_platform_units": 123, "rss_unit": "bytes"}):
            class Runtime:
                def run(self, *args):
                    return {"status": "complete", "output": {"value": 12}, **invalid}
            report = benchmark(self.job(), "synthetic", {}, ".", iterations=2, runtime=Runtime())
            self.assertEqual(report["status"], "not_ready")
            self.assertFalse(report["resource_measurements_complete"])
            self.assertIsNone(report["resources"]["cpu_seconds_per_record"])

    def test_octave_subprocess_cannot_be_qualified_from_python_worker_usage(self):
        class Runtime:
            def run(self, *args):
                return {"status": "complete", "output": {"value": 12}, "cpu_user_seconds": 0.2,
                        "cpu_system_seconds": 0.1, "peak_rss_platform_units": 1024, "rss_unit": "kilobytes"}
        report = benchmark(self.job(), "rrest", {}, ".", iterations=2, runtime=Runtime())
        self.assertEqual(report["status"], "not_ready")
        self.assertEqual(report["resource_unavailable_reason"], "external_process_accounting_unavailable")
        self.assertIsNone(report["resources"]["maximum_rss_bytes"])
        self.assertIsNone(report["resources"]["cpu_seconds_per_record"])
        self.assertGreater(report["resources"]["records_per_hour"], 0)
        self.assertEqual(report["worker_diagnostics"]["maximum_rss_bytes"], 1024**2)
