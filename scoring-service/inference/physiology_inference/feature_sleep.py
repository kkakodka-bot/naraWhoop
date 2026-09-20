"""Compact supervised sleep challenger with training-only transforms and duration smoothing."""

from .contracts import Abstain, canonical_hash
import math
import re

LABELS = ("wake", "light", "deep", "rem")
FEATURES = ("hr_mean", "log_rmssd", "sdnn", "motion", "time_sin", "time_cos")


def _matrix(rows, means=None, scales=None):
    import numpy as np
    values = np.array([[row["features"].get(name, np.nan) for name in FEATURES] for row in rows], dtype=float)
    missing = ~np.isfinite(values)
    if means is None:
        means = np.array([np.mean(values[~missing[:, i], i]) if np.any(~missing[:, i]) else 0.0 for i in range(values.shape[1])])
        scales = np.array([max(np.std(values[~missing[:, i], i]), 1e-6) if np.any(~missing[:, i]) else 1.0 for i in range(values.shape[1])])
    filled = np.where(missing, means, values)
    return np.column_stack(((filled - means) / scales, missing.astype(float), np.ones(len(rows)))), means, scales


def _validate_rows(rows, require_labels=False):
    if not rows or len(rows) > 1000000:
        raise Abstain("feature_rows_invalid")
    seen = set(); acquisitions = {}; owners = {}; spans = {}
    for row in rows:
        if not row.get("participant") or not row.get("recording") or not isinstance(row.get("features"), dict):
            raise Abstain("feature_provenance_missing")
        source = row.get("source_recording_id"); digest = row.get("source_sha256", "")
        if not source or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise Abstain("feature_acquisition_provenance_missing")
        identity = (row["participant"], digest)
        if source in acquisitions and acquisitions[source] != identity or digest in owners and owners[digest] != row["participant"]:
            raise Abstain("feature_acquisition_alias")
        acquisitions[source] = identity; owners[digest] = row["participant"]
        if not all(isinstance(row.get(k), (int, float)) and math.isfinite(row[k]) for k in ("start", "end")):
            raise Abstain("feature_epoch_identity_invalid")
        key = (row["participant"], row["recording"], row["start"])
        if key in seen or row["end"] - row["start"] != 30:
            raise Abstain("feature_epoch_identity_invalid")
        seen.add(key)
        spans.setdefault(digest, []).append((row["start"], row["end"]))
        if require_labels and (row.get("label") not in LABELS or row.get("label_source") != "independent_psg"):
            raise Abstain("independent_psg_labels_required")
    for intervals in spans.values():
        ordered = sorted(intervals)
        if any(a[1] > b[0] for a, b in zip(ordered, ordered[1:])):
            raise Abstain("feature_acquisition_overlap")


def _evidence(row):
    features = row["features"]; coverage = row.get("evidence_coverage", {})
    hr = features.get("hr_mean"); motion = features.get("motion")
    if not isinstance(hr, (int, float)) or not math.isfinite(hr) or not 20 <= hr <= 240:
        return "qualified_hr_unavailable"
    if not isinstance(motion, (int, float)) or not math.isfinite(motion) or not 0 <= motion <= 4:
        return "qualified_motion_unavailable"
    if any(not isinstance(coverage.get(k), (int, float)) or not math.isfinite(coverage[k]) or
           not 0.9 <= coverage[k] <= 1 for k in ("hr", "motion")):
        return "joint_modality_coverage_insufficient"
    if row.get("quality_rejection_reasons"):
        return "signal_quality_rejected"
    return None


