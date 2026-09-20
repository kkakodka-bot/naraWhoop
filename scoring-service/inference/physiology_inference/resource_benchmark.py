"""Serial bounded model measurements. Host measurements are not automatic VPS qualification."""

import argparse
import json
import math
from pathlib import Path
import platform
import sys
import time

from .contracts import canonical_hash, validate_job
from .correction_comparison import finite, read_json, require
from .runtime import Limits, ShadowRuntime
from .process_resources import CgroupProcessAccounting, difference


def within_tolerance(first, other, tolerance):
    if isinstance(first, bool) or isinstance(other, bool):
        return first is other
    if isinstance(first, (int, float)) and isinstance(other, (int, float)):
        return math.isfinite(first) and math.isfinite(other) and abs(first - other) <= tolerance
    if isinstance(first, dict) and isinstance(other, dict):
        return first.keys() == other.keys() and all(within_tolerance(first[k], other[k], tolerance) for k in first)
    if isinstance(first, list) and isinstance(other, list):
        return len(first) == len(other) and all(within_tolerance(a, b, tolerance) for a, b in zip(first, other))
    return type(first) is type(other) and first == other


def benchmark(job, model_id, activation, asset_root, iterations=10, warmup=1, tolerance=0.0, runtime=None, process_cgroup=None):
    validate_job(job)
    require(isinstance(iterations, int) and 2 <= iterations <= 100 and isinstance(warmup, int) and 0 <= warmup <= 10,
            "bounded benchmark iterations/warmup required")
    require(math.isfinite(tolerance) and tolerance >= 0, "prespecified numerical tolerance required")
    runtime = runtime or ShadowRuntime()
    accounting = CgroupProcessAccounting(process_cgroup) if process_cgroup is not None else None
    warmups = [runtime.run(job, model_id, activation, asset_root) for _ in range(warmup)]
    started = time.monotonic(); results = []; latencies = []; tree_usage = []
    for _ in range(iterations):
        counters_before = accounting.snapshot() if accounting else None
        before = time.monotonic()
        results.append(runtime.run(job, model_id, activation, asset_root))
        latencies.append((time.monotonic() - before) * 1000)
        if accounting:
            tree_usage.append(difference(counters_before, accounting.snapshot()))
    elapsed = time.monotonic() - started
    completed = [r for r in results if r.get("status") == "complete"]
    all_complete = len(completed) == iterations and all(r.get("status") == "complete" for r in warmups)
    cpu = [r["cpu_user_seconds"] + r["cpu_system_seconds"] for r in results
           if all(finite(r.get(key)) and r[key] >= 0 for key in ("cpu_user_seconds", "cpu_system_seconds"))]
    rss = [r["peak_rss_platform_units"] * (1 if r["rss_unit"] == "bytes" else 1024) for r in results
           if r.get("rss_unit") in ("bytes", "kilobytes") and finite(r.get("peak_rss_platform_units")) and r["peak_rss_platform_units"] > 0]
    # Octave performs RRest's computation outside the measured Python worker.
    external_process = model_id == "rrest"
    resources_complete = bool(accounting) or (not external_process and len(cpu) == iterations and len(rss) == iterations)
    measured_cpu = sum(item["cpu_seconds"] for item in tree_usage) / iterations if accounting else (
        sum(cpu) / iterations if not external_process and len(cpu) == iterations else None)
    measured_memory = max(item["memory_peak_bytes"] for item in tree_usage) if accounting else (
        max(rss) if not external_process and len(rss) == iterations else None)
    repeatable = all_complete and all(within_tolerance(completed[0].get("output"), r.get("output"), tolerance) for r in completed)
    return {"schema_version": 1, "publication_mode": "shadow", "canonical_publication_enabled": False,
            "status": "measured_pending_external_review" if all_complete and repeatable and resources_complete else "not_ready",
            "resource_scope": "measured_host_unreviewed", "actual_target_qualification": "not_attested",
            "host": {"system": platform.system(), "machine": platform.machine(), "python": platform.python_version()},
            "model_id": model_id, "input_sha256": canonical_hash(job), "activation_sha256": canonical_hash(activation),
            "concurrency": 1, "iterations": iterations, "warmup_iterations": warmup,
            "completed_iterations": len(completed), "wall_seconds": elapsed,
            "numerical_tolerance": tolerance, "repeatability_passed": repeatable, "resource_measurements_complete": resources_complete,
            "output_hashes": [canonical_hash(r.get("output")) for r in completed],
            "worker_diagnostics": {"maximum_rss_bytes": max(rss) if len(rss) == iterations else None,
                                   "cpu_seconds_per_record": sum(cpu) / iterations if len(cpu) == iterations else None},
            "resource_accounting": {"method": "dedicated_cgroup_v2_process_tree" if accounting else "python_worker_rusage",
                "cgroup_path": str(accounting.path) if accounting else None,
                "memory_semantics": "kernel_cgroup_lifetime_charged_memory_peak" if accounting else "single_worker_peak_rss",
                "dedicated_scope_checked": bool(accounting)},
            "resources": {"p95_latency_ms": sorted(latencies)[math.ceil(iterations * 0.95) - 1],
                          "maximum_rss_bytes": measured_memory if not accounting else None,
                          "process_tree_memory_peak_bytes": measured_memory if accounting else None,
                          "cpu_seconds_per_record": measured_cpu,
                          "records_per_hour": len(completed) * 3600 / elapsed if elapsed > 0 else None},
            "resource_unavailable_reason": "external_process_accounting_unavailable" if external_process and not accounting else
                                           (None if resources_complete else "worker_resource_measurements_missing"),
            "latencies_ms": latencies,
            "failures": [{"phase": phase, "iteration": i, "reason": r.get("reason", "incomplete_model_output")}
                         for phase, values in (("warmup", warmups), ("measurement", results))
                         for i, r in enumerate(values) if r.get("status") != "complete"],
            "limitations": ["Serial child CPU/RSS includes environment verification and model loading.",
                            "Without dedicated cgroup accounting, external Octave CPU/RSS is unavailable, not worker usage.",
                            "Cgroup CPU includes the benchmark and all descendants; memory.peak bounds lifetime kernel-charged memory, not aggregate RSS.",
                            "Charged memory may include warmup, caches and kernel memory; shared pages may be charged elsewhere. Its budget must explicitly select this metric, never RSS.",
                            "External processes must not join or leave the dedicated scope during a run; external review must attest isolation.",
                            "JVM/ingestion/Postgres and optional GPU measurements outside the scope are not included.",
                            "External reviewers must bind host identity, representative inputs and frozen budgets before target qualification."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job", required=True); parser.add_argument("--activation", required=True)
    parser.add_argument("--asset-root", required=True); parser.add_argument("--output")
    parser.add_argument("--iterations", type=int, default=10); parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--tolerance", type=float, required=True); parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--process-cgroup", help="Own dedicated Linux cgroup-v2 path; enables kernel process-tree accounting")
    args = parser.parse_args()
    try:
        activation = read_json(args.activation)
        report = benchmark(read_json(args.job), activation["model_id"], activation, args.asset_root,
                           args.iterations, args.warmup, args.tolerance, ShadowRuntime(Limits(timeout_seconds=args.timeout)), args.process_cgroup)
        encoded = json.dumps(report, sort_keys=True, indent=2, allow_nan=False) + "\n"
        if args.output:
            with Path(args.output).open("x") as stream:
                stream.write(encoded)
        else:
            print(encoded, end="")
        return 0 if report["status"] == "measured_pending_external_review" else 3
    except (ValueError, OSError, KeyError) as error:
        print(f"resource-benchmark: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
