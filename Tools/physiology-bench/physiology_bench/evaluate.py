"""Compare incumbent and challenger over the same reference participants/time."""

from __future__ import annotations

from collections import defaultdict
from statistics import mean, median

from . import VERSION
from .contracts import (STAGES, bounds, content_hash, number, require, union_duration,
                        validate_dataset, validate_predictions)
from .metrics import (beat_agreement, classification, match_episodes, numeric, opportunity_summary,
                      participant_bootstrap)
from .references import psg_epochs, scalar_windows
from .splits import purge_overlap, validate_split


def _numeric_report(rows: list[dict], metric: str, config: dict) -> dict:
    tolerance = 2.0 if metric == "respiratory_rate_bpm" else None
    report = {}
    for mode in ("native", "common"):
        report[mode] = {}
        for name in ("baseline", "candidate"):
            accepted = [row for row in rows if row[name] is not None and
                        (mode == "native" or row["baseline"] is not None and row["candidate"] is not None)]
            stats = numeric([(row["reference"], row[name]) for row in accepted], tolerance)
            stats["participants"] = sorted({row["participant_id"] for row in accepted})
            stats["participant_n"] = len(stats["participants"])
            by_recording, observed_by_recording = defaultdict(list), defaultdict(list)
            all_by_recording = defaultdict(list)
            for row in rows:
                all_by_recording[row["recording_id"]].append((row["start_s"], row["end_s"]))
            for row in accepted:
                by_recording[row["recording_id"]].append((row["start_s"], row["end_s"]))
                for span in row[f"{name}_observed_spans"] or []:
                    observed_by_recording[row["recording_id"]].append((span["start_s"], span["end_s"]))
            eligible = sum(union_duration(spans) for spans in all_by_recording.values())
            accepted_time = sum(union_duration(spans) for spans in by_recording.values())
            stats.update(eligible_reference_seconds=eligible, accepted_window_seconds=accepted_time,
                         accepted_coverage=accepted_time / eligible if eligible else None,
                         observed_window_seconds_sum=sum(row[f"{name}_observed_s"] for row in accepted),
                         observed_union_seconds=sum(union_duration(spans) for spans in observed_by_recording.values())
                         if all(row[f"{name}_observed_spans"] is not None for row in accepted) else None,
                         mean_correction_fraction=mean(row[f"{name}_correction"] for row in accepted
                             if row[f"{name}_correction"] is not None)
                         if any(row[f"{name}_correction"] is not None for row in accepted) else None)
            stats["mae_participant_ci"] = participant_bootstrap(
                accepted, lambda sample: numeric([(row["reference"], row[name]) for row in sample])["mae"],
                config["seed"], config["bootstrap_replicates"])
            report[mode][name] = stats
    common = [row for row in rows if row["baseline"] is not None and row["candidate"] is not None]
    report["common"]["participants"] = sorted({row["participant_id"] for row in common})
    report["common"]["participant_n"] = len(report["common"]["participants"])
    delta = lambda sample: mean(abs(row["candidate"] - row["reference"]) -
                                abs(row["baseline"] - row["reference"]) for row in sample) if sample else None
    report["common"]["candidate_minus_baseline_mae"] = delta(common)
    report["common"]["mae_difference_participant_ci"] = participant_bootstrap(
        common, delta, config["seed"], config["bootstrap_replicates"])
    a, b = report["native"]["candidate"]["accepted_coverage"], report["native"]["baseline"]["accepted_coverage"]
    report["native"]["candidate_minus_baseline_accepted_coverage"] = a - b if a is not None and b is not None else None
    # Thresholds are confidence operating points, not validated physiological cutoffs.
    report["risk_coverage"] = []
    for threshold in (0.0, 0.25, 0.5, 0.75, 0.9, 0.95, 1.0):
        retained = [row for row in rows if row["candidate"] is not None and
                    row["candidate_confidence"] is not None and row["candidate_confidence"] >= threshold]
        stats = numeric([(row["reference"], row["candidate"]) for row in retained], tolerance)
        eligible_by_recording, retained_by_recording = defaultdict(list), defaultdict(list)
        for row in rows:
            eligible_by_recording[row["recording_id"]].append((row["start_s"], row["end_s"]))
        for row in retained:
            retained_by_recording[row["recording_id"]].append((row["start_s"], row["end_s"]))
        eligible_s = sum(union_duration(spans) for spans in eligible_by_recording.values())
        accepted_s = sum(union_duration(spans) for spans in retained_by_recording.values())
        report["risk_coverage"].append({"confidence_threshold": threshold, "accepted_windows": len(retained),
                                        "reference_windows": len(rows), "coverage": len(retained) / len(rows) if rows else None,
                                        "accepted_time_coverage": accepted_s / eligible_s if eligible_s else None,
                                        "mae": stats["mae"]})
    # Each recording/night contributes one arithmetic mean of its eligible windows.
    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["participant_id"], row["recording_id"])].append(row)
    report["per_recording"] = []
    for (pid, rid), values in sorted(grouped.items()):
        summary = {"participant_id": pid, "recording_id": rid, "reference_windows": len(values)}
        for name in ("baseline", "candidate"):
            eligible = [row for row in values if row[name] is not None]
            summary[name] = {"reference_mean_common_time": mean(row["reference"] for row in eligible) if eligible else None,
                             "estimate_mean": mean(row[name] for row in eligible) if eligible else None,
                             "reference_median_common_time": median(row["reference"] for row in eligible) if eligible else None,
                             "estimate_median": median(row[name] for row in eligible) if eligible else None,
                             "accepted_windows": len(eligible)}
        report["per_recording"].append(summary)
    sleep_groups = defaultdict(list)
    for row in rows:
        if row.get("reference_context") == "sleep":
            sleep_groups[(row["participant_id"], row["recording_id"])].append(row)
    report["nightly_sleep_window_mean_error"] = {}
    report["nightly_sleep_window_median_error"] = {}
    for name in ("baseline", "candidate"):
        nightly = []
        nightly_medians = []
        for values in sleep_groups.values():
            accepted = [row for row in values if row[name] is not None]
            if accepted:
                nightly.append((mean(row["reference"] for row in accepted), mean(row[name] for row in accepted)))
                nightly_medians.append((median(row["reference"] for row in accepted), median(row[name] for row in accepted)))
        report["nightly_sleep_window_mean_error"][name] = numeric(nightly, tolerance)
        report["nightly_sleep_window_median_error"][name] = numeric(nightly_medians, tolerance)
    report["nightly_context_policy"] = "Entire 300-second window covered by independent PSG sleep; gaps/mixed context excluded."
    return report


