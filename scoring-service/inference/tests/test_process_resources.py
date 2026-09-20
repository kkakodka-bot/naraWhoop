"""Kernel-counter contract controls. Real Linux child smoke is a separate offline probe."""

import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from physiology_inference.contracts import Abstain, canonical_hash
from physiology_inference.process_resources import CgroupProcessAccounting, bounded_text, difference, membership_path
from physiology_inference.resource_benchmark import benchmark


class ProcessResourcesTests(unittest.TestCase):
    def test_membership_resolves_mount_root_and_rejects_arbitrary_paths(self):
        mount = "1 0 0:1 /container /sys/fs/cgroup rw - cgroup2 cgroup rw\n"
        self.assertEqual(membership_path("0::/container/scope\n", mount), Path("/sys/fs/cgroup/scope").resolve())
        self.assertEqual(membership_path("0::/\n", "1 0 0:1 / /some\\040path rw - cgroup2 cgroup rw"), Path("/some path").resolve())
        for membership, table in (("1:cpu:/scope", mount), ("0::/other", mount), ("0::/../scope", mount),
                                  ("0::/container", mount + mount)):
            with self.assertRaises(Abstain):
                membership_path(membership, table)

    def test_mounts_shadowing_scope_or_counter_files_fail_closed(self):
        mount = "1 0 0:1 / /sys/fs/cgroup rw - cgroup2 cgroup rw\n"
        for overlay in ("/sys/fs", "/sys/fs/cgroup", "/sys/fs/cgroup/scope", "/sys/fs/cgroup/scope/cpu.stat", "/sys/fs/cgroup/scope/child"):
            table = mount + f"2 1 0:2 / {overlay} rw - tmpfs tmpfs rw\n"
            with self.assertRaisesRegex(Abstain, "scope_shadowed_by_mount"):
                membership_path("0::/scope", table)

    def test_dedicated_scope_counter_and_identity_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); scope = root / "scope"; scope.mkdir()
            (scope / "cgroup.procs").write_text(str(os.getpid()))
            (scope / "cpu.stat").write_text("usage_usec 100000\nuser_usec 70000\nsystem_usec 30000\n")
            (scope / "memory.peak").write_text("123456\n")
            def read(path):
                if str(path) == "/proc/self/cgroup":
                    return "0::/scope\n"
                if str(path) == "/proc/self/mountinfo":
                    return f"1 0 0:1 / {root} rw - cgroup2 cgroup rw\n"
                return bounded_text(path)
            with patch("physiology_inference.process_resources.sys.platform", "linux"), patch(
                    "physiology_inference.process_resources.bounded_text", side_effect=read):
                accounting = CgroupProcessAccounting(scope)
                self.assertEqual(accounting.snapshot(), {"cpu_usage_usec": 100000, "memory_peak_bytes": 123456})
                with self.assertRaisesRegex(Abstain, "not_current_membership"):
                    CgroupProcessAccounting(root)
                (scope / "cgroup.procs").write_text(f"{os.getpid()}\n999999\n")
                with self.assertRaisesRegex(Abstain, "not_dedicated"):
                    accounting.snapshot()
                (scope / "cgroup.procs").write_text(str(os.getpid()))
                (scope / "cpu.stat").write_text("usage_usec 1\nusage_usec 2\n")
                with self.assertRaisesRegex(Abstain, "cpu_counter_invalid"):
                    accounting.snapshot()
                (scope / "cpu.stat").write_text("usage_usec 100000\n")
                (scope / "memory.peak").write_text("max\n")
                with self.assertRaisesRegex(Abstain, "counters_unavailable"):
                    accounting.snapshot()
                def unreadable_scope(path, onerror):
                    onerror(PermissionError("synthetic unreadable child scope"))
                with patch("physiology_inference.process_resources.os.walk", side_effect=unreadable_scope):
                    with self.assertRaisesRegex(Abstain, "scope_unreadable"):
                        accounting.snapshot()
                accounting.identity = (-1, -1)
                with self.assertRaisesRegex(Abstain, "identity_changed"):
                    accounting.snapshot()

    def test_cpu_delta_and_lifetime_memory_peak_do_not_become_rss(self):
        before = {"cpu_usage_usec": 100000, "memory_peak_bytes": 2000000}
        after = {"cpu_usage_usec": 350000, "memory_peak_bytes": 3000000}
        self.assertEqual(difference(before, after), {"cpu_seconds": 0.25, "memory_peak_bytes": 3000000})
        with self.assertRaisesRegex(Abstain, "counter_reset"):
            difference(after, before)
        class Accounting:
            path = Path("/synthetic/scope")
            def __init__(self):
                self.counter = 0
            def snapshot(self):
                self.counter += 100000
                return {"cpu_usage_usec": self.counter, "memory_peak_bytes": 3000000}
        class Runtime:
            def run(self, *args):
                return {"status": "complete", "output": {"value": 12}}
        value = {"user_id": "owner", "device_id": "device", "input_revision": "1", "mode": "retrospective", "signals": []}
        request = {**value, "input_hash": canonical_hash(value)}
        with patch("physiology_inference.resource_benchmark.CgroupProcessAccounting", return_value=Accounting()):
            report = benchmark(request, "rrest", {}, ".", iterations=2, runtime=Runtime(), process_cgroup="/synthetic/scope")
        self.assertEqual(report["status"], "measured_pending_external_review")
        self.assertEqual(report["resources"]["process_tree_memory_peak_bytes"], 3000000)
        self.assertAlmostEqual(report["resources"]["cpu_seconds_per_record"], 0.1)
        self.assertIsNone(report["resources"]["maximum_rss_bytes"])
        self.assertTrue(report["resource_measurements_complete"])
        self.assertFalse(report["canonical_publication_enabled"])


if __name__ == "__main__":
    unittest.main()
