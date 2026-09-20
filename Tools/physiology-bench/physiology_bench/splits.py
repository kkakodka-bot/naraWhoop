"""Participant assignment precedes window generation; receptive fields are audited."""

from __future__ import annotations

import hashlib
import math
from statistics import median

from .contracts import content_hash, digest, number, require


def participant_split(participant_ids: list[str], seed: str,
                      fractions: tuple[float, float, float] = (0.6, 0.2, 0.2),
                      external_ids: tuple[str, ...] = ()) -> dict:
    require(len(set(participant_ids)) == len(participant_ids), "duplicate split participant")
    require(len(fractions) == 3 and all(0 < number(v, "split fraction") < 1 for v in fractions)
            and abs(sum(fractions) - 1) < 1e-9, "invalid split fractions")
    require(set(external_ids) <= set(participant_ids), "external participant absent from dataset")
    ranked = sorted(set(participant_ids) - set(external_ids),
                    key=lambda value: (hashlib.sha256(f"{seed}\0{value}".encode()).hexdigest(), value))
    require(len(ranked) >= 3, "need at least three nonexternal participants for three disjoint sets")
    train_n = max(1, min(len(ranked) - 2, math.floor(len(ranked) * fractions[0])))
    dev_n = max(1, min(len(ranked) - train_n - 1, math.floor(len(ranked) * fractions[1])))
    assignments = {pid: ("train" if i < train_n else "development" if i < train_n + dev_n else "test")
                   for i, pid in enumerate(ranked)}
    assignments.update({pid: "external" for pid in external_ids})
    return {"schema_version": 1, "seed": seed, "unit": "participant",
            "assignments": dict(sorted(assignments.items())), "fractions": list(fractions)}


def validate_split(split: dict, participants: set[str]) -> None:
    require(split.get("schema_version") == 1 and split.get("unit") == "participant", "participant split required")
    assignments = split.get("assignments", {})
    require(set(assignments) == participants, "split must cover exactly the reference participants")
    require(set(assignments.values()) <= {"train", "development", "test", "external"}, "unknown split")
    require({"train", "development", "test"} <= set(assignments.values()), "empty training/development/test split")


def purge_overlap(windows: list[dict], split: dict, embargo_s: float = 0) -> tuple[list[dict], list[dict]]:
    """Holdout wins: purge training context that shares any source recording with holdout.

    source_recording_id is the original acquisition ID, not a renamed export ID. This
    catches accidental duplicated recordings even when participant aliases differ.
    Participant reassignment is rejected rather than repaired by this purge.
    """
    require(number(embargo_s, "embargo_s") >= 0, "negative embargo")
    priority = {"train": 0, "development": 1, "test": 2, "external": 3}
    ids, checked = set(), []
    for window in windows:
        require(window["id"] not in ids, "duplicate window id")
        ids.add(window["id"])
        expected = split["assignments"].get(window["participant_id"])
        require(expected is not None and window["split"] == expected, "participant crosses split")
        require(bool(window.get("source_recording_id")), "source recording identity required")
        lo, hi = number(window["input_start_s"], "input_start_s"), number(window["input_end_s"], "input_end_s")
        require(lo < hi, "invalid context interval")
        checked.append(window)
    kept, purged = [], []
    for window in checked:
        conflicts = [other["id"] for other in checked
                     if priority[other["split"]] > priority[window["split"]]
                     and other["source_recording_id"] == window["source_recording_id"]
                     and window["input_start_s"] < other["input_end_s"] + embargo_s
                     and other["input_start_s"] < window["input_end_s"] + embargo_s]
        if conflicts:
            purged.append({"id": window["id"], "reason": "overlapping_heldout_receptive_field",
                           "conflicts": sorted(conflicts)})
        else:
            kept.append(window)
    return kept, purged


def fit_robust_scaler(rows: list[dict], split: dict, feature_names: list[str],
                      fit_partition: str = "train") -> dict:
    """Small auditable normalizer; labels and heldout rows are never accepted."""
    require(fit_partition in ("train", "development"), "cannot fit on heldout data")
    require(rows and feature_names and len(feature_names) == len(set(feature_names)), "empty/duplicate fit features")
    participants = set()
    for row in rows:
        pid = row["participant_id"]
        require(split["assignments"].get(pid) == fit_partition, "normalizer fit would leak heldout/other partition")
        participants.add(pid)
    parameters = {}
    for feature in feature_names:
        values = [number(row["features"].get(feature), feature) for row in rows]
        center = median(values)
        mad = median(abs(value - center) for value in values)
        parameters[feature] = {"median": center, "mad": mad, "scale": mad if mad > 0 else 1.0}
    return {"schema_version": 1, "method": "median_mad_unscaled", "fit_partition": fit_partition,
            "fit_participants": sorted(participants), "split_sha256": content_hash(split),
            "fit_rows_sha256": content_hash(rows), "parameters": parameters}


def transform(rows: list[dict], frozen: dict) -> list[dict]:
    return [{**row, "features": {key: (number(row["features"].get(key), key) - value["median"]) / value["scale"]
                                    for key, value in frozen["parameters"].items()}} for row in rows]


def audit_fit_artifacts(artifacts: list[dict], split: dict) -> dict:
    """Check provenance of every fitted preprocessing/selection component before holdout."""
    validate_split(split, set(split.get("assignments", {})))
    required = {"normalization", "thresholds", "calibration", "feature_selection", "model_selection"}
    require({row.get("component") for row in artifacts} == required and len(artifacts) == len(required),
            "fit audit must name each preprocessing/selection component exactly once")
    for artifact in artifacts:
        require(artifact.get("split_sha256") == content_hash(split), "fit artifact split mismatch")
        digest(artifact.get("implementation_sha256"), "fit implementation hash")
        if artifact.get("status") == "not_fitted":
            require(bool(artifact.get("reason")) and not artifact.get("participants"), "fixed component needs reason and no fit participants")
            continue
        require(artifact.get("status") == "fitted", "unknown component fit status")
        digest(artifact.get("fit_inputs_sha256"), "fit input hash")
        digest(artifact.get("frozen_parameters_sha256"), "frozen fit parameter hash")
        require(bool(artifact.get("participants")), "fit participant list missing")
        for pid in artifact["participants"]:
            require(split["assignments"].get(pid) in ("train", "development"), "heldout participant in fitting/selection")
    return {"schema_version": 1, "split_sha256": content_hash(split), "split": split, "artifacts": artifacts,
            "status": "provenance_passed", "limitation": "Input manifests must be backed by reproducible training logs; this audit cannot inspect arbitrary external training code."}
