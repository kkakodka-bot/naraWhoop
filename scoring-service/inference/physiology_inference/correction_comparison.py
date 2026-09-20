"""Offline, same-input HRV correction experiment. No reference labels or promotion are inferred."""

import argparse
import json
import math
from pathlib import Path
from statistics import mean, median, stdev

from .adapters import lipponen_corrections
from .contracts import Abstain, canonical_hash, implementation_hash, validate_activation, verify_loaded_package

VERSION = "hrv-correction-comparison-1"
METHODS = ("censor_only", "malik_20pct", "lipponen_observed", "lipponen_corrected_research")


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def union(spans, start, end):
    result = []
    for lo, hi in sorted((max(start, a), min(end, b)) for a, b in spans if a < end and b > start):
        if hi <= lo:
            continue
        if result and lo <= result[-1][1]:
            result[-1] = (result[-1][0], max(hi, result[-1][1]))
        else:
            result.append((lo, hi))
    return result


def malik_mask(intervals):
    """Exact legacy 300..2000 ms range, radius-two neighbours excluding self, <=20% rule."""
    ranged = [(i, value) for i, value in enumerate(intervals) if 300 <= value <= 2000]
    kept = [False] * len(intervals)
    for i, (original, value) in enumerate(ranged):
        neighbours = [v for j, (_, v) in enumerate(ranged[max(0, i - 2):i + 3], start=max(0, i - 2)) if j != i]
        kept[original] = len(ranged) <= 2 or len(neighbours) < 2 or abs(value - median(neighbours)) / median(neighbours) <= 0.20
    return kept


def interval_metrics(peaks, sample_rate, runs, accepted=None):
    intervals = [(b - a) * 1000 / sample_rate for a, b in zip(peaks, peaks[1:])]
    observed = [any(lo <= a < b < hi for lo, hi in runs) for a, b in zip(peaks, peaks[1:])]
    mask = [(observed[i] and 250 <= value <= 2500 and (accepted is None or accepted[i]))
            for i, value in enumerate(intervals)]
    pairs = [i > 0 and mask[i - 1] and mask[i] for i in range(len(intervals))]
    differences = [(intervals[i] - intervals[i - 1]) ** 2 for i in range(1, len(intervals)) if pairs[i]]
    values = [v for v, valid in zip(intervals, mask) if valid]
    return {"interval_values_ms": intervals, "observed_interval_mask": observed,
            "accepted_interval_mask": mask, "pair_mask": pairs, "pair_identity": "original_beats",
            "rmssd_ms": math.sqrt(mean(differences)) if differences else None,
            "sdnn_ms": stdev(values) if len(values) >= 2 else None,
            "valid_pair_count": sum(pairs), "valid_interval_fraction": sum(mask) / sum(observed) if any(observed) else 0,
            "accepted_seconds": sum((b - a) / sample_rate for a, b, keep in zip(peaks, peaks[1:], mask) if keep)}


def validate_input(data):
    require(isinstance(data, dict), "comparison object required")
    require(data.get("schema_version") == 1 and data.get("evidence_kind") in ("synthetic_functional", "reference"), "comparison schema/evidence kind required")
    require(isinstance(data.get("dataset_id"), str) and data["dataset_id"], "dataset identity required")
    records = data.get("recordings")
    require(isinstance(records, list) and 0 < len(records) <= 100, "bounded recordings required")
    ids = set(); total_peaks = total_windows = 0
    for record in records:
        require(isinstance(record, dict), "recording object required")
        for key in ("id", "participant_id", "source_recording_id", "user_id", "device_id"):
            require(isinstance(record.get(key), str) and record[key], f"{key} required")
        require(record["id"] not in ids, "duplicate recording identity"); ids.add(record["id"])
        require(record.get("timing_verified") is True, "original acquisition timing must be verified")
        require(record.get("modality") in ("ppg_pulse_intervals", "ecg_intervals"), "interval modality required")
        digest = record.get("source_sha256", "")
        require(isinstance(digest, str) and len(digest) == 64 and all(c in "0123456789abcdef" for c in digest), "original source hash required")
        start, end, rate = record.get("start_s"), record.get("end_s"), record.get("sample_rate_hz")
        require(all(finite(v) for v in (start, end, rate)) and 0 < end - start <= 76 * 3600 and 1 <= rate <= 10000, "recording clock/bounds invalid")
        spans = record.get("observed_spans", [])
        require(isinstance(spans, list) and len(spans) <= 10000, "observed spans invalid")
        previous = start
        for span in spans:
            require(isinstance(span, dict), "observed span object required")
            lo, hi = span.get("start_s"), span.get("end_s")
            require(finite(lo) and finite(hi) and previous <= lo < hi <= end, "observed spans must be ordered and nonoverlapping")
            previous = hi
        peaks = record.get("peaks")
        require(isinstance(peaks, list) and len(peaks) <= 200000, "bounded original peak list required")
        peak_ids = set(); previous = -1
        for peak in peaks:
            require(isinstance(peak, dict), "peak object required")
            identity, position = peak.get("id"), peak.get("sample_index")
            require(isinstance(identity, str) and identity and identity not in peak_ids, "original peak identity missing/duplicate")
            require(isinstance(position, int) and not isinstance(position, bool) and position > previous and position < (end - start) * rate, "peak samples must be ordered inside recording")
            time = start + position / rate
            require(any(span["start_s"] <= time < span["end_s"] for span in spans), "peak outside observed acquisition")
            previous = position; peak_ids.add(identity)
        total_peaks += len(peaks); total_windows += max(0, math.floor(end / 300) - math.ceil(start / 300))
    require(total_peaks <= 200000 and total_windows <= 1000, "comparison workload limit exceeded")
    return data


