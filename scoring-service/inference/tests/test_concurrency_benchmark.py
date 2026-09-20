import threading
import time
import unittest

from physiology_inference.concurrency_benchmark import benchmark
from physiology_inference.contracts import canonical_hash


class ConcurrencyBenchmarkTest(unittest.TestCase):
    def job(self):
        job = {"user_id": "synthetic-user", "device_id": "synthetic-device", "input_revision": "1",
               "mode": "retrospective", "signals": []}
        job["input_hash"] = canonical_hash(job)
        return job

    def test_bounded_parallelism_and_missing_aggregate_resources_never_qualify(self):
        lock = threading.Lock()
        observed = {"running": 0, "maximum": 0}

        class Runtime:
            def run(self, *args):
                with lock:
                    observed["running"] += 1
                    observed["maximum"] = max(observed["maximum"], observed["running"])
                time.sleep(.02)
                with lock:
                    observed["running"] -= 1
                return {"status": "complete", "output": [1.0]}

        result = benchmark(self.job(), "fixture", {}, ".", concurrency=2, iterations=8, runtime_factory=Runtime)
        self.assertEqual(observed["maximum"], 2)
        self.assertEqual(result["completed_iterations"], 8)
        self.assertTrue(result["repeatability_passed"])
        self.assertEqual(result["status"], "not_ready")
        self.assertIsNone(result["resources"]["process_tree_memory_peak_bytes"])
        self.assertFalse(result["canonical_publication_enabled"])

    def test_failure_remains_visible_and_resource_report_is_not_accuracy(self):
        class Runtime:
            def run(self, *args):
                return {"status": "abstained", "reason": "inference_timeout"}

        result = benchmark(self.job(), "fixture", {}, ".", iterations=2, runtime_factory=Runtime)
        self.assertEqual(result["completed_iterations"], 0)
        self.assertEqual(len(result["failures"]), 2)
        self.assertFalse(result["repeatability_passed"])
        self.assertEqual(result["actual_target_qualification"], "not_attested")

    def test_invalid_concurrency_and_tolerance_fail_before_execution(self):
        for concurrency in (0, 5, True):
            with self.assertRaises(ValueError):
                benchmark(self.job(), "fixture", {}, ".", concurrency=concurrency)
        with self.assertRaises(ValueError):
            benchmark(self.job(), "fixture", {}, ".", tolerance=float("nan"))


if __name__ == "__main__":
    unittest.main()