def fit(rows, training_participants, iterations=200, learning_rate=0.05, regularization=0.01):
    """Deterministic multinomial learner; callers supply person-disjoint PSG training rows only."""
    import numpy as np
    _validate_rows(rows, require_labels=True)
    if set(row["participant"] for row in rows) != set(training_participants):
        raise Abstain("training_participant_contract_mismatch")
    if not 1 <= iterations <= 10000 or not 0 < learning_rate <= 1 or regularization < 0:
        raise Abstain("training_configuration_invalid")
    if set(row["label"] for row in rows) != set(LABELS):
        raise Abstain("all_four_psg_classes_required")
    if any(_evidence(row) for row in rows):
        raise Abstain("training_joint_modality_evidence_required")
    ordered = sorted(rows, key=lambda r: (r["participant"], r["recording"], r["start"]))
    x, means, scales = _matrix(ordered)
    target = np.eye(4)[[LABELS.index(row["label"]) for row in ordered]]
    weights = np.zeros((x.shape[1], 4))
    for _ in range(iterations):
        logits = x @ weights; logits -= np.max(logits, axis=1, keepdims=True)
        probabilities = np.exp(logits); probabilities /= probabilities.sum(axis=1, keepdims=True)
        weights -= learning_rate * (x.T @ (probabilities - target) / len(x) + regularization * weights)
    transitions = np.ones((4, 4)); durations = [[] for _ in LABELS]
    run = 1
    for i, row in enumerate(ordered):
        index = LABELS.index(row["label"])
        adjacent = i > 0 and row["participant"] == ordered[i - 1]["participant"] and row["recording"] == ordered[i - 1]["recording"] and row["start"] == ordered[i - 1]["end"]
        if adjacent:
            previous = LABELS.index(ordered[i - 1]["label"]); transitions[previous, index] += 1
            if previous == index:
                run += 1
            else:
                durations[previous].append(run); run = 1
        elif i:
            durations[LABELS.index(ordered[i - 1]["label"])].append(run); run = 1
    durations[LABELS.index(ordered[-1]["label"])].append(run)
    transitions /= transitions.sum(axis=1, keepdims=True)
    model = {"version": "feature-softmax-duration-2", "labels": list(LABELS), "features": list(FEATURES),
             "means": means.tolist(), "scales": scales.tolist(), "weights": weights.tolist(),
             "transitions": transitions.tolist(), "duration_means": [float(np.mean(d)) if d else 1 for d in durations],
             "training_participants": sorted(training_participants), "training_hash": canonical_hash(ordered),
             "training_source_hashes": sorted({row["source_sha256"] for row in ordered}),
             "training_source_ids": sorted({row["source_recording_id"] for row in ordered}),
             "publication_mode": "shadow", "calibrated": False}
    model["model_hash"] = canonical_hash(model)
    return model


def calibrate(model, rows, development_participants):
    """Fit temperature only on explicitly disjoint development people; never infer held-out permission."""
    import copy
    import numpy as np
    _validate_rows(rows, require_labels=True)
    if set(row["participant"] for row in rows) != set(development_participants) or not development_participants:
        raise Abstain("calibration_participant_contract_mismatch")
    if set(development_participants) & set(model["training_participants"]) or any(
            row["source_sha256"] in model["training_source_hashes"] or row["source_recording_id"] in model["training_source_ids"] for row in rows):
        raise Abstain("calibration_training_overlap")
    if any(row.get("partition") != "development" or _evidence(row) for row in rows):
        raise Abstain("calibration_development_evidence_required")
    predict(model, rows, mode="causal")  # Validate the frozen checkpoint before fitting a new artifact.
    x, _, _ = _matrix(rows, np.array(model["means"]), np.array(model["scales"]))
    logits = x @ np.array(model["weights"])
    labels = np.array([LABELS.index(row["label"]) for row in rows])
    candidates = np.geomspace(0.25, 4.0, 81)
    def loss(temperature):
        z = logits / temperature; z -= z.max(axis=1, keepdims=True)
        return float(np.mean(np.log(np.exp(z).sum(axis=1)) - z[np.arange(len(z)), labels]))
    temperature = float(min(candidates, key=loss))
    result = copy.deepcopy(model)
    result.update({"calibrated": True, "calibration": {"method": "development-temperature-grid-1",
        "temperature": temperature, "participants": sorted(development_participants),
        "source_hashes": sorted({row["source_sha256"] for row in rows}), "input_hash": canonical_hash(rows),
        "scope": "emission_probabilities_not_duration_decoded_marginals", "reference_validation": "not_established"}})
    result["model_hash"] = canonical_hash({k: v for k, v in result.items() if k != "model_hash"})
    return result


