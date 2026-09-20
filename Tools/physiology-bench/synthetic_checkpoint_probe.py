#!/usr/bin/env python3
"""Synthetic released-checkpoint resource probe. No activation, reference labels or publication client."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import contextlib
from hashlib import sha256
import json
import math
import os
from pathlib import Path
import platform
import re
import resource
import signal
import subprocess
import sys
import tempfile
import time

from physiology_inference.contracts import Abstain, Signal, canonical_hash, implementation_hash, verify_asset
from physiology_inference.process_resources import CgroupProcessAccounting, bounded_text, difference
from physiology_inference.runtime import isolated_child_environment

VERSION = "synthetic-checkpoint-resource-probe-1"
MAX_MEMORY = 3 * 1024**3
FAILURE_REASONS = {"checkpoint_contract_rejected", "checkpoint_dependency_unavailable", "checkpoint_cache_unavailable",
                   "checkpoint_filesystem_permission", "checkpoint_asset_missing", "checkpoint_memory_limit",
                   "checkpoint_scratch_space_exhausted", "checkpoint_read_only_path", "checkpoint_execution_failed"}
EXCEPTION_TYPES = {"Abstain", "ImportError", "ModuleNotFoundError", "PermissionError", "FileNotFoundError",
                   "MemoryError", "OSError", "RuntimeError", "ValueError", "TypeError", "KeyError", "Exception"}
FIXTURE = {"version": "synthetic-ppg-sines-1", "sample_rate_hz": 24, "cardiac_hz": 1,
           "modulation_hz": .2, "cardiac_amplitude": 1000, "modulation_amplitude": 100,
           "unit": "adc_count", "wavelength_nm": 525, "reference": None,
           "acquisition": "generated_not_hardware", "integer_rounding": "python_round_nearest_even"}


def source_hash():
    return sha256(Path(__file__).read_bytes()).hexdigest()


def lock():
    import physiology_inference
    return json.loads((Path(physiology_inference.__file__).parent / "upstream-lock.json").read_text())["models"]["wav2sleep-cardiorespiratory"]


def make_plan(source_revision, image_id, epochs=20, iterations=4, concurrency=1,
              timeout_seconds=120, cpu_seconds_per_record_budget=60):
    pinned = lock()
    plan = {"schema_version": 1, "model_id": "wav2sleep-cardiorespiratory", "probe_version": VERSION, "probe_sha256": source_hash(),
        "source_revision": source_revision, "image_id": image_id,
        "implementation_sha256": implementation_hash(), "checkpoint_sha256": pinned["checkpoint_sha256"],
        "config_sha256": pinned["config_sha256"], "upstream_code_revision": pinned["code_revision"],
        "fixture": FIXTURE, "epochs": epochs, "iterations": iterations, "concurrency": concurrency,
        "timeout_seconds_per_record": timeout_seconds, "cpu_seconds_per_record_budget": cpu_seconds_per_record_budget,
        "maximum_container_cpus": 2, "maximum_container_memory_bytes": MAX_MEMORY,
        "maximum_container_swap_bytes": 0, "maximum_container_pids": 128,
        "numerical_tolerance": 0.0, "repeatability_policy": "exact_output_hash_within_environment",
        "synthetic_only": True, "activation_qualified": False, "canonical_outputs_allowed": False,
        "reference_accuracy": None, "target_qualification": "not_granted"}
    plan["plan_sha256"] = canonical_hash(plan)
    validate_plan(plan)
    return plan


def validate_plan(plan):
    if not isinstance(plan, dict) or plan.get("plan_sha256") != canonical_hash({k: v for k, v in plan.items() if k != "plan_sha256"}):
        raise Abstain("probe_plan_digest_mismatch")
    if (plan.get("probe_version") != VERSION or plan.get("model_id") != "wav2sleep-cardiorespiratory" or
            plan.get("probe_sha256") != source_hash() or plan.get("fixture") != FIXTURE):
        raise Abstain("probe_plan_source_or_fixture_mismatch")
    if (plan.get("implementation_sha256") != implementation_hash() or
            any(plan.get(field) != lock()[field] for field in ("checkpoint_sha256", "config_sha256"))):
        raise Abstain("probe_runtime_or_checkpoint_mismatch")
    if not re.fullmatch(r"[0-9a-f]{40}", plan.get("source_revision", "")) or not re.fullmatch(r"sha256:[0-9a-f]{64}", plan.get("image_id", "")):
        raise Abstain("probe_build_identity_missing")
    for field, low, high in (("epochs", 1, 960), ("iterations", 2, 10), ("concurrency", 1, 2)):
        if type(plan.get(field)) is not int or not low <= plan[field] <= high:
            raise Abstain("probe_workload_bounds_invalid")
    for field in ("timeout_seconds_per_record", "cpu_seconds_per_record_budget"):
        if type(plan.get(field)) not in (int, float) or not math.isfinite(plan[field]) or not 0 < plan[field] <= 120:
            raise Abstain("probe_time_budget_invalid")
    if (plan.get("numerical_tolerance") != 0 or plan.get("maximum_container_cpus") != 2 or
            plan.get("maximum_container_memory_bytes") != MAX_MEMORY or plan.get("maximum_container_swap_bytes") != 0 or
            plan.get("maximum_container_pids") != 128 or plan.get("synthetic_only") is not True or
            plan.get("activation_qualified") is not False or plan.get("canonical_outputs_allowed") is not False or
            plan.get("reference_accuracy") is not None or plan.get("target_qualification") != "not_granted"):
        raise Abstain("probe_safety_policy_invalid")
    return plan


def read_json(path, maximum=1024 * 1024):
    with Path(path).open("rb") as stream:
        raw = stream.read(maximum + 1)
    if len(raw) > maximum:
        raise Abstain("probe_json_size_limit")
    def reject(value): raise ValueError("nonfinite JSON")
    return json.loads(raw, parse_constant=reject)


def write_new(path, value):
    with Path(path).open("x") as stream:
        json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False); stream.write("\n")


def check_limits(path):
    quota, period = bounded_text(path / "cpu.max").split()
    if quota == "max" or not quota.isdecimal() or not period.isdecimal() or not 0 < int(quota) <= 2 * int(period):
        raise Abstain("probe_cpu_hard_limit_required")
    limits = {}
    for name, maximum in (("memory.max", MAX_MEMORY), ("memory.swap.max", 0), ("pids.max", 128)):
        value = bounded_text(path / name).strip()
        if not value.isdecimal() or int(value) > maximum or name != "memory.swap.max" and int(value) <= 0:
            raise Abstain("probe_" + name.replace(".", "_") + "_hard_limit_required")
        limits[name] = int(value)
    return {"cpu_quota": int(quota), "cpu_period": int(period), **limits}


def single_record(plan, asset_root):
    validate_plan(plan)
    # Child-local CPU/file limits supplement (never replace) the whole-container hard caps.
    limit = max(1, math.ceil(plan["timeout_seconds_per_record"]))
    resource.setrlimit(resource.RLIMIT_CPU, (limit, limit + 1))
    resource.setrlimit(resource.RLIMIT_FSIZE, (1024 * 1024, 1024 * 1024))
    pinned = lock()
    paths = {name: verify_asset({"path": filename, "sha256": pinned[key]}, asset_root) for name, filename, key in
             (("weights", "state_dict.pth", "checkpoint_sha256"), ("config", "config.yaml", "config_sha256"))}
    count = plan["epochs"] * 30 * 24 + 1
    values = [round(1000 * math.sin(2 * math.pi * i / 24) + 100 * math.sin(2 * math.pi * .2 * i / 24)) for i in range(count)]
    raw = {"name": "PPG", "unit": "adc_count", "sample_rate_hz": 24, "start": 0,
        "values": values, "observed": [True] * count, "timing_verified": True, "semantics_verified": True,
        "clock_id": "synthetic-clock", "acquisition_id": "synthetic-no-person-no-reference", "wavelength_nm": 525}
    from physiology_inference.adapters import wav2sleep_predict
    output = wav2sleep_predict({"PPG": Signal.parse(raw)}, plan["epochs"], paths, pinned["package_tree_sha256"])
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return {"plan_sha256": plan["plan_sha256"], "input_sha256": canonical_hash(raw),
        "output_sha256": canonical_hash(output), "epochs": len(output["stages"]),
        "cpu_seconds": usage.ru_utime + usage.ru_stime,
        "maximum_rss_bytes": usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss * 1024,
        "synthetic_only": True, "activation_qualified": False, "canonical_outputs_allowed": False}


def sanitized_failure(error, plan_hash):
    reason = "checkpoint_execution_failed"
    if isinstance(error, Abstain): reason = "checkpoint_contract_rejected"
    elif isinstance(error, ImportError): reason = "checkpoint_dependency_unavailable"
    elif isinstance(error, PermissionError): reason = "checkpoint_filesystem_permission"
    elif isinstance(error, FileNotFoundError): reason = "checkpoint_asset_missing"
    elif isinstance(error, MemoryError): reason = "checkpoint_memory_limit"
    elif isinstance(error, OSError) and error.errno == 28: reason = "checkpoint_scratch_space_exhausted"
    elif isinstance(error, OSError) and error.errno == 30: reason = "checkpoint_read_only_path"
    elif isinstance(error, RuntimeError) and "cannot cache function" in str(error) and "no locator available" in str(error):
        reason = "checkpoint_cache_unavailable"
    return {"status": "failed", "reason": reason, "plan_sha256": plan_hash,
            "exception_type": type(error).__name__ if type(error).__name__ in EXCEPTION_TYPES else "Exception"}


def child_record(plan_path, plan, asset_root):
    start = time.monotonic()
    result = {"status": "failed", "reason": None}
    with isolated_child_environment() as environment, tempfile.TemporaryFile() as output:
        with subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "worker", "--plan", str(plan_path),
            "--asset-root", str(asset_root)], stdout=output, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, env=environment, start_new_session=True) as child:
            try:
                child.wait(timeout=plan["timeout_seconds_per_record"])
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL); child.wait()
                result["reason"] = "checkpoint_timeout"
            if result["reason"] is None and child.returncode:
                result["reason"] = "checkpoint_worker_signal" if child.returncode < 0 else "checkpoint_worker_failed"
            exit_code = child.returncode
        output.seek(0); raw = output.read(1024 * 1024 + 1)
        if result["reason"] == "checkpoint_worker_failed":
            try:
                record = json.loads(raw)
                if (len(raw) <= 4096 and isinstance(record, dict) and record.get("status") == "failed" and
                        record.get("plan_sha256") == plan["plan_sha256"] and record.get("reason") in FAILURE_REASONS and
                        record.get("exception_type") in EXCEPTION_TYPES):
                    result.update(reason=record["reason"], exception_type=record["exception_type"])
            except (ValueError, TypeError): pass
        if result["reason"] is None:
            try:
                record = json.loads(raw)
                if len(raw) > 1024 * 1024 or not isinstance(record, dict) or record.get("plan_sha256") != plan["plan_sha256"] or record.get("epochs") != plan["epochs"]:
                    raise ValueError("worker identity")
                if any(not re.fullmatch(r"[a-f0-9]{64}", record.get(key, "")) for key in ("input_sha256", "output_sha256")):
                    raise ValueError("worker hashes")
                if record.get("synthetic_only") is not True or record.get("activation_qualified") is not False or record.get("canonical_outputs_allowed") is not False:
                    raise ValueError("worker safety")
                if any(type(record.get(key)) not in (float, int) or not math.isfinite(record[key]) or record[key] <= 0 for key in ("cpu_seconds", "maximum_rss_bytes")):
                    raise ValueError("worker resource diagnostics")
                result = {"status": "complete", **record}
            except (ValueError, TypeError):
                result["reason"] = "checkpoint_output_invalid"
    result["exit_code"] = exit_code
    result["signal_number"] = -exit_code if exit_code < 0 else None
    result["elapsed_seconds"] = time.monotonic() - start
    return result


def summarize(plan, records, elapsed, usage, limits):
    complete = [row for row in records if row["status"] == "complete"]
    repeatable = len(complete) == plan["iterations"] and len({(row["input_sha256"], row["output_sha256"]) for row in complete}) == 1
    latencies = sorted(row["elapsed_seconds"] for row in records)
    cpu_per_record = usage["cpu_seconds"] / len(complete) if complete else None
    budgets_passed = (repeatable and cpu_per_record <= plan["cpu_seconds_per_record_budget"] and
        max(latencies) <= plan["timeout_seconds_per_record"] and usage["memory_peak_bytes"] <= MAX_MEMORY)
    return {"schema_version": 1, "probe_version": VERSION, "plan": plan,
        "status": "synthetic_measurement_complete" if repeatable else "not_ready",
        "synthetic_only": True, "activation_qualified": False, "canonical_outputs_allowed": False,
        "reference_accuracy": None, "target_qualification": "not_granted",
        "diagnostic_budget_passed": budgets_passed, "repeatability_passed": repeatable,
        "completed_records": len(complete), "records": records, "wall_seconds": elapsed,
        "host": {"system": platform.system(), "machine": platform.machine(), "python": platform.python_version()},
        "container_limits": limits, "resources": {"cpu_seconds": usage["cpu_seconds"],
            "cpu_seconds_per_completed_record": cpu_per_record,
            "process_tree_memory_peak_bytes": usage["memory_peak_bytes"], "maximum_aggregate_rss_bytes": None,
            "p95_record_latency_seconds": latencies[math.ceil(len(latencies) * .95) - 1],
            "records_per_hour": len(complete) * 3600 / elapsed},
        "scope": {"workload": "synthetic PPG with actual released checkpoint; one inference per fresh child",
            "latency": "child start through input generation, hash checks, model import/load/inference/output; excludes executor waiting",
            "cpu": "dedicated container cgroup benchmark and all descendants",
            "memory": "fresh container lifetime kernel charged peak, includes cache/kernel; not summed RSS",
            "excluded": "production activation guard/environment verification, JVM/ingestion/database, reference or device validation"}}


def run(plan_path, asset_root, process_cgroup):
    plan = validate_plan(read_json(plan_path))
    accounting = CgroupProcessAccounting(process_cgroup)
    limits = check_limits(accounting.path)
    before = accounting.snapshot(); start = time.monotonic()
    with ThreadPoolExecutor(max_workers=plan["concurrency"]) as pool:
        records = list(pool.map(lambda _: child_record(plan_path, plan, asset_root), range(plan["iterations"])))
    elapsed = time.monotonic() - start
    after = accounting.snapshot()
    if check_limits(accounting.path) != limits:
        raise Abstain("probe_container_limits_changed")
    return summarize(plan, records, elapsed, difference(before, after), limits)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="command", required=True)
    plan_parser = modes.add_parser("plan")
    for name in ("source-revision", "image-id", "output"):
        plan_parser.add_argument("--" + name, required=True)
    plan_parser.add_argument("--epochs", type=int, default=20)
    plan_parser.add_argument("--iterations", type=int, default=4)
    plan_parser.add_argument("--concurrency", type=int, choices=(1, 2), default=1)
    plan_parser.add_argument("--timeout-seconds", type=float, default=120)
    plan_parser.add_argument("--cpu-seconds-per-record-budget", type=float, default=60)
    for name in ("run", "worker"):
        item = modes.add_parser(name); item.add_argument("--plan", required=True); item.add_argument("--asset-root", required=True)
        if name == "run":
            item.add_argument("--process-cgroup", default="/sys/fs/cgroup"); item.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.command == "plan":
        write_new(args.output, make_plan(args.source_revision, args.image_id, args.epochs, args.iterations,
            args.concurrency, args.timeout_seconds, args.cpu_seconds_per_record_budget))
        return 0
    if args.command == "worker":
        plan = read_json(args.plan)
        try:
            with contextlib.redirect_stdout(sys.stderr):
                result = single_record(plan, args.asset_root)
        except Exception as error:
            result = sanitized_failure(error, plan.get("plan_sha256"))
            print(json.dumps(result, sort_keys=True, allow_nan=False))
            return 4
        print(json.dumps(result, sort_keys=True, allow_nan=False))
        return 0
    report = run(args.plan, args.asset_root, args.process_cgroup)
    write_new(args.output, report)
    return 0 if report["status"] == "synthetic_measurement_complete" and report["diagnostic_budget_passed"] else 3


if __name__ == "__main__":
    raise SystemExit(main())
