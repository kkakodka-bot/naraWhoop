"""Metrics preserve abstention, duration and participant denominators."""

from __future__ import annotations

import math
import random
from collections import defaultdict
from statistics import mean, stdev

from .contracts import STAGES, number, require


def numeric(pairs: list[tuple[float, float]], within: float | None = None) -> dict:
    errors = [number(pred, "prediction") - number(ref, "reference") for ref, pred in pairs]
    output = {"n": len(errors), "bias": None, "mae": None, "rmse": None,
              "loa_lower": None, "loa_upper": None, "within_tolerance_fraction": None}
    if not errors:
        return output
    bias = mean(errors)
    output.update(bias=bias, mae=mean(abs(error) for error in errors),
                  rmse=math.sqrt(mean(error * error for error in errors)))
    if len(errors) > 1:
        spread = 1.96 * stdev(errors)
        output.update(loa_lower=bias - spread, loa_upper=bias + spread)
    if within is not None:
        require(number(within, "within tolerance") >= 0, "negative tolerance")
        output["within_tolerance_fraction"] = mean(abs(error) <= within for error in errors)
    return output


def classification(rows: list[tuple[str, str, dict | None]]) -> dict:
    confusion = [[0 for _ in STAGES] for _ in STAGES]
    abstentions = 0
    wake_total = sleep_total = wake_correct = sleep_correct = 0
    brier, log_losses, reliability = [], [], [[] for _ in range(10)]
    for actual, predicted, probabilities in rows:
        require(actual in STAGES, "unscored reference stage in classification")
        wake_total += actual == "wake"
        sleep_total += actual != "wake"
        wake_correct += actual == predicted == "wake"
        sleep_correct += actual != "wake" and predicted in ("light", "deep", "rem", "sleep_unstaged")
        if predicted not in STAGES:
            abstentions += 1
            continue
        confusion[STAGES.index(actual)][STAGES.index(predicted)] += 1
        if probabilities is not None:
            brier.append(sum((probabilities[key] - int(actual == key)) ** 2 for key in STAGES))
            log_losses.append(-math.log(max(probabilities[actual], 1e-15)))
            confidence = max(probabilities.values())
            chosen = max(STAGES, key=lambda key: probabilities[key])
            reliability[min(9, int(confidence * 10))].append((confidence, int(chosen == actual)))
    n = sum(map(sum, confusion))
    actual_n = [sum(row) for row in confusion]
    predicted_n = [sum(row[i] for row in confusion) for i in range(4)]
    stages = {}
    for i, stage in enumerate(STAGES):
        tp, a, p = confusion[i][i], actual_n[i], predicted_n[i]
        all_reference = sum(actual == stage for actual, _, _ in rows)
        stages[stage] = {"reference_n": a, "predicted_n": p, "all_reference_n": all_reference,
                         "recall_all_reference": tp / all_reference if all_reference else None,
                         "precision": tp / p if p else None, "recall": tp / a if a else None,
                         "f1": 2 * tp / (a + p) if a + p else None}
    accuracy = sum(confusion[i][i] for i in range(4)) / n if n else None
    chance = sum(a * p for a, p in zip(actual_n, predicted_n)) / (n * n) if n else None
    f1 = [row["f1"] for row in stages.values() if row["f1"] is not None]
    bins = [{"lower": i / 10, "upper": (i + 1) / 10, "n": len(bucket),
             "mean_confidence": mean(c for c, _ in bucket) if bucket else None,
             "accuracy": mean(a for _, a in bucket) if bucket else None}
            for i, bucket in enumerate(reliability)]
    return {"classes": list(STAGES), "confusion": confusion, "per_stage": stages,
            "confusion_scope": "accepted four-stage pairs; abstentions excluded, full-reference recall also reported",
            "reference_epochs": len(rows), "accepted_epochs": n, "abstained_epochs": abstentions,
            "accepted_coverage": n / len(rows) if rows else None,
            "accuracy": accuracy, "macro_f1_present_classes": mean(f1) if f1 else None,
            "macro_f1_four_classes": mean(row["f1"] for row in stages.values())
            if all(row["f1"] is not None for row in stages.values()) else None,
            "kappa": (accuracy - chance) / (1 - chance) if chance is not None and chance < 1 else None,
            "wake_specificity_all_reference": wake_correct / wake_total if wake_total else None,
            "sleep_sensitivity_all_reference": sleep_correct / sleep_total if sleep_total else None,
            "calibration": {"n": len(brier), "brier": mean(brier) if brier else None,
                            "log_loss": mean(log_losses) if log_losses else None, "reliability": bins,
                            "ece": sum(abs(row["mean_confidence"] - row["accuracy"]) * row["n"]
                                       for row in bins if row["n"]) / len(brier) if brier else None}}


