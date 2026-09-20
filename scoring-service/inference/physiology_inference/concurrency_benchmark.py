"""Bounded concurrent shadow execution; no target qualification without whole-scope evidence."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import math
from pathlib import Path
import platform
import time

from .contracts import canonical_hash, validate_job
from .correction_comparison import read_json, require
from .process_resources import CgroupProcessAccounting, difference
from .resource_benchmark import within_tolerance
from .runtime import ShadowRuntime


def benchmark(job, model_id, activation, asset_root, concurrency=1, iterations=10,
              tolerance=0.0, runtime_factory=ShadowRuntime, process_cgroup=None):
    validate_job(job)
    require(type(concurrency) is int and 1 <= concurrency <= 4, "concurrency must be 1..4")
    require(type(iterations) is int and 2 <= iterations <= 100, "iterations must be 2..100")
    require(math.isfinite(tolerance) and tolerance >= 0, "frozen numerical tolerance required")
    accounting = CgroupProcessAccounting(process_cgroup) if process_cgroup else None

    def execute(_):
        started = time.monotonic()
        result = runtime_factory().run(job, model_id, activation, asset_root)
        return result, (time.monotonic() - started) * 1000

    before = accounting.snapshot() if accounting else None
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=concurrency, thread_name_prefix="model-benchmark") as pool:
        records = list(pool.map(execute, range(iterations)))
    elapsed = time.monotonic() - start
    usage = difference(before, accounting.snapshot()) if accounting else None
    complete = [result for result, _ in records if result.get("status") == "complete"]
    latencies = [latency for _, latency in records]
    repeatable = len(complete) == iterations and all(
        within_tolerance(complete[0].get("output"), row.get("output"), tolerance) for row in complete)
    return {
        "schema_version": 1, "publication_mode": "shadow", "canonical_publication_enabled": False,
        "status": "measured_pending_external_review" if repeatable and usage else "not_ready",
        "actual_target_qualification": "not_attested", "resource_scope": "measured_host_unreviewed",
        "model_id": model_id, "input_sha256": canonical_hash(job), "activation_sha256": canonical_hash(activation),
        "host": {"system": platform.system(), "machine": platform.machine(), "python": platform.python_version()},
        "concurrency": concurrency, "iterations": iterations, "completed_iterations": len(complete),
        "numerical_tolerance": tolerance, "repeatability_passed": repeatable, "wall_seconds": elapsed,
        "resources": {
            "p95_latency_ms": sorted(latencies)[math.ceil(len(latencies) * .95) - 1],
            "records_per_hour": len(complete) * 3600 / elapsed if elapsed > 0 else None,
            "cpu_seconds_per_record": usage["cpu_seconds"] / iterations if usage else None,
            "process_tree_memory_peak_bytes": usage["memory_peak_bytes"] if usage else None,
            "maximum_rss_bytes": None,
        },
        "resource_measurements_complete": usage is not None,
        "resource_accounting": {
            "method": "dedicated_cgroup_v2_process_tree" if usage else "unavailable",
            "cgroup_path": str(accounting.path) if accounting else None,
            "memory_semantics": "kernel_cgroup_lifetime_charged_memory_peak" if usage else None,
        },
        "failures": [{"iteration": i, "reason": result.get("reason", "incomplete_model_output")}
                     for i, (result, _) in enumerate(records) if result.get("status") != "complete"],
        "limitations": [
            "Concurrent test executes identical immutable inputs to measure resources, not accuracy.",
            "Latency includes cold process and model loading, and excludes waiting in the benchmark executor.",
            "Do not sum child RSS or relabel kernel charged memory as aggregate RSS.",
            "The dedicated cgroup must be externally attested exclusive for this run; lifetime memory peak includes prior charges.",
            "Actual VPS identity, ingestion/database headroom and deployment concurrency require separate approval.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("job", "activation", "asset-root", "output"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--tolerance", type=float, required=True)
    parser.add_argument("--process-cgroup")
    args = parser.parse_args()
    try:
        activation = read_json(args.activation)
        result = benchmark(read_json(args.job), activation["model_id"], activation, args.asset_root,
                           args.concurrency, args.iterations, args.tolerance, process_cgroup=args.process_cgroup)
        with Path(args.output).open("x") as stream:
            json.dump(result, stream, sort_keys=True, indent=2, allow_nan=False)
            stream.write("\n")
        return 0 if result["status"] == "measured_pending_external_review" else 3
    except (ValueError, KeyError, OSError) as error:
        parser.exit(2, f"concurrency-benchmark: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