def duration_decode(probabilities, transitions, duration_means, maximum_duration=120):
    """Explicit-duration Viterbi (geometric training-duration prior), whole-sequence retrospective."""
    import numpy as np
    p = np.asarray(probabilities, dtype=float); t = np.asarray(transitions, dtype=float)
    if p.ndim != 2 or p.shape[1] != 4 or not 1 <= maximum_duration <= 240 or np.any(p < 0) or not np.isfinite(p).all():
        raise Abstain("smoothing_input_invalid")
    n = len(p); prefix = np.vstack((np.zeros((1, 4)), np.cumsum(np.log(np.maximum(p, 1e-12)), axis=0)))
    dp = np.full((n + 1, 4), -np.inf); back = {}; dp[0] = 0
    for end in range(1, n + 1):
        for state in range(4):
            mean = max(1.001, duration_means[state]); stay = 1 - 1 / mean
            for length in range(1, min(end, maximum_duration) + 1):
                start = end - length
                likelihood = prefix[end, state] - prefix[start, state] + (length - 1) * np.log(stay) + np.log(1 / mean)
                previous_scores = dp[start] + np.log(np.maximum(t[:, state], 1e-12))
                if start:
                    previous_scores[state] = -np.inf
                previous = int(np.argmax(previous_scores)); score = previous_scores[previous] + likelihood
                if score > dp[end, state]:
                    dp[end, state] = score; back[(end, state)] = (start, previous)
    labels = [None] * n; state = int(np.argmax(dp[-1])); end = n
    while end:
        start, previous = back[(end, state)]
        labels[start:end] = [LABELS[state]] * (end - start); end = start; state = previous
    return labels


def predict(model, rows, mode="retrospective"):
    import numpy as np
    _validate_rows(rows)
    if model.get("model_hash") != canonical_hash({k: v for k, v in model.items() if k != "model_hash"}):
        raise Abstain("feature_model_hash_mismatch")
    if model.get("version") != "feature-softmax-duration-2" or model["features"] != list(FEATURES) or model["labels"] != list(LABELS):
        raise Abstain("feature_model_schema_mismatch")
    if mode not in ("causal", "retrospective"):
        raise Abstain("computation_mode_invalid")
    for key, shape in (("means", (6,)), ("scales", (6,)), ("weights", (13, 4)), ("transitions", (4, 4)), ("duration_means", (4,))):
        value = np.asarray(model.get(key), dtype=float)
        if value.shape != shape or not np.isfinite(value).all():
            raise Abstain("feature_model_parameters_invalid")
    if (np.any(np.array(model["scales"]) <= 0) or np.any(np.array(model["transitions"]) <= 0) or
            not np.allclose(np.array(model["transitions"]).sum(axis=1), 1, atol=1e-9, rtol=0) or
            np.any(np.array(model["duration_means"]) <= 0)):
        raise Abstain("feature_model_parameters_invalid")
    calibration = model.get("calibration", {})
    if model.get("calibrated") is not True and calibration:
        raise Abstain("feature_calibration_invalid")
    temperature = calibration.get("temperature", 1.0)
    if not isinstance(temperature, (int, float)) or not math.isfinite(temperature) or not 0.25 <= temperature <= 4:
        raise Abstain("feature_calibration_invalid")
    if model.get("calibrated") is True and (calibration.get("method") != "development-temperature-grid-1" or
            not calibration.get("participants") or set(calibration["participants"]) & set(model["training_participants"])):
        raise Abstain("feature_calibration_invalid")
    x, _, _ = _matrix(rows, np.array(model["means"]), np.array(model["scales"]))
    logits = (x @ np.array(model["weights"])) / temperature; logits -= logits.max(axis=1, keepdims=True)
    p = np.exp(logits); p /= p.sum(axis=1, keepdims=True)
    reasons = [_evidence(row) for row in rows]
    evidence = [reason is None for reason in reasons]
    labels = ["unknown"] * len(rows)
    # Never smooth across a gap, recording boundary, participant or input ordering reversal.
    starts = [0] + [i for i in range(1, len(rows)) if not evidence[i] or not evidence[i - 1] or rows[i]["participant"] != rows[i - 1]["participant"] or rows[i]["recording"] != rows[i - 1]["recording"] or rows[i]["start"] != rows[i - 1]["end"]] + [len(rows)]
    for lo, hi in zip(starts[:-1], starts[1:]):
        if not evidence[lo]:
            continue
        if mode == "retrospective":
            labels[lo:hi] = duration_decode(p[lo:hi], model["transitions"], model["duration_means"])
        else:
            # Causal path uses only this epoch's emissions, never whole-recording Viterbi.
            labels[lo:hi] = [LABELS[int(i)] for i in p[lo:hi].argmax(axis=1)]
    return {"probabilities": [row.tolist() if evidence[i] else None for i, row in enumerate(p)], "stages": labels, "computation_mode": mode,
            "calibrated": model.get("calibrated") is True, "calibration": calibration or None,
            "evidence_coverage": [row.get("evidence_coverage", {}) for row in rows], "abstention_reasons": reasons,
            "publication_mode": "shadow", "model_hash": model["model_hash"], "preprocess_version": "feature-softmax-duration-2"}