def compare(data, neurokit, coverage_thresholds=(0.8, 0.9, 0.95), correction_limits=(0.0, 0.05, 0.1), runtime_provenance=None):
    validate_input(data)
    require(0 < len(coverage_thresholds) <= 10 and all(finite(v) and 0 < v <= 1 for v in coverage_thresholds), "coverage sweep invalid")
    require(0 < len(correction_limits) <= 10 and all(finite(v) and 0 <= v <= 1 for v in correction_limits), "correction sweep invalid")
    windows = []
    for record in data["recordings"]:
        rate = record["sample_rate_hz"]; origin = record["start_s"]
        for start in range(math.ceil(origin / 300) * 300, math.floor(record["end_s"] / 300) * 300, 300):
            end = start + 300
            points = [p for p in record["peaks"] if start <= origin + p["sample_index"] / rate < end]
            require(len(points) <= 5000, "per-window peak limit exceeded")
            peaks = [p["sample_index"] for p in points]
            spans = union([(s["start_s"], s["end_s"]) for s in record["observed_spans"]], start, end)
            runs = [((a - origin) * rate, (b - origin) * rate) for a, b in spans]
            observed_seconds = sum(b - a for a, b in spans)
            gaps = [b - a for a, b in zip([start] + [b for _, b in spans], [a for a, _ in spans] + [end])]
            common = {"recording_id": record["id"], "participant_id": record["participant_id"],
                      "source_recording_id": record["source_recording_id"], "user_id": record["user_id"], "device_id": record["device_id"],
                      "modality": record["modality"], "start_s": start, "end_s": end,
                      "observed_duration_s": observed_seconds, "maximum_gap_s": max(gaps),
                      "observed_spans": [{"start_s": a, "end_s": b} for a, b in spans],
                      "original_peak_ids": [p["id"] for p in points], "original_peak_samples": peaks}
            censor = interval_metrics(peaks, rate, runs)
            malik = [False] * max(0, len(peaks) - 1)
            # The legacy filter is reproduced within observed runs, never across acquisition loss.
            for lo, hi in runs:
                indices = [i for i, (a, b) in enumerate(zip(peaks, peaks[1:])) if lo <= a < b < hi]
                for i, keep in zip(indices, malik_mask([censor["interval_values_ms"][i] for i in indices])):
                    malik[i] = keep
            methods = {"censor_only": {**censor, "correction_fraction": 0.0, "correction_events": []},
                       "malik_20pct": {**interval_metrics(peaks, rate, runs, malik), "correction_fraction": 0.0, "correction_events": []}}
            correction_error = None
            try:
                require(len(peaks) >= 4, "insufficient_original_peaks")
                correction = lipponen_corrections(peaks, rate, runs, neurokit)
                affected = set(correction["affected_original_beats"])
                changed_intervals = [i for i, observed in enumerate(censor["observed_interval_mask"])
                                     if observed and (i in affected or i + 1 in affected)]
                fraction = len(changed_intervals) / sum(censor["observed_interval_mask"]) if any(censor["observed_interval_mask"]) else 0
                ledger = {"correction_fraction": fraction, "correction_fraction_denominator": "observed_original_intervals",
                          "affected_original_interval_indices": changed_intervals, "correction_events": correction["correction_events"],
                          "corrected_peak_samples": correction["corrected_peak_samples"],
                          "correction_event_count": correction["correction_event_count"]}
                methods["lipponen_observed"] = {**interval_metrics(peaks, rate, runs,
                    [i not in affected and i + 1 not in affected for i in range(max(0, len(peaks) - 1))]), **ledger}
                methods["lipponen_corrected_research"] = {**interval_metrics(correction["corrected_peak_samples"], rate, runs),
                    "pair_identity": "corrected_research_beats", **ledger}
            except Exception as error:
                correction_error = str(error)
                for name in METHODS[2:]:
                    methods[name] = {**censor, "rmssd_ms": None, "sdnn_ms": None, "correction_fraction": None,
                                     "correction_events": [], "unavailable_reason": "lipponen_unavailable"}
            windows.append({**common, "methods": methods, "lipponen_unavailable_detail": correction_error})
    provenance = runtime_provenance or {"status": "unverified_injected_backend", "activation_sha256": None,
                                        "environment_manifest_sha256": None}
    manifests = {name: {"schema_version": 1, "model_id": f"{VERSION}:{name}", "operational_status": "research_comparison",
        "publication_mode": "shadow", "canonical_outputs_allowed": False, "implementation_sha256": implementation_hash(),
        "runtime_provenance": provenance,
        "method": name, "reference_validation_status": "not_run", "modality": "preserved_per_recording",
        "malik_contract": "legacy300..2000ms_radius2_excluding_self20pct;original_pair_gap_mask"} for name in METHODS}
    sweeps = []
    for coverage in sorted(set(coverage_thresholds)):
        for limit in sorted(set(correction_limits)):
            for method in METHODS:
                predictions = []
                for window in windows:
                    metrics = window["methods"][method]
                    reason = metrics.get("unavailable_reason")
                    for failed, label in ((window["observed_duration_s"] / 300 < coverage, "observed_time_coverage"),
                            (window["maximum_gap_s"] > 30, "acquisition_gap"),
                            (metrics["valid_interval_fraction"] < 0.9, "valid_interval_fraction"),
                            (metrics["accepted_seconds"] / 300 < 0.8, "accepted_duration"),
                            (metrics["valid_pair_count"] < 20, "insufficient_eligible_pairs"),
                            (metrics["correction_fraction"] is not None and metrics["correction_fraction"] > limit, "correction_burden")):
                        if reason is None and failed:
                            reason = label
                    if reason is None and metrics["rmssd_ms"] is None:
                        reason = "insufficient_eligible_pairs"
                    predictions.append({"recording_id": window["recording_id"], "start_s": window["start_s"], "end_s": window["end_s"],
                        "input_start_s": window["start_s"], "input_end_s": window["end_s"], "metric": "rmssd_ms", "unit": "ms",
                        "value": metrics["rmssd_ms"] if reason is None else None, "abstention_reason": reason,
                        "confidence": None, "observed_duration_s": window["observed_duration_s"], "observed_spans": window["observed_spans"],
                        "correction_fraction": metrics["correction_fraction"], "measurement_valid": reason is None})
                sweeps.append({"method": method, "minimum_observed_fraction": coverage, "maximum_correction_fraction": limit,
                    "accepted_windows": sum(p["measurement_valid"] for p in predictions), "total_windows": len(predictions), "predictions": predictions})
    return {"schema_version": 1, "version": VERSION, "evidence_kind": data["evidence_kind"], "input_sha256": canonical_hash(data),
            "publication_mode": "shadow", "canonical_outputs_allowed": False, "reference_validation_status": "not_run",
            "runtime_provenance": provenance,
            "policy_status": "engineering_sweep_not_validated_cutoffs", "minimum_valid_interval_fraction": 0.9,
            "maximum_gap_s": 30, "minimum_accepted_duration_fraction": 0.8, "minimum_pairs": 20,
            "windows": windows, "comparison_manifests": manifests, "sweeps": sweeps}


