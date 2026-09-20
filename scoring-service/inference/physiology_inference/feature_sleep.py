"""Compact supervised sleep challenger with training-only transforms and duration smoothing."""

from .contracts import Abstain, canonical_hash

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
    seen = set()
    for row in rows:
        if not row.get("participant") or not row.get("recording") or not isinstance(row.get("features"), dict):
            raise Abstain("feature_provenance_missing")
        key = (row["participant"], row["recording"], row["start"])
        if key in seen or row["end"] - row["start"] != 30:
            raise Abstain("feature_epoch_identity_invalid")
        seen.add(key)
        if require_labels and (row.get("label") not in LABELS or row.get("label_source") != "independent_psg"):
            raise Abstain("independent_psg_labels_required")


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
    model = {"version": "feature-softmax-duration-1", "labels": list(LABELS), "features": list(FEATURES),
             "means": means.tolist(), "scales": scales.tolist(), "weights": weights.tolist(),
             "transitions": transitions.tolist(), "duration_means": [float(np.mean(d)) if d else 1 for d in durations],
             "training_participants": sorted(training_participants), "training_hash": canonical_hash(ordered),
             "publication_mode": "shadow", "calibrated": False}
    model["model_hash"] = canonical_hash(model)
    return model


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
    if model["features"] != list(FEATURES) or model["labels"] != list(LABELS):
        raise Abstain("feature_model_schema_mismatch")
    if mode not in ("causal", "retrospective"):
        raise Abstain("computation_mode_invalid")
    x, _, _ = _matrix(rows, np.array(model["means"]), np.array(model["scales"]))
    logits = x @ np.array(model["weights"]); logits -= logits.max(axis=1, keepdims=True)
    p = np.exp(logits); p /= p.sum(axis=1, keepdims=True)
    evidence = [any(np.isfinite(row["features"].get(name, np.nan)) for name in FEATURES[:4]) for row in rows]
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
            "calibrated": False, "publication_mode": "shadow", "model_hash": model["model_hash"]}