def _stage_report(rows: list[dict], config: dict) -> dict:
    output = {}
    for scope in ("native", "common"):
        selected = rows if scope == "native" else [row for row in rows if
            row["candidate"]["stage"] in STAGES and row["baseline"]["stage"] in STAGES]
        output[scope] = {}
        for name in ("baseline", "candidate"):
            values = [(row["reference"], row[name]["stage"], row[name].get("probabilities")) for row in selected]
            result = classification(values)
            result["participants"] = sorted({row["participant_id"] for row in selected if row[name]["stage"] in STAGES})
            result["participant_n"] = len(result["participants"])
            result["probability_statuses"] = sorted(set(row[name].get("probability_status", "unavailable")
                                                        for row in selected))
            result["kappa_participant_ci"] = participant_bootstrap(selected, lambda sample: classification([
                (row["reference"], row[name]["stage"], None) for row in sample])["kappa"],
                config["seed"], config["bootstrap_replicates"])
            output[scope][name] = result
        for metric in ("kappa", "wake_specificity_all_reference", "sleep_sensitivity_all_reference", "accepted_coverage"):
            a, b = output[scope]["candidate"][metric], output[scope]["baseline"][metric]
            output[scope]["candidate_minus_baseline_" + metric] = a - b if a is not None and b is not None else None
        def kappa_difference(sample):
            values = [classification([(row["reference"], row[name]["stage"], None) for row in sample])["kappa"]
                      for name in ("baseline", "candidate")]
            return values[1] - values[0] if all(value is not None for value in values) else None
        output[scope]["kappa_difference_participant_ci"] = participant_bootstrap(
            selected, kappa_difference, config["seed"], config["bootstrap_replicates"])
        if scope == "common":
            output[scope]["participants"] = sorted({row["participant_id"] for row in selected})
            output[scope]["participant_n"] = len(output[scope]["participants"])
    # Use the same full scored-PSG denominator for both models. Missing confidence is
    # unavailable, never imputed from an uncalibrated probability or an absent prediction.
    output["risk_coverage"] = {"confidence_policy": "explicit_prediction_confidence_no_imputation"}
    for name in ("baseline", "candidate"):
        curve = []
        for threshold in (0.0, 0.25, 0.5, 0.75, 0.9, 0.95, 1.0):
            selected = [row for row in rows if row[name]["stage"] in STAGES and
                        row[name].get("confidence") is not None and row[name]["confidence"] >= threshold]
            accepted = {id(row) for row in selected}
            stats = classification([(row["reference"], row[name]["stage"] if id(row) in accepted else "state_unknown", None)
                                    for row in rows])
            curve.append({"confidence_threshold": threshold, "reference_epochs": len(rows),
                          "accepted_epochs": len(selected), "reference_seconds": len(rows) * 30,
                          "accepted_seconds": len(selected) * 30,
                          "accepted_time_coverage": len(selected) / len(rows) if rows else None,
                          "participant_n": len({row["participant_id"] for row in selected}),
                          "accuracy": stats["accuracy"],
                          "misclassification_risk": 1 - stats["accuracy"] if stats["accuracy"] is not None else None,
                          "kappa": stats["kappa"], "macro_f1_four_classes": stats["macro_f1_four_classes"],
                          "wake_specificity_all_reference": stats["wake_specificity_all_reference"],
                          "sleep_sensitivity_all_reference": stats["sleep_sensitivity_all_reference"]})
        output["risk_coverage"][name] = curve
    return output