def prediction_export(report, method, coverage, maximum_correction):
    selected = next((row for row in report["sweeps"] if row["method"] == method and
        row["minimum_observed_fraction"] == coverage and row["maximum_correction_fraction"] == maximum_correction), None)
    require(selected is not None, "requested sweep absent")
    manifest = {**report["comparison_manifests"][method], "minimum_observed_fraction": coverage,
                "maximum_correction_fraction": maximum_correction}
    recordings = {}
    for row in selected["predictions"]:
        recordings.setdefault(row["recording_id"], []).append({k: v for k, v in row.items() if k != "recording_id"})
    return {"schema_version": 1, "model_id": manifest["model_id"], "algorithm_version": VERSION,
            "model_manifest_sha256": canonical_hash(manifest), "computation_mode": "retrospective",
            "comparison_manifest": manifest, "source_comparison_sha256": canonical_hash(report),
            "recordings": [{"recording_id": key, "windows": value} for key, value in sorted(recordings.items())]}


def read_json(path):
    path = Path(path)
    require(path.stat().st_size <= 16 * 1024**2, "input file too large")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON key"); result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError("nonfinite JSON")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True); parser.add_argument("--activation", required=True)
    parser.add_argument("--asset-root", required=True); parser.add_argument("--output")
    parser.add_argument("--export-method", choices=METHODS)
    parser.add_argument("--coverage", type=float, default=0.9); parser.add_argument("--maximum-correction", type=float, default=0.1)
    args = parser.parse_args()
    try:
        data = validate_input(read_json(args.input)); activation = read_json(args.activation)
        validate_activation(activation, args.asset_root, "neurokit2")
        import neurokit2 as nk
        verify_loaded_package(nk, activation.get("package_tree_sha256"))
        result = compare(data, nk, runtime_provenance={"status": "validated_shadow_activation",
            "activation_sha256": canonical_hash(activation),
            "environment_manifest_sha256": activation["assets"]["environment_manifest"]["sha256"]})
        if args.export_method:
            result = prediction_export(result, args.export_method, args.coverage, args.maximum_correction)
        encoded = json.dumps(result, sort_keys=True, indent=2, allow_nan=False) + "\n"
        if args.output:
            with Path(args.output).open("x") as stream:
                stream.write(encoded)
        else:
            print(encoded, end="")
        return 0
    except (ValueError, OSError, ImportError) as error:
        print(f"correction-comparison: {error}", file=__import__("sys").stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
