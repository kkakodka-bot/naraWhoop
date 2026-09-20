"""Reference adapters consume already synchronized, adjudicated observations."""

from __future__ import annotations

import math
from collections import defaultdict
from statistics import stdev

from .contracts import STAGE_MAP, bounds, require, union_duration


def ecg_windows(recording: dict, duration_s: int = 300) -> list[dict]:
    require(recording["reference"]["modality"] == "ECG", "ECG reference required")
    require(duration_s == 300, "primary HRV reference windows must be UTC-aligned 300 seconds")
    start, end = bounds(recording)
    beats = recording.get("beats", [])
    intervals = defaultdict(list)
    for previous, current in zip(beats, beats[1:]):
        observed = any(span["start_s"] <= previous["time_s"] < current["time_s"] <= span["end_s"]
                       for span in recording["observed_spans"])
        if previous["nn_eligible"] and current["nn_eligible"] and observed:
            window_start = math.floor(previous["time_s"] / duration_s) * duration_s
            if current["time_s"] < window_start + duration_s:
                intervals[window_start].append((previous["time_s"], current["time_s"],
                                                1000 * (current["time_s"] - previous["time_s"]),
                                                previous["id"], current["id"]))
    result = []
    first = math.ceil(start / duration_s) * duration_s
    for lo in range(first, math.floor(end - duration_s) + 1, duration_s):
        hi = lo + duration_s
        # A reference interval crossing a window edge remains outside that window.
        selected = intervals[lo]
        pairs = [(a, b) for a, b in zip(selected, selected[1:]) if a[4] == b[3]]
        covered = union_duration([(row[0], row[1]) for row in selected])
        spans = sorted((row[0], row[1]) for row in selected)
        cursor, maximum_gap = lo, 0.0
        for a, b in spans:
            maximum_gap = max(maximum_gap, a - cursor)
            cursor = max(cursor, b)
        maximum_gap = max(maximum_gap, hi - cursor)
        values = [row[2] for row in selected]
        common = {"start_s": lo, "end_s": hi, "unit": "ms", "observed_duration_s": covered,
                  "valid_pair_count": len(pairs), "maximum_gap_s": maximum_gap,
                  "reference_method": "adjudicated_ecg_original_nn",
                  "original_interval_ids": [[row[3], row[4]] for row in selected]}
        rmssd = math.sqrt(sum((a[2] - b[2]) ** 2 for a, b in pairs) / len(pairs)) if pairs else None
        result.extend([{**common, "metric": "rmssd_ms", "value": rmssd},
                       {**common, "metric": "sdnn_ms", "value": stdev(values) if len(values) >= 2 else None}])
    return result


def psg_epochs(recording: dict) -> list[dict]:
    require(recording["reference"]["modality"] == "PSG", "PSG reference required")
    return [{**epoch, "stage": STAGE_MAP.get(epoch["stage"], epoch["stage"])}
            for epoch in recording.get("epochs", []) if epoch["scorable"] and epoch["stage"] != "unknown"]


def respiratory_windows(recording: dict) -> list[dict]:
    require(recording["reference"]["modality"] in ("airflow", "capnography", "validated_respiratory_effort"),
            "synchronized respiratory reference required")
    return [{**row, "metric": "respiratory_rate_bpm", "observed_duration_s": row["end_s"] - row["start_s"],
             "maximum_gap_s": 0, "reference_method": recording["reference"]["modality"]}
            for row in recording.get("respiration", [])]


def scalar_windows(recording: dict) -> list[dict]:
    kind = recording["reference"]["modality"]
    if kind == "ECG":
        return ecg_windows(recording)
    if kind != "PSG":
        return respiratory_windows(recording)
    return []
