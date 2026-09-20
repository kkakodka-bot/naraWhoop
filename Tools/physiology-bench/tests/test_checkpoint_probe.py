import copy
import importlib.util
import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scoring-service/inference"))
spec = importlib.util.spec_from_file_location("checkpoint_probe", Path(__file__).resolve().parents[1] / "synthetic_checkpoint_probe.py")
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)


class CheckpointProbeTest(unittest.TestCase):
    def plan(self):
        return probe.make_plan("a" * 40, "sha256:" + "b" * 64, iterations=2)

    def test_plan_is_frozen_before_inference_and_never_qualifies(self):
        plan = self.plan()
        self.assertEqual(probe.validate_plan(plan), plan)
        self.assertFalse(plan["activation_qualified"])
        self.assertIsNone(plan["reference_accuracy"])
        plan["concurrency"] = 2
        with self.assertRaisesRegex(ValueError, "digest_mismatch"):
            probe.validate_plan(plan)

    def test_bounds_and_safety_cannot_be_relaxed_even_if_rehashed(self):
        for key, value in (("concurrency", 3), ("epochs", 961), ("iterations", True),
                           ("maximum_container_memory_bytes", 4 * 1024**3), ("numerical_tolerance", .1),
                           ("activation_qualified", True), ("timeout_seconds_per_record", float("inf"))):
            with self.subTest(key=key):
                plan = self.plan(); plan[key] = value
                with self.assertRaises(ValueError):
                    plan["plan_sha256"] = probe.canonical_hash({k: v for k, v in plan.items() if k != "plan_sha256"})
                    probe.validate_plan(plan)

    def test_whole_container_hard_caps_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in (("cpu.max", "200000 100000"), ("memory.max", str(probe.MAX_MEMORY)),
                                ("memory.swap.max", "0"), ("pids.max", "128")):
                (root / name).write_text(value)
            self.assertEqual(probe.check_limits(root)["memory.swap.max"], 0)
            for name, bad in (("cpu.max", "max 100000"), ("cpu.max", "300000 100000"),
                              ("memory.max", "max"), ("memory.swap.max", "1"), ("pids.max", "129")):
                previous = (root / name).read_text(); (root / name).write_text(bad)
                with self.assertRaises(ValueError): probe.check_limits(root)
                (root / name).write_text(previous)

    def test_repeated_outputs_report_real_scope_not_reference_qualification(self):
        row = {"status": "complete", "input_sha256": "a" * 64, "output_sha256": "b" * 64, "elapsed_seconds": 2}
        report = probe.summarize(self.plan(), [row, copy.deepcopy(row)], 4, {"cpu_seconds": 2, "memory_peak_bytes": 1000}, {})
        self.assertEqual(report["status"], "synthetic_measurement_complete")
        self.assertTrue(report["diagnostic_budget_passed"])
        self.assertEqual(report["resources"]["records_per_hour"], 1800)
        self.assertIsNone(report["resources"]["maximum_aggregate_rss_bytes"])
        self.assertEqual(report["target_qualification"], "not_granted")

    def test_timeout_or_drift_does_not_pass_repeatability(self):
        row = {"status": "complete", "input_sha256": "a" * 64, "output_sha256": "b" * 64, "elapsed_seconds": 2}
        for other in ({"status": "failed", "reason": "checkpoint_timeout", "elapsed_seconds": 3},
                      {**row, "output_sha256": "c" * 64}, {**row, "input_sha256": "d" * 64}):
            report = probe.summarize(self.plan(), [row, other], 5, {"cpu_seconds": 3, "memory_peak_bytes": 1000}, {})
            self.assertEqual(report["status"], "not_ready"); self.assertFalse(report["repeatability_passed"])

    def test_evidence_artifacts_are_new_files_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan.json"
            probe.write_new(path, self.plan())
            with self.assertRaises(FileExistsError): probe.write_new(path, self.plan())

    def test_failure_diagnostics_do_not_include_traceback_paths_or_exception_messages(self):
        private = "private-token-not-for-output"
        errors = ((RuntimeError("cannot cache function " + private + ": no locator available"), "checkpoint_cache_unavailable"),
                  (PermissionError(private), "checkpoint_filesystem_permission"),
                  (ImportError(private), "checkpoint_dependency_unavailable"),
                  (ValueError(private), "checkpoint_execution_failed"))
        for error, expected in errors:
            result = probe.sanitized_failure(error, "a" * 64)
            self.assertEqual(result["reason"], expected)
            self.assertNotIn(private, json.dumps(result))
            self.assertLess(len(json.dumps(result)), 4096)

    def test_failed_real_child_records_sanitized_reason_and_exit_code(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = self.plan()
            path = Path(directory) / "plan.json"
            probe.write_new(path, plan)
            with patch.dict(os.environ, {"PYTHONPATH": str(ROOT / "scoring-service/inference")}):
                result = probe.child_record(path, plan, directory)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["reason"], "checkpoint_contract_rejected")
        self.assertEqual(result["exception_type"], "Abstain")
        self.assertEqual(result["exit_code"], 4)
        self.assertIsNone(result["signal_number"])

    @unittest.skipUnless(os.environ.get("WAV2SLEEP_CHECKPOINT_ROOT") and importlib.util.find_spec("wav2sleep"),
                         "released checkpoint/source not configured for optional actual-adapter test")
    def test_actual_released_adapter_result_has_expected_epoch_identity(self):
        # Build identities here are explicitly unit-test fixtures, not a measured image or VPS.
        # Do not change resource limits of the whole test runner; deployed child limits are separate.
        with patch.object(probe.resource, "setrlimit"):
            record = probe.single_record(self.plan(), os.environ["WAV2SLEEP_CHECKPOINT_ROOT"])
        self.assertEqual(record["epochs"], 20)
        self.assertEqual(len(record["output_sha256"]), 64)
        self.assertTrue(record["synthetic_only"])
        self.assertFalse(record["activation_qualified"])

    @unittest.skipUnless(os.environ.get("WAV2SLEEP_CHECKPOINT_ROOT") and importlib.util.find_spec("wav2sleep"),
                         "released checkpoint/source not configured for optional isolated-child test")
    def test_actual_child_environment_imports_and_predicts_without_passwd_home(self):
        with tempfile.TemporaryDirectory() as directory, probe.isolated_child_environment() as environment:
            path = Path(directory) / "plan.json"
            probe.write_new(path, self.plan())
            script = ("import pwd,sys; from unittest.mock import patch; "
                      "sys.path.insert(0,sys.argv[1]); import synthetic_checkpoint_probe as probe; "
                      "ctx=patch.object(pwd,'getpwuid',side_effect=KeyError('no passwd fixture')); ctx.start(); "
                      "result=probe.single_record(probe.read_json(sys.argv[2]),sys.argv[3]); "
                      "assert result['epochs']==20; print('synthetic_checkpoint_ok')")
            result = subprocess.run([sys.executable, "-c", script, str(Path(probe.__file__).parent),
                                     str(path), os.environ["WAV2SLEEP_CHECKPOINT_ROOT"]],
                                    env=environment, capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "synthetic_checkpoint_ok")


if __name__ == "__main__":
    unittest.main()
