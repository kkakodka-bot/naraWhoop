#!/usr/bin/env python3
"""Record a candidate and sanitized local evidence; never infer physical release acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

SCENARIOS = (
    "locked_backlog_2h", "overnight_12h_three_runs", "range_return_30_cycles",
    "bluetooth_off_10min_locked_recovery", "discovery_subscription_commit_ack_interruptions",
    "genuine_system_termination_restoration", "offline_2h_locked_recovery",
    "network_credentials_signed_url_transitions", "low_power_thermal_pressure",
    "reboot_first_unlock_recovery", "force_quit_negative_control", "ordinary_72h_soak",
)
GATES = (
    "premature_acks", "acknowledged_missing_rows", "wrong_account_delivery",
    "source_advance_without_exact_receipt", "logical_replay_duplicates",
    "callback_to_pending_connection_p99", "connect_to_required_notifications",
    "end_to_ack_submission_p99_1000_chunks", "maximum_app_ack_latency",
    "ordinary_sqlite_durability_commits", "cloud_impact_on_ble_p99",
    "backfill_throughput_30min", "healthy_link_progress_gap", "bulk_admission_stop_latency",
    "critical_thermal_jetsam_exc_resource", "memory_delta_and_peak", "matched_battery_regression",
)
EVIDENCE_NAMES = {
    "connection", "transport", "hosted", "store", "push", "cloud", "imu", "crash_stress",
    "analytics", "server", "compression", "localization", "tools", "ios_release", "ci",
}


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def sanitized_xcresult(value):
    """Allowlist fields: raw bundles can contain hardware IDs and arbitrary failure text."""
    return {
        "result": value.get("result", "NOT_MEASURED"),
        "passed_tests": int(value.get("passedTests", 0)),
        "failed_tests": int(value.get("failedTests", 0)),
        "skipped_tests": int(value.get("skippedTests", 0)),
        "expected_failures": int(value.get("expectedFailures", 0)),
        "environments": [
            {key: entry.get("device", {}).get(key, "NOT_MEASURED")
             for key in ("architecture", "modelName", "osVersion", "platform")}
            for entry in value.get("devicesAndConfigurations", [])
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--xcresult", type=Path)
    parser.add_argument("--evidence", action="append", default=[], metavar="NAME=PATH")
    args = parser.parse_args()
    root = Path(command("git", "rev-parse", "--show-toplevel"))
    sha = command("git", "rev-parse", "HEAD")
    dirty = bool(command("git", "status", "--porcelain"))
    project = (root / "project.yml").read_text()
    def version(key):
        match = re.search(r'^\s*' + key + r':\s*"([^"\n]+)"', project, re.M)
        return match.group(1) if match else "NOT_MEASURED"
    evidence = []
    for argument in args.evidence:
        name, separator, filename = argument.partition("=")
        if not separator or name not in EVIDENCE_NAMES:
            parser.error("evidence must use an approved nonidentifying label")
        path = Path(filename)
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1_048_576), b""):
                digest.update(block)
        evidence.append({"name": name, "sha256": digest.hexdigest(), "bytes": path.stat().st_size,
                         "source_binding": "SEE_RUN_SOURCE_SHA_OR_FINGERPRINTS"})
    result = {
        "schema_version": 1,
        "candidate": {"sha": sha, "working_tree_dirty": dirty,
                      "version": version("MARKETING_VERSION"), "build": version("CURRENT_PROJECT_VERSION")},
        "audited_sha": "2f26b62ae685ddbcec4c539f7c5d806ce72f60cf",
        "resumed_pr22_sha": "97704bdf8e4ab802083070d8d45664ade51c1f6c",
        "release_disposition": "NOT_READY",
        "local_evidence": evidence,
        "physical_cells": [
            {"phone_cell": phone, "whoop_family": family,
             "device_model": "NOT_MEASURED", "ios": "NOT_MEASURED", "firmware": "NOT_MEASURED",
             "network": "NOT_MEASURED", "thermal": "NOT_MEASURED", "low_power_mode": "NOT_MEASURED",
             "scenarios": [{"name": scenario, "status": "NOT_MEASURED", "sample_count": 0}
                           for scenario in SCENARIOS]}
            for phone in ("oldest_supported", "current_public_ios")
            for family in ("WHOOP 4", "WHOOP 5", "WHOOP MG")
        ],
        "physical_release_gates": {name: {"status": "NOT_MEASURED", "sample_count": 0} for name in GATES},
        "instruments": {name: "NOT_MEASURED" for name in (
            "before_after_signposts", "time_profiler", "energy_log", "file_activity", "disk_io")},
        "metrickit": {name: "NOT_MEASURED" for name in ("cpu", "memory", "energy", "hang", "exit")},
        "deployed_server_receipts_and_account_isolation": "NOT_MEASURED",
        "limitations": ["No indefinite background execution", "No ordinary recovery promise after force-quit",
                        "Protected storage may be unavailable before first unlock", "OS scheduling is discretionary",
                        "Local evidence does not establish physical or deployed-server acceptance"],
    }
    if args.xcresult:
        raw = command("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(args.xcresult), "--compact")
        result["hosted_tests"] = sanitized_xcresult(json.loads(raw))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print("Wrote sanitized candidate manifest; release remains NOT_READY.")


if __name__ == "__main__":
    main()