def _episode_report(recordings: list[dict], predictions: dict, config: dict) -> dict:
    onset, offset, tst, waso, latency, participants = [], [], [], [], [], []
    ref_n = predicted_n = matched_n = naps = predicted_naps = matched_naps = 0
    total_seconds = unknown_seconds = 0.0
    unlabelled_predictions = unlabelled_opportunities = 0
    for recording in recordings:
        if recording["reference"]["modality"] != "PSG":
            continue
        opportunities = sorted(recording.get("opportunities", []), key=lambda row: row["start_s"])
        all_proposed = sorted([row for row in predictions.get(recording["id"], {}).get("episodes", [])
                           if row["type"] != "uncertain"], key=lambda row: row["start_s"])
        spans = [(row["start_s"], row["end_s"]) for row in recording.get("opportunity_annotation_spans", [])]
        def labelled(row):
            return union_duration([(max(start, row["start_s"]), min(end, row["end_s"]))
                                   for start, end in spans if start < row["end_s"] and end > row["start_s"]]) >= row["end_s"] - row["start_s"]
        reference = [row for row in opportunities if labelled(row)]
        proposed = [row for row in all_proposed if labelled(row)]
        unlabelled_predictions += len(all_proposed) - len(proposed)
        unlabelled_opportunities += len(opportunities) - len(reference)
        matches = match_episodes(reference, proposed, config["episode_minimum_iou"])
        ref_n += len(reference)
        predicted_n += len(proposed)
        matched_n += len(matches)
        naps += sum(row["type"] == "nap" for row in reference)
        predicted_naps += sum(row["type"] == "nap" for row in proposed)
        matched_naps += sum(reference[i]["type"] == proposed[j]["type"] == "nap" for i, j in matches)
        total_seconds += union_duration(spans)
        epochs = psg_epochs(recording)
        candidate_epochs = predictions.get(recording["id"], {}).get("epochs", [])
        for i, j in matches:
            summary = opportunity_summary(epochs, reference[i]["start_s"], reference[i]["end_s"])
            actual_onset = reference[i].get("sleep_onset_s", summary["onset_s"])
            actual_offset = reference[i].get("final_wake_s", summary["offset_s"])
            if actual_onset is not None:
                onset.append((actual_onset, proposed[j]["start_s"]))
            if actual_offset is not None:
                offset.append((actual_offset, proposed[j]["end_s"]))
        for opportunity in opportunities:
            args = (opportunity["start_s"], opportunity["end_s"], opportunity.get("bed_entry_s"))
            actual = opportunity_summary(epochs, *args)
            estimate = opportunity_summary(candidate_epochs, *args)
            unknown_seconds += estimate["unknown_s"]
            if actual["unknown_s"] > 0:
                continue
            for values, key in ((tst, "tst_s"), (waso, "waso_s"), (latency, "latency_s")):
                if actual[key] is not None and estimate[key] is not None:
                    values.append((actual[key], estimate[key]))
            participants.append({"participant_id": recording["participant_id"],
                                 "tst_error_s": estimate["tst_s"] - actual["tst_s"]})
    return {"reference_episodes": ref_n, "predicted_episodes": predicted_n, "matched_episodes": matched_n,
            "minimum_iou": config["episode_minimum_iou"],
            "precision": matched_n / predicted_n if predicted_n else None,
            "recall": matched_n / ref_n if ref_n else None,
            "false_episodes_per_24h": (predicted_n - matched_n) * 86400 / total_seconds if total_seconds else None,
            "independently_annotated_detection_seconds": total_seconds,
            "unlabelled_predictions_excluded": unlabelled_predictions,
            "unlabelled_opportunities_excluded": unlabelled_opportunities,
            "nap_precision": matched_naps / predicted_naps if predicted_naps else None,
            "nap_recall": matched_naps / naps if naps else None,
            "onset_seconds": numeric(onset), "offset_seconds": numeric(offset),
            "tst_seconds": numeric(tst), "waso_seconds": numeric(waso), "latency_seconds": numeric(latency),
            "unknown_opportunity_seconds": unknown_seconds,
            "tst_bias_participant_ci": participant_bootstrap(participants,
                lambda rows: mean(row["tst_error_s"] for row in rows) if rows else None,
                config["seed"], config["bootstrap_replicates"])}