def beat_agreement(reference_times: list[float], predicted_times: list[float], tolerance_s: float) -> dict:
    require(number(tolerance_s, "tolerance_s") > 0, "positive prespecified beat tolerance required")
    for times in (reference_times, predicted_times):
        require(all(math.isfinite(t) for t in times) and all(a < b for a, b in zip(times, times[1:])),
                "beat times must be finite and strictly increasing")
    i = j = 0
    pairs = []
    while i < len(reference_times) and j < len(predicted_times):
        error = predicted_times[j] - reference_times[i]
        if abs(error) <= tolerance_s:
            pairs.append((reference_times[i], predicted_times[j]))
            i += 1
            j += 1
        elif error < 0:
            j += 1
        else:
            i += 1
    return {"matching": "chronological_one_to_one_maximum_cardinality", "tolerance_s": tolerance_s,
            "reference_beats": len(reference_times), "predicted_beats": len(predicted_times),
            "matched_beats": len(pairs), "precision": len(pairs) / len(predicted_times) if predicted_times else None,
            "recall": len(pairs) / len(reference_times) if reference_times else None,
            "timing_error_seconds": numeric(pairs)}


def match_episodes(reference: list[dict], predictions: list[dict], minimum_iou: float) -> list[tuple[int, int]]:
    """Order-preserving optimum: maximize matches, then overlap. Episodes must not overlap."""
    require(0 <= number(minimum_iou, "minimum_iou") <= 1, "invalid episode IoU policy")
    n, m = len(reference), len(predictions)
    require(n * m <= 1_000_000, "episode matching resource limit exceeded")
    scores = [[(0, 0.0) for _ in range(m + 1)] for _ in range(n + 1)]
    moves = {}
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            best, move = scores[i - 1][j], (i - 1, j, False)
            if scores[i][j - 1] > best:
                best, move = scores[i][j - 1], (i, j - 1, False)
            a, b = reference[i - 1], predictions[j - 1]
            overlap = max(0.0, min(a["end_s"], b["end_s"]) - max(a["start_s"], b["start_s"]))
            union = max(a["end_s"], b["end_s"]) - min(a["start_s"], b["start_s"])
            if overlap > 0 and overlap / union >= minimum_iou:
                previous = scores[i - 1][j - 1]
                candidate = (previous[0] + 1, previous[1] + overlap)
                if candidate > best:
                    best, move = candidate, (i - 1, j - 1, True)
            scores[i][j], moves[i, j] = best, move
    result, i, j = [], n, m
    while i and j:
        a, b, matched = moves[i, j]
        if matched:
            result.append((i - 1, j - 1))
        i, j = a, b
    return list(reversed(result))


def opportunity_summary(epochs: list[dict], start_s: float, end_s: float, bed_entry_s=None) -> dict:
    sleep = sorted((max(row["start_s"], start_s), min(row["end_s"], end_s)) for row in epochs
                   if row["stage"] in ("light", "deep", "rem", "sleep_unstaged")
                   and row["start_s"] < end_s and row["end_s"] > start_s)
    tst = sum(b - a for a, b in sleep)
    onset, offset = (sleep[0][0], sleep[-1][1]) if sleep else (None, None)
    waso = sum(max(0, min(row["end_s"], offset) - max(row["start_s"], onset))
               for row in epochs if row["stage"] == "wake") if sleep else None
    known = sum(max(0, min(row["end_s"], end_s) - max(row["start_s"], start_s))
                for row in epochs if row["stage"] != "state_unknown")
    return {"tst_s": tst, "waso_s": waso, "onset_s": onset, "offset_s": offset,
            "latency_s": onset - bed_entry_s if onset is not None and bed_entry_s is not None else None,
            "unknown_s": max(0, end_s - start_s - known)}


def percentile(values: list[float], quantile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    low, high = math.floor(position), math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def participant_bootstrap(rows: list[dict], statistic, seed: int, replicates: int = 1000) -> dict:
    require(isinstance(replicates, int) and 10 <= replicates <= 10000, "bootstrap replicates outside [10,10000]")
    grouped = defaultdict(list)
    for row in rows:
        grouped[row["participant_id"]].append(row)
    participants = sorted(grouped)
    if len(participants) < 2:
        return {"participant_n": len(participants), "replicates": 0,
                "lower": None, "upper": None, "reason": "insufficient_participants"}
    rng, samples = random.Random(seed), []
    for _ in range(replicates):
        sample = [row for pid in rng.choices(participants, k=len(participants)) for row in grouped[pid]]
        value = statistic(sample)
        if value is not None and math.isfinite(value):
            samples.append(value)
    return {"participant_n": len(participants), "replicates": replicates,
            "defined_replicates": len(samples), "seed": seed, "unit": "participant",
            "lower": percentile(samples, 0.025), "upper": percentile(samples, 0.975)}
