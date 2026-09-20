"""Strict, versioned interchange for synchronized reference observations."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Any

STAGES = ("wake", "light", "deep", "rem")
STAGE_MAP = {"W": "wake", "N1": "light", "N2": "light", "N3": "deep", "R": "rem"}
STATES = STAGES + ("sleep_unstaged", "state_unknown")
METRIC_UNITS = {"rmssd_ms": "ms", "sdnn_ms": "ms", "respiratory_rate_bpm": "breaths/min"}
PRIMARY = {"ECG", "PSG", "airflow", "capnography", "validated_respiratory_effort"}


class ContractError(ValueError):
    pass


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise ContractError(reason)


def number(value: Any, name: str) -> float:
    require(not isinstance(value, bool) and isinstance(value, (int, float)), f"{name}: expected number")
    require(math.isfinite(value), f"{name}: nonfinite number")
    return float(value)


def identifier(value: Any, name: str) -> str:
    require(isinstance(value, str) and 0 < len(value) <= 256, f"{name}: missing/invalid identifier")
    return value


def digest(value: Any, name: str) -> str:
    require(isinstance(value, str) and len(value) == 64 and
            all(c in "0123456789abcdef" for c in value), f"{name}: expected SHA-256")
    return value


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False,
                      ensure_ascii=False).encode("utf-8")


def content_hash(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def file_hash(path: str | Path) -> str:
    result = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def load_json(path: str | Path, maximum_bytes: int = 64 * 1024 * 1024) -> dict:
    def pairs(items):
        output = {}
        for key, value in items:
            require(key not in output, f"duplicate JSON key: {key}")
            output[key] = value
        return output

    with Path(path).open("rb") as handle:
        raw = handle.read(maximum_bytes + 1)
    require(len(raw) <= maximum_bytes, "JSON exceeds size limit")
    try:
        value = json.loads(raw, object_pairs_hook=pairs,
                           parse_constant=lambda value: (_ for _ in ()).throw(ContractError(f"nonfinite JSON: {value}")))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ContractError(f"invalid JSON: {error}") from error
    require(isinstance(value, dict), "document must be an object")
    return value


def bounds(row: dict, outer: tuple[float, float] | None = None) -> tuple[float, float]:
    start, end = number(row.get("start_s"), "start_s"), number(row.get("end_s"), "end_s")
    require(start < end, "empty/reversed time interval")
    require(end - start <= 366 * 86400, "recording interval exceeds one-year resource limit")
    if outer:
        require(outer[0] <= start < end <= outer[1], "time interval outside recording")
    return start, end


def nonoverlapping(rows: list[dict], name: str) -> None:
    prior = -math.inf
    for row in sorted(rows, key=lambda item: item["start_s"]):
        start, end = bounds(row)
        require(start >= prior, f"overlapping {name}")
        prior = end


def union_duration(intervals: list[tuple[float, float]]) -> float:
    total, end = 0.0, -math.inf
    for start, stop in sorted(intervals):
        require(start <= stop, "reversed coverage interval")
        total += max(0.0, stop - max(start, end))
        end = max(end, stop)
    return total


def validate_dataset(data: dict) -> dict:
    require(data.get("schema_version") == 1, "unsupported reference schema")
    identifier(data.get("dataset_id"), "dataset_id")
    require(data.get("evidence_kind") in ("reference", "synthetic_functional"), "unknown evidence kind")
    participants = data.get("participants")
    require(isinstance(participants, list) and bool(participants), "participants required")
    ids = [identifier(row.get("id"), "participant id") for row in participants]
    require(len(set(ids)) == len(ids), "duplicate participant")
    for participant in participants:
        require(isinstance(participant.get("subgroups", {}), dict), "subgroups must be an object")
        for key, value in participant.get("subgroups", {}).items():
            identifier(key, "subgroup name")
            identifier(value, "subgroup value")
    recordings = data.get("recordings")
    require(isinstance(recordings, list) and bool(recordings), "recordings required")
    seen, source_owners, source_spans = set(), {}, {}
    for recording in recordings:
        rid = identifier(recording.get("id"), "recording id")
        identifier(recording.get("source_recording_id"), "original source recording id")
        require(rid not in seen, "duplicate recording")
        seen.add(rid)
        require(recording.get("participant_id") in ids, "unknown recording participant")
        outer = bounds(recording)
        reference = recording.get("reference", {})
        require(reference.get("modality") in PRIMARY, "vendor/model output is not a primary reference")
        source = recording["source_recording_id"]
        owner = recording["participant_id"]
        require(source_owners.get(source, owner) == owner, "original recording assigned to multiple participants")
        source_owners[source] = owner
        span_key = (source, reference["modality"])
        for prior_start, prior_end in source_spans.get(span_key, []):
            require(outer[0] >= prior_end or prior_start >= outer[1], "duplicated reference recording span")
        source_spans.setdefault(span_key, []).append(outer)
        identifier(reference.get("version"), "reference version")
        digest(reference.get("sha256"), "reference sha256")
        identifier(reference.get("license"), "reference data license")
        require(isinstance(reference.get("adjudicated"), bool), "adjudication status required")
        sync = reference.get("synchronization", {})
        identifier(sync.get("method"), "synchronization method")
        number(sync.get("offset_s"), "reference offset_s")
        require(number(sync.get("uncertainty_s"), "uncertainty_s") >= 0, "negative synchronization uncertainty")
        require(sync.get("applied") is True, "reference must already be aligned to sensor UTC")
        for field in ("epochs", "opportunities", "respiration", "opportunity_annotation_spans", "behavior_annotations", "window_annotations"):
            rows = recording.get(field, [])
            require(isinstance(rows, list), f"{field} must be an array")
            for row in rows:
                bounds(row, outer)
            if field != "respiration":
                nonoverlapping(rows, field)
        for field in ("opportunity_annotation_spans", "behavior_annotations", "window_annotations"):
            for annotation in recording.get(field, []):
                source = identifier(annotation.get("annotation_source"), "independent annotation source")
                require(source not in ("model", "vendor", "self_generated"), "model output cannot label evaluation strata")
                if field != "opportunity_annotation_spans":
                    require(isinstance(annotation.get("labels"), dict) and bool(annotation["labels"]), "annotation labels required")
                    for key, value in annotation["labels"].items():
                        identifier(key, "annotation label name")
                        identifier(value, "annotation label")
        for epoch in recording.get("epochs", []):
            require(reference["modality"] == "PSG", "stage labels require PSG")
            require(epoch.get("stage") in STAGES + tuple(STAGE_MAP) + ("unknown",), "invalid PSG stage")
            require(abs(epoch["end_s"] - epoch["start_s"] - 30) < 1e-6, "PSG epoch must be 30 seconds")
            require(isinstance(epoch.get("scorable"), bool), "PSG scorable flag required")
        for opportunity in recording.get("opportunities", []):
            require(reference["modality"] == "PSG", "opportunity comparison requires synchronized PSG")
            require(opportunity.get("type") in ("main_sleep", "nap", "other_sleep"), "invalid opportunity type")
            identifier(opportunity.get("annotation_source"), "independent opportunity annotation source")
            require(opportunity.get("annotation_source") not in ("model", "vendor", "self_generated"),
                    "model output cannot label opportunities")
            if opportunity.get("bed_entry_s") is not None:
                require(outer[0] <= number(opportunity["bed_entry_s"], "bed_entry_s") <= opportunity["start_s"],
                        "bed entry after sleep onset/outside recording")
            for boundary in ("sleep_onset_s", "final_wake_s"):
                if opportunity.get(boundary) is not None:
                    require(opportunity["start_s"] <= number(opportunity[boundary], boundary) <= opportunity["end_s"],
                            "sleep boundary outside opportunity")
        for row in recording.get("respiration", []):
            require(reference["modality"] in PRIMARY - {"ECG", "PSG"}, "unsupported respiratory reference")
            require(row.get("unit") == "breaths/min", "respiratory reference unit mismatch")
            require(number(row.get("value"), "respiratory rate") > 0, "invalid reference respiratory rate")
        respiratory_keys = [(row["start_s"], row["end_s"]) for row in recording.get("respiration", [])]
        require(len(respiratory_keys) == len(set(respiratory_keys)), "duplicate respiratory reference window")
        beats = recording.get("beats", [])
        require(isinstance(beats, list), "beats must be an array")
        last, beat_ids = -math.inf, set()
        for beat in beats:
            require(reference["modality"] == "ECG", "R peaks require ECG reference")
            bid = identifier(beat.get("id"), "beat id")
            require(bid not in beat_ids, "duplicate ECG beat identity")
            beat_ids.add(bid)
            t = number(beat.get("time_s"), "R peak time")
            require(outer[0] <= t < outer[1] and t > last, "ECG beats must be strictly ordered within recording")
            require(isinstance(beat.get("nn_eligible"), bool), "adjudicated NN eligibility required")
            last = t
        if reference["modality"] == "ECG":
            spans = recording.get("observed_spans")
            require(isinstance(spans, list), "ECG observed acquisition spans required")
            for span in spans:
                bounds(span, outer)
            nonoverlapping(spans, "ECG acquisition spans")
    return data


def validate_predictions(data: dict, dataset: dict) -> dict:
    require(data.get("schema_version") == 1, "unsupported prediction schema")
    identifier(data.get("model_id"), "model_id")
    identifier(data.get("algorithm_version"), "algorithm_version")
    digest(data.get("model_manifest_sha256"), "model manifest hash")
    require(data.get("computation_mode") in ("causal", "retrospective"), "computation mode required")
    records = {row["id"]: row for row in dataset["recordings"]}
    seen = set()
    require(isinstance(data.get("recordings"), list), "prediction recordings required")
    for record in data["recordings"]:
        rid = record.get("recording_id")
        require(rid in records and rid not in seen, "unknown/duplicate prediction recording")
        seen.add(rid)
        outer = bounds(records[rid])
        for field in ("windows", "epochs", "episodes"):
            require(isinstance(record.get(field, []), list), f"prediction {field} must be an array")
            for row in record.get(field, []):
                start, end = bounds(row, outer)
                input_start = number(row.get("input_start_s"), "input_start_s")
                input_end = number(row.get("input_end_s"), "input_end_s")
                require(input_start < input_end, "invalid model receptive field")
                require(outer[0] <= input_start < input_end <= outer[1], "receptive field outside declared recording")
                if data["computation_mode"] == "causal":
                    require(input_end <= end, "future context in causal output")
                if field != "episodes":
                    require(0 <= number(row.get("observed_duration_s"), "observed duration") <= end - start,
                            "invalid observed duration")
                    confidence = row.get("confidence")
                    require(confidence is None or 0 <= number(confidence, "confidence") <= 1,
                            "confidence outside [0,1]")
                    if "observed_spans" in row:
                        require(isinstance(row["observed_spans"], list), "observed spans must be an array")
                        for span in row["observed_spans"]:
                            bounds(span, (start, end))
                        nonoverlapping(row["observed_spans"], "prediction observation spans")
                        observed = sum(span["end_s"] - span["start_s"] for span in row["observed_spans"])
                        require(abs(observed - row["observed_duration_s"]) <= 1e-6, "observed duration/span mismatch")
            if field != "windows":
                nonoverlapping(record.get(field, []), f"prediction {field}")
        window_keys = set()
        for row in record.get("windows", []):
            name = row.get("metric")
            require(name in METRIC_UNITS and row.get("unit") == METRIC_UNITS[name], "metric/unit mismatch")
            key = (name, row["start_s"], row["end_s"])
            require(key not in window_keys, "duplicate prediction window")
            window_keys.add(key)
            if row.get("value") is None:
                identifier(row.get("abstention_reason"), "abstention reason")
            else:
                require(number(row["value"], "estimate") >= 0, "negative estimate")
                require(row["observed_duration_s"] > 0, "nonmissing estimate without observed input")
            correction = row.get("correction_fraction")
            require(correction is None or 0 <= number(correction, "correction fraction") <= 1,
                    "invalid cumulative correction fraction")
        for row in record.get("epochs", []):
            require(row.get("stage") in STATES, "unknown predicted state")
            require(abs(row["end_s"] - row["start_s"] - 30) < 1e-6, "prediction epoch must be 30 seconds")
            if row["stage"] in ("state_unknown", "sleep_unstaged"):
                identifier(row.get("abstention_reason"), "stage abstention reason")
            probabilities = row.get("probabilities")
            if probabilities is not None:
                require(set(probabilities) == set(STAGES), "four-stage probability vocabulary required")
                values = [number(probabilities[key], key) for key in STAGES]
                require(all(0 <= p <= 1 for p in values) and abs(sum(values) - 1) <= 1e-6,
                        "invalid probability simplex")
                require(row.get("probability_status") in ("calibrated", "uncalibrated"),
                        "probability calibration status required")
        for row in record.get("episodes", []):
            require(row.get("type") in ("main_sleep", "nap", "other_sleep", "uncertain"), "invalid episode type")
        times = record.get("beat_times_s", [])
        require(isinstance(times, list), "predicted beat times must be an array")
        last = -math.inf
        for value in times:
            value = number(value, "predicted beat time")
            require(outer[0] <= value < outer[1] and value > last, "predicted beat times must be strictly ordered within recording")
            last = value
    return data