def evaluate(dataset: dict, baseline: dict, candidate: dict, split: dict, config: dict,
             verified_reference_hashes: tuple[str, ...] = ()) -> dict:
    validate_dataset(dataset)
    validate_predictions(baseline, dataset)
    validate_predictions(candidate, dataset)
    validate_split(split, {row["id"] for row in dataset["participants"]})
    receptive_fields = [{"id": row["id"], "participant_id": row["participant_id"],
                         "source_recording_id": row["source_recording_id"],
                         "split": split["assignments"][row["participant_id"]],
                         "input_start_s": row["start_s"], "input_end_s": row["end_s"]}
                        for row in dataset["recordings"]]
    _, conflicts = purge_overlap(receptive_fields, split)
    require(not conflicts, "dataset has overlapping source context across participants/splits; purge before evaluation")
    require(config.get("partition") in ("development", "test", "external"), "evaluation partition required")
    require(0 < number(config.get("reference_minimum_observed_fraction"), "reference coverage policy") <= 1,
            "reference coverage policy must be prespecified")
    require(number(config.get("reference_maximum_gap_s"), "reference gap policy") >= 0, "negative reference gap policy")
    require(0 <= number(config.get("episode_minimum_iou"), "episode IoU") <= 1, "episode IoU must be prespecified")
    require(isinstance(config.get("seed"), int), "bootstrap seed required")
    require(isinstance(config.get("bootstrap_replicates"), int) and 10 <= config["bootstrap_replicates"] <= 10000,
            "invalid bootstrap replication count")
    recordings = [row for row in dataset["recordings"] if split["assignments"][row["participant_id"]] == config["partition"]]
    require(recordings, "no recordings in evaluation partition")
    prediction_sets = {"baseline": {row["recording_id"]: row for row in baseline["recordings"]},
                       "candidate": {row["recording_id"]: row for row in candidate["recordings"]}}
    scalar, stages, rejected_reference = defaultdict(list), [], []
    beats = []
    context_epochs = defaultdict(list)
    for recording in recordings:
        if recording["reference"]["modality"] == "PSG":
            context_epochs[recording["participant_id"]].extend(psg_epochs(recording))
    for recording in recordings:
        rid = recording["id"]
        if recording["reference"]["modality"] == "ECG":
            tolerance = number(config.get("beat_tolerance_s"), "prespecified beat timing tolerance")
            reference_times = [row["time_s"] for row in recording.get("beats", [])]
            beats.append({"participant_id": recording["participant_id"], "recording_id": rid,
                          **{name: beat_agreement(reference_times, predicted.get(rid, {}).get("beat_times_s", []), tolerance)
                             for name, predicted in prediction_sets.items()}})
        lookups = {name: {(row["metric"], row["start_s"], row["end_s"]): row
                         for row in predictions.get(rid, {}).get("windows", [])}
                   for name, predictions in prediction_sets.items()}
        for reference in scalar_windows(recording):
            duration = reference["end_s"] - reference["start_s"]
            if reference["value"] is None or reference["observed_duration_s"] / duration < config["reference_minimum_observed_fraction"] \
                    or reference["maximum_gap_s"] > config["reference_maximum_gap_s"]:
                rejected_reference.append({"recording_id": rid, "metric": reference["metric"],
                                           "start_s": reference["start_s"], "reason": "reference_quality_policy"})
                continue
            key = (reference["metric"], reference["start_s"], reference["end_s"])
            row = {"participant_id": recording["participant_id"], "recording_id": rid,
                   "start_s": reference["start_s"], "end_s": reference["end_s"], "reference": reference["value"]}
            row["strata"] = {f"{key}={value}" for annotation in recording.get("window_annotations", [])
                             if annotation["start_s"] <= reference["start_s"] and annotation["end_s"] >= reference["end_s"]
                             for key, value in annotation["labels"].items()}
            lo, hi = reference["start_s"], reference["end_s"]
            independent_sleep = [(max(lo, epoch["start_s"]), min(hi, epoch["end_s"]))
                                 for epoch in context_epochs[recording["participant_id"]]
                                 if epoch["stage"] in ("light", "deep", "rem")
                                 and epoch["start_s"] < hi and epoch["end_s"] > lo]
            row["reference_context"] = "sleep" if union_duration(independent_sleep) >= hi - lo else "mixed_or_unknown"
            for name, lookup in lookups.items():
                predicted = lookup.get(key, {})
                row[name] = predicted.get("value")
                row[f"{name}_observed_s"] = predicted.get("observed_duration_s", 0)
                row[f"{name}_observed_spans"] = predicted.get("observed_spans")
                row[f"{name}_confidence"] = predicted.get("confidence")
                row[f"{name}_correction"] = predicted.get("correction_fraction")
            scalar[reference["metric"]].append(row)
        if recording["reference"]["modality"] == "PSG":
            lookup = {name: {(row["start_s"], row["end_s"]): row for row in predictions.get(rid, {}).get("epochs", [])}
                      for name, predictions in prediction_sets.items()}
            for epoch in psg_epochs(recording):
                stages.append({"participant_id": recording["participant_id"], "recording_id": rid,
                               "behaviors": {f"{key}={value}" for annotation in recording.get("behavior_annotations", [])
                                              if annotation["start_s"] <= epoch["start_s"] and annotation["end_s"] >= epoch["end_s"]
                                              for key, value in annotation["labels"].items()},
                               "reference": epoch["stage"], **{name: values.get((epoch["start_s"], epoch["end_s"]),
                                   {"stage": "state_unknown"}) for name, values in lookup.items()}})
    groups = defaultdict(set)
    for participant in dataset["participants"]:
        for name, value in participant.get("subgroups", {}).items():
            groups[f"{name}={value}"].add(participant["id"])
    subgroups = {}
    for group, ids in sorted(groups.items()):
        matching = [row for row in recordings if row["participant_id"] in ids]
        if matching:
            subgroups[group] = {"participant_n": len({row["participant_id"] for row in matching}),
                               "numeric": {metric: _numeric_report([row for row in rows if row["participant_id"] in ids], metric, config)
                                           for metric, rows in scalar.items()},
                               "stages": _stage_report([row for row in stages if row["participant_id"] in ids], config)}
    primary_ready = dataset["evidence_kind"] == "reference" and all(
        row["reference"]["adjudicated"] and row["reference"]["sha256"] in verified_reference_hashes for row in recordings)
    return {"schema_version": 1, "harness_version": VERSION, "evidence_kind": dataset["evidence_kind"],
            "dataset_sha256": content_hash(dataset), "split_sha256": content_hash(split),
            "config_sha256": content_hash(config), "baseline_sha256": content_hash(baseline),
            "candidate_sha256": content_hash(candidate), "partition": config["partition"],
            "model_manifest_sha256": candidate["model_manifest_sha256"],
            "prediction_provenance": {name: {key: value[key] for key in ("model_id", "algorithm_version", "computation_mode", "model_manifest_sha256")}
                                      for name, value in (("baseline", baseline), ("candidate", candidate))},
            "reference_validation_ready": primary_ready and config["partition"] in ("test", "external"),
            "verified_reference_artifact_sha256": sorted(set(verified_reference_hashes)),
            "reference_provenance": [{"recording_id": row["id"], "modality": row["reference"]["modality"],
                                       "sha256": row["reference"]["sha256"],
                                       "adjudicated": row["reference"]["adjudicated"],
                                       "synchronization": row["reference"]["synchronization"],
                                       "label_uncertainty": row["reference"].get("label_uncertainty"),
                                       "scorer_agreement": row["reference"].get("scorer_agreement")}
                                      for row in recordings],
            "evaluated_participants": sorted({row["participant_id"] for row in recordings}),
            "evaluated_recordings": [row["id"] for row in recordings],
            "leakage_audit": {"unit": "participant", "overlap_conflicts": 0,
                              "recording_receptive_fields_sha256": content_hash(receptive_fields)},
            "reference_exclusions": rejected_reference,
            "beat_timing": beats,
            "numeric": {metric: _numeric_report(rows, metric, config) for metric, rows in sorted(scalar.items())},
            "window_strata": {label: {metric: _numeric_report([row for row in rows if label in row["strata"]], metric, config)
                                        for metric, rows in scalar.items()}
                              for label in sorted({label for rows in scalar.values() for row in rows for label in row["strata"]})},
            "stages": _stage_report(stages, config),
            "behavior_strata": {label: _stage_report([row for row in stages if label in row["behaviors"]], config)
                                for label in sorted({label for row in stages for label in row["behaviors"]})},
            "detection": {name: _episode_report(recordings, values, config) for name, values in prediction_sets.items()},
            "subgroups": subgroups,
            "limitations": ["Reference provenance and adjudication are supplied by the data custodian; this tool cannot certify them.",
                            "Limits of agreement are descriptive; confidence intervals resample participants, not epochs.",
                            "A prediction absent at the exact reference bounds is an abstention; no temporal interpolation is performed.",
                            "Clinical accuracy, target hardware and deployment are not established by functional fixtures."]}
