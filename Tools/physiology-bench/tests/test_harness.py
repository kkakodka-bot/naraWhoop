"""Synthetic functional tests only. No patient or scientific evaluation evidence."""

import copy
import hashlib
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from physiology_bench.contracts import (ContractError, content_hash, load_json, union_duration,
                                        validate_dataset, validate_predictions)
from physiology_bench.evaluate import evaluate, _stage_report
from physiology_bench.manifests import validate_model
from physiology_bench.metrics import (beat_agreement, classification, match_episodes, numeric,
                                      opportunity_summary, participant_bootstrap)
from physiology_bench.promotion import freeze_policy, promotion_decision, sign, verify
from physiology_bench.references import ecg_windows, psg_epochs
from physiology_bench.splits import audit_fit_artifacts, fit_robust_scaler, participant_split, purge_overlap, transform

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


def synthetic_dataset():
    participants = [{"id": f"functional-{i}", "subgroups": {"fixture_group": "a" if i % 2 else "b"}}
                    for i in range(6)]
    recordings = []
    for participant in participants:
        rid = participant["id"] + "-resp"
        recordings.append({"id": rid, "source_recording_id": rid, "participant_id": participant["id"],
                           "start_s": 0, "end_s": 600,
                           "reference": {"modality": "capnography", "version": "synthetic-functional-v1",
                                         "sha256": "a" * 64, "license": "synthetic repository fixture",
                                         "adjudicated": False,
                                         "synchronization": {"method": "synthetic_same_clock", "offset_s": 0,
                                                             "uncertainty_s": 0, "applied": True}},
                           "respiration": [{"start_s": 0, "end_s": 300, "value": 12, "unit": "breaths/min"},
                                           {"start_s": 300, "end_s": 600, "value": 14, "unit": "breaths/min"}]})
    return {"schema_version": 1, "evidence_kind": "synthetic_functional", "dataset_id": "functional-tests-only",
            "participants": participants, "recordings": recordings}


def split_fixture():
    return {"schema_version": 1, "unit": "participant", "seed": "functional",
            "assignments": {f"functional-{i}": "train" if i < 2 else "development" if i < 4 else "test" for i in range(6)}}


def predictions(dataset, model="baseline"):
    records = []
    for recording in dataset["recordings"]:
        windows = []
        for row in recording.get("respiration", []):
            windows.append({"metric": "respiratory_rate_bpm", "unit": "breaths/min",
                            "start_s": row["start_s"], "end_s": row["end_s"], "input_start_s": row["start_s"],
                            "input_end_s": row["end_s"], "observed_duration_s": row["end_s"] - row["start_s"],
                            "confidence": 0.8, "correction_fraction": 0, "value": row["value"] + (1 if model == "baseline" else 0)})
        records.append({"recording_id": recording["id"], "windows": windows})
    return {"schema_version": 1, "model_id": model, "algorithm_version": "synthetic-only-v1",
            "model_manifest_sha256": "b" * 64, "computation_mode": "causal", "recordings": records}


def config():
    return {"partition": "test", "seed": 9, "bootstrap_replicates": 30,
            "reference_minimum_observed_fraction": 0.8, "reference_maximum_gap_s": 2,
            "episode_minimum_iou": 0.5}


def ecg_fixture():
    row = copy.deepcopy(synthetic_dataset()["recordings"][0])
    row["reference"]["modality"] = "ECG"
    row.pop("respiration")
    row["beats"] = [{"id": str(i), "time_s": i, "nn_eligible": True} for i in range(600)]
    row["observed_spans"] = [{"start_s": 0, "end_s": 600}]
    return row


def synthetic_psg_dataset():
    data = synthetic_dataset()
    for row in data["recordings"]:
        row.pop("respiration")
        row["reference"]["modality"] = "PSG"
        row["epochs"] = [{"start_s": t, "end_s": t + 30, "stage": "N2" if 120 <= t < 240 else "W",
                          "scorable": True} for t in range(0, 600, 30)]
        row["opportunities"] = [{"start_s": 120, "end_s": 240, "type": "nap",
                                  "annotation_source": "synthetic_functional_annotator"}]
        row["opportunity_annotation_spans"] = [{"start_s": 0, "end_s": 600,
                                                "annotation_source": "synthetic_functional_annotator"}]
        row["behavior_annotations"] = [{"start_s": 300, "end_s": 420, "labels": {"behavior": "reading"},
                                        "annotation_source": "synthetic_functional_annotator"}]
    return data


def synthetic_gate_payload():
    """In-memory gate simulation only, not an evaluation report or reference evidence."""
    split = split_fixture()
    artifacts = [{"component": component, "split_sha256": content_hash(split), "status": "not_fitted",
                  "implementation_sha256": "c" * 64, "reason": "synthetic fixed component", "participants": []}
                 for component in ("normalization", "thresholds", "calibration", "feature_selection", "model_selection")]
    audit = audit_fit_artifacts(artifacts, split)
    model = load_json(REPO / "models/manifests/neurokit2.json")
    model.update(model_id="SYNTHETIC_GATE_TEST_NOT_A_MODEL", operational_status="adapter_ready", blockers=[],
                 preprocessing_sha256="a" * 64, quality_policy_sha256="a" * 64, adapter_sha256="a" * 64,
                 dataset_rights_status="reviewed")
    for rights in model["licenses"].values():
        rights["status"] = "reviewed"
        rights["identifier"] = "synthetic-fixture-only"
        rights["evidence_url"] = "urn:synthetic-functional-gate-not-legal-review"
    model["resource_limits"].update(timeout_seconds=1, maximum_rss_bytes=1024, numerical_tolerance=0)
    criteria = [{"role": "primary_improvement", "path": "report/numeric/respiratory_rate_bpm/common/candidate_minus_baseline_mae", "operator": "<=", "limit": -0.1},
                {"role": "coverage_noninferiority", "path": "report/numeric/respiratory_rate_bpm/native/candidate_minus_baseline_accepted_coverage", "operator": ">=", "limit": 0},
                {"role": "subgroup_regression", "path": "report/subgroups/fixture=only/numeric/respiratory_rate_bpm/common/candidate_minus_baseline_mae", "operator": "<=", "limit": 0}]
    for name in ("p95_latency_ms", "maximum_rss_bytes", "cpu_seconds_per_record", "records_per_hour"):
        criteria.append({"role": "resource_budget", "path": "resources/" + name,
                         "operator": ">=" if name == "records_per_hour" else "<=", "limit": 1})
    policy = {"schema_version": 1, "policy_id": "SYNTHETIC_GATE_TEST_ONLY", "status": "frozen", "metric_family": "respiration",
              "frozen_at": "2026-01-01T00:00:00Z", "dataset_sha256": "a" * 64, "split_sha256": content_hash(split),
              "config_sha256": "b" * 64, "model_manifest_sha256": content_hash(model), "fit_audit_sha256": content_hash(audit),
              "minimum_participants": 2, "minimum_subgroup_participants": 2, "required_subgroups": ["fixture=only"],
              "requires_locked_phone_soak": True, "requires_actual_target_resources": True, "criteria": criteria}
    common = {"candidate_minus_baseline_mae": -1, "participant_n": 2,
              "participants": ["functional-4", "functional-5"],
              "mae_difference_participant_ci": {"participant_n": 2, "replicates": 30, "defined_replicates": 30,
                                                "unit": "participant", "lower": -1, "upper": -1}}
    report = {"reference_validation_ready": True, "evidence_kind": "reference", "partition": "test",
              "verified_reference_artifact_sha256": ["f" * 64],
              "reference_provenance": [{"sha256": "f" * 64, "adjudicated": True, "synchronization": {"applied": True}}],
              "evaluated_participants": ["functional-4", "functional-5"],
              "leakage_audit": {"overlap_conflicts": 0}, "numeric": {"respiratory_rate_bpm": {
                  "common": copy.deepcopy(common), "native": {"candidate_minus_baseline_accepted_coverage": 0}}},
              "subgroups": {"fixture=only": {"participant_n": 2, "numeric": {"respiratory_rate_bpm": {
                  "common": copy.deepcopy(common)}}}}}
    report.update({key: policy[key] for key in ("dataset_sha256", "split_sha256", "config_sha256", "model_manifest_sha256")})
    manifest = {"schema_version": 1, "policy_sha256": content_hash(policy), "evaluation_started_at": "2026-01-02T00:00:00Z",
                "report": report, "functional_gates_passed": True, "fit_audit": audit, "model_manifest": model,
                "evidence": {gate: {"status": "passed", "artifact_sha256": "e" * 64, "reviewer": "SYNTHETIC_TEST_ONLY"}
                             for gate in ("functional_gate_suite", "locked_phone_soak", "actual_target_resources", "reference_custodian_attestation")},
                "resources": {row["path"].split("/")[1]: 1 for row in criteria if row["role"] == "resource_budget"}}
    return policy, manifest


class ContractTests(unittest.TestCase):
    def test_dataset_accepts_explicit_synthetic_fixture(self):
        self.assertEqual(validate_dataset(synthetic_dataset())["evidence_kind"], "synthetic_functional")

    def test_vendor_reference_rejected(self):
        data = synthetic_dataset()
        data["recordings"][0]["reference"]["modality"] = "WHOOP"
        with self.assertRaisesRegex(ContractError, "primary reference"):
            validate_dataset(data)

    def test_unsupported_units_rejected(self):
        data = synthetic_dataset()
        data["recordings"][0]["respiration"][0]["unit"] = "Hz"
        with self.assertRaisesRegex(ContractError, "unit mismatch"):
            validate_dataset(data)

    def test_nonfinite_and_duplicate_json_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "data.json"
            for contents in ('{"x": NaN}', '{"x":1,"x":2}', '{"x":Infinity}'):
                path.write_text(contents)
                with self.assertRaises(ContractError):
                    load_json(path)

    def test_size_limit_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "data.json"
            path.write_text('{"x": "too large"}')
            with self.assertRaisesRegex(ContractError, "size limit"):
                load_json(path, maximum_bytes=4)

    def test_missing_sync_is_not_zero_offset(self):
        data = synthetic_dataset()
        del data["recordings"][0]["reference"]["synchronization"]["offset_s"]
        with self.assertRaises(ContractError):
            validate_dataset(data)

    def test_duplicate_beat_identity_rejected(self):
        data = synthetic_dataset()
        data["recordings"][0] = ecg_fixture()
        data["recordings"][0]["beats"][1]["id"] = "0"
        with self.assertRaisesRegex(ContractError, "duplicate ECG"):
            validate_dataset(data)

    def test_future_causal_context_rejected(self):
        data = synthetic_dataset()
        predicted = predictions(data)
        predicted["recordings"][0]["windows"][0]["input_end_s"] = 301
        with self.assertRaisesRegex(ContractError, "future context"):
            validate_predictions(predicted, data)
        predicted["computation_mode"] = "retrospective"
        validate_predictions(predicted, data)

    def test_duplicate_predictions_rejected(self):
        data = synthetic_dataset()
        predicted = predictions(data)
        predicted["recordings"][0]["windows"].append(copy.deepcopy(predicted["recordings"][0]["windows"][0]))
        with self.assertRaisesRegex(ContractError, "duplicate prediction"):
            validate_predictions(predicted, data)

    def test_zero_and_null_are_distinct(self):
        data = synthetic_dataset()
        predicted = predictions(data)
        window = predicted["recordings"][0]["windows"][0]
        window.update(metric="rmssd_ms", unit="ms", value=0)
        validate_predictions(predicted, data)
        window["value"] = None
        with self.assertRaisesRegex(ContractError, "abstention reason"):
            validate_predictions(predicted, data)

    def test_invalid_probability_simplex_rejected(self):
        data = synthetic_dataset()
        predicted = predictions(data)
        predicted["recordings"][0]["epochs"] = [{"start_s": 0, "end_s": 30, "input_start_s": 0,
            "input_end_s": 30, "observed_duration_s": 30, "stage": "light", "confidence": 0.9,
            "probabilities": {"wake": 0.8, "light": 0.8, "deep": 0, "rem": 0}, "probability_status": "uncalibrated"}]
        with self.assertRaisesRegex(ContractError, "simplex"):
            validate_predictions(predicted, data)


class SplitTests(unittest.TestCase):
    def test_split_independent_of_input_order(self):
        ids = [str(i) for i in range(20)]
        self.assertEqual(participant_split(ids, "frozen"), participant_split(list(reversed(ids)), "frozen"))

    def test_external_people_never_train(self):
        result = participant_split([str(i) for i in range(8)], "frozen", external_ids=("1", "2"))
        self.assertEqual(result["assignments"]["1"], "external")
        self.assertEqual(result["assignments"]["2"], "external")

    def test_too_small_split_rejected(self):
        with self.assertRaises(ContractError):
            participant_split(["a", "b"], "frozen")

    def test_training_fit_rejects_heldout_person(self):
        with self.assertRaisesRegex(ContractError, "leak"):
            fit_robust_scaler([{"participant_id": "functional-4", "features": {"hr": 50}}], split_fixture(), ["hr"])

    def test_constant_feature_scale_is_finite_and_frozen(self):
        rows = [{"participant_id": "functional-0", "features": {"hr": 50}},
                {"participant_id": "functional-1", "features": {"hr": 50}}]
        fit = fit_robust_scaler(rows, split_fixture(), ["hr"])
        test = [{"participant_id": "functional-4", "features": {"hr": 60}}]
        self.assertEqual(transform(test, fit)[0]["features"]["hr"], 10)
        self.assertEqual(fit["parameters"]["hr"]["median"], 50)

    def test_sequence_context_purged_not_just_output_overlap(self):
        windows = [{"id": "train", "participant_id": "functional-0", "split": "train",
                    "source_recording_id": "duplicated-original", "input_start_s": 0, "input_end_s": 310},
                   {"id": "heldout", "participant_id": "functional-4", "split": "test",
                    "source_recording_id": "duplicated-original", "input_start_s": 300, "input_end_s": 600}]
        kept, purged = purge_overlap(windows, split_fixture())
        self.assertEqual([row["id"] for row in kept], ["heldout"])
        self.assertEqual(purged[0]["id"], "train")

    def test_embargo_and_half_open_boundary(self):
        windows = [{"id": "train", "participant_id": "functional-0", "split": "train",
                    "source_recording_id": "source", "input_start_s": 0, "input_end_s": 300},
                   {"id": "test", "participant_id": "functional-4", "split": "test",
                    "source_recording_id": "source", "input_start_s": 300, "input_end_s": 600}]
        self.assertEqual(len(purge_overlap(windows, split_fixture())[0]), 2)
        self.assertEqual(len(purge_overlap(windows, split_fixture(), 1)[0]), 1)

    def test_participant_alias_split_is_rejected(self):
        with self.assertRaisesRegex(ContractError, "participant crosses"):
            purge_overlap([{"id": "bad", "participant_id": "functional-0", "split": "test",
                            "source_recording_id": "s", "input_start_s": 0, "input_end_s": 300}], split_fixture())


class ReferenceMetricTests(unittest.TestCase):
    def test_stage_risk_coverage_preserves_reference_denominator_and_both_models(self):
        rows = [{"participant_id": "p1", "reference": "wake",
                 "baseline": {"stage": "wake", "confidence": 0.8},
                 "candidate": {"stage": "light", "confidence": 0.5}},
                {"participant_id": "p2", "reference": "light",
                 "baseline": {"stage": "light", "confidence": 0.8},
                 "candidate": {"stage": "light", "confidence": 0.95}},
                {"participant_id": "p2", "reference": "deep",
                 "baseline": {"stage": "state_unknown"},
                 "candidate": {"stage": "state_unknown", "confidence": 1.0}}]
        report = _stage_report(rows, {"seed": 1, "bootstrap_replicates": 10})["risk_coverage"]
        full, selective = report["candidate"][0], report["candidate"][4]
        self.assertEqual(full["accepted_epochs"], 2)
        self.assertEqual(full["misclassification_risk"], 0.5)
        self.assertEqual(full["reference_seconds"], 90)
        self.assertEqual(selective["accepted_seconds"], 30)
        self.assertEqual(selective["accepted_time_coverage"], 1 / 3)
        self.assertEqual(selective["misclassification_risk"], 0)
        self.assertEqual(selective["wake_specificity_all_reference"], 0)
        self.assertEqual(report["baseline"][0]["misclassification_risk"], 0)

    def test_stage_risk_coverage_does_not_invent_missing_confidence_or_accuracy(self):
        rows = [{"participant_id": "p", "reference": "wake", **{name: {"stage": "wake",
            "probabilities": {"wake": 1, "light": 0, "deep": 0, "rem": 0}} for name in ("baseline", "candidate")}}]
        for values in (rows, []):
            report = _stage_report(values, {"seed": 1, "bootstrap_replicates": 10})["risk_coverage"]
            for point in report["candidate"]:
                self.assertEqual(point["accepted_epochs"], 0)
                self.assertIsNone(point["misclassification_risk"])
                self.assertIsNone(point["accuracy"])

    def test_ecg_true_zero_and_original_pair_count(self):
        windows = ecg_windows(ecg_fixture())
        self.assertEqual(windows[0]["value"], 0)
        self.assertEqual(windows[0]["valid_pair_count"], 298)
        self.assertEqual(windows[0]["observed_duration_s"], 299)
        self.assertEqual(windows[0]["maximum_gap_s"], 1)

    def test_rejected_middle_beat_removes_adjacent_intervals_and_pairs(self):
        row = ecg_fixture()
        row["beats"][150]["nn_eligible"] = False
        window = ecg_windows(row)[0]
        self.assertEqual(window["valid_pair_count"], 295)
        self.assertEqual(window["observed_duration_s"], 297)
        self.assertEqual(window["maximum_gap_s"], 2)
        self.assertEqual(window["value"], 0)

    def test_sparse_reference_window_is_not_full_coverage(self):
        row = ecg_fixture()
        row["beats"] = row["beats"][:3]
        window = ecg_windows(row)[0]
        self.assertEqual(window["observed_duration_s"], 2)
        self.assertEqual(window["maximum_gap_s"], 298)

    def test_reference_acquisition_gap_never_forms_nn_pair(self):
        row = ecg_fixture()
        row["observed_spans"] = [{"start_s": 0, "end_s": 100}, {"start_s": 200, "end_s": 600}]
        window = ecg_windows(row)[0]
        self.assertEqual(window["observed_duration_s"], 199)
        self.assertEqual(window["maximum_gap_s"], 100)
        self.assertEqual(window["valid_pair_count"], 197)

    def test_union_does_not_double_count(self):
        self.assertEqual(union_duration([(0, 10), (5, 15), (20, 25)]), 20)

    def test_numeric_hand_computed_errors(self):
        result = numeric([(10, 11), (10, 13)], within=2)
        self.assertEqual(result["bias"], 2)
        self.assertEqual(result["mae"], 2)
        self.assertAlmostEqual(result["rmse"], math.sqrt(5))
        self.assertAlmostEqual(result["loa_lower"], 2 - 1.96 * math.sqrt(2))
        self.assertEqual(result["within_tolerance_fraction"], 0.5)

    def test_undefined_metrics_are_null(self):
        self.assertIsNone(numeric([])["mae"])
        self.assertIsNone(numeric([(1, 1)])["loa_lower"])
        self.assertIsNone(classification([])["kappa"])

    def test_unknown_does_not_become_sleep(self):
        result = classification([("wake", "state_unknown", None), ("light", "sleep_unstaged", None)])
        self.assertEqual(result["accepted_epochs"], 0)
        self.assertEqual(result["wake_specificity_all_reference"], 0)
        self.assertEqual(result["sleep_sensitivity_all_reference"], 1)

    def test_four_stage_perfect_confusion_and_calibration(self):
        labels = ("wake", "light", "deep", "rem")
        result = classification([(stage, stage, {key: float(key == stage) for key in labels}) for stage in labels])
        self.assertEqual(result["kappa"], 1)
        self.assertEqual(result["macro_f1_four_classes"], 1)
        self.assertEqual(result["calibration"]["brier"], 0)

    def test_psg_mapping_keeps_n1_n2_combined(self):
        row = {"reference": {"modality": "PSG"}, "epochs": [
            {"stage": "N1", "scorable": True}, {"stage": "N2", "scorable": True},
            {"stage": "unknown", "scorable": False}]}
        self.assertEqual([epoch["stage"] for epoch in psg_epochs(row)], ["light", "light"])

    def test_beat_matching_is_one_to_one(self):
        result = beat_agreement([1, 2, 3], [1.01, 1.02, 3.01], 0.05)
        self.assertEqual(result["matched_beats"], 2)
        self.assertAlmostEqual(result["precision"], 2 / 3)

    def test_episode_matching_optimizes_count_before_overlap(self):
        reference = [{"start_s": 0, "end_s": 10}, {"start_s": 10, "end_s": 20}]
        predicted = [{"start_s": 0, "end_s": 2}, {"start_s": 2, "end_s": 20}]
        self.assertEqual(match_episodes(reference, predicted, 0), [(0, 0), (1, 1)])

    def test_tst_waso_and_gap_accounting(self):
        epochs = [{"start_s": 0, "end_s": 30, "stage": "light"},
                  {"start_s": 30, "end_s": 60, "stage": "wake"},
                  {"start_s": 60, "end_s": 90, "stage": "sleep_unstaged"}]
        result = opportunity_summary(epochs, 0, 120, 0)
        self.assertEqual(result["tst_s"], 60)
        self.assertEqual(result["waso_s"], 30)
        self.assertEqual(result["unknown_s"], 30)

    def test_bootstrap_unit_is_participant_and_repeatable(self):
        rows = [{"participant_id": "a", "x": 0}] * 100 + [{"participant_id": "b", "x": 10}]
        statistic = lambda values: sum(row["x"] for row in values) / len(values)
        first = participant_bootstrap(rows, statistic, 10, 100)
        self.assertEqual(first, participant_bootstrap(rows, statistic, 10, 100))
        self.assertEqual(first["participant_n"], 2)
        self.assertEqual(first["upper"], 10)
        self.assertEqual(first["lower"], 0)

    def test_one_participant_has_no_bootstrap_uncertainty_claim(self):
        result = participant_bootstrap([{"participant_id": "only"}], lambda rows: 1, 1, 20)
        self.assertEqual(result["reason"], "insufficient_participants")


class IntegrationTests(unittest.TestCase):
    def test_overlapping_respiratory_windows_use_time_union_for_coverage(self):
        data = synthetic_dataset()
        for row in data["recordings"]:
            row["respiration"] = [{"start_s": 0, "end_s": 120, "value": 12, "unit": "breaths/min"},
                                  {"start_s": 30, "end_s": 150, "value": 12, "unit": "breaths/min"}]
        candidate = predictions(data, "candidate")
        for record in candidate["recordings"]:
            for row in record["windows"]:
                row["observed_spans"] = [{"start_s": row["start_s"], "end_s": row["end_s"]}]
        result = evaluate(data, predictions(data), candidate, split_fixture(), config())["numeric"]["respiratory_rate_bpm"]
        self.assertEqual(result["native"]["candidate"]["accepted_window_seconds"], 300)
        self.assertEqual(result["native"]["candidate"]["observed_union_seconds"], 300)
        self.assertEqual(result["native"]["candidate"]["observed_window_seconds_sum"], 480)
        self.assertEqual(result["risk_coverage"][0]["accepted_time_coverage"], 1)

    def test_full_day_detection_nap_and_annotated_reading_false_episode(self):
        data = synthetic_psg_dataset()
        candidate = predictions(data, "candidate")
        for row in candidate["recordings"]:
            row["episodes"] = [{"start_s": 120, "end_s": 240, "input_start_s": 0, "input_end_s": 240, "type": "nap"},
                               {"start_s": 300, "end_s": 420, "input_start_s": 0, "input_end_s": 420, "type": "nap"}]
            row["epochs"] = [{"start_s": t, "end_s": t + 30, "input_start_s": t, "input_end_s": t + 30,
                              "observed_duration_s": 30, "confidence": None, "stage": "light"} for t in range(0, 600, 30)]
        report = evaluate(data, predictions(data), candidate, split_fixture(), config())
        detection = report["detection"]["candidate"]
        self.assertEqual(detection["recall"], 1)
        self.assertEqual(detection["precision"], 0.5)
        self.assertEqual(detection["nap_precision"], 0.5)
        self.assertEqual(detection["false_episodes_per_24h"], 144)
        self.assertEqual(report["behavior_strata"]["behavior=reading"]["native"]["candidate"]["wake_specificity_all_reference"], 0)
        self.assertEqual(detection["tst_seconds"]["mae"], 0)

    def test_unlabelled_background_does_not_prove_false_episode_rate(self):
        data = synthetic_psg_dataset()
        for row in data["recordings"]:
            row.pop("opportunity_annotation_spans")
        candidate = predictions(data, "candidate")
        candidate["recordings"][4]["episodes"] = [{"start_s": 300, "end_s": 420, "input_start_s": 0,
                                                    "input_end_s": 420, "type": "nap"}]
        result = evaluate(data, predictions(data), candidate, split_fixture(), config())["detection"]["candidate"]
        self.assertIsNone(result["false_episodes_per_24h"])
        self.assertIsNone(result["recall"])
        self.assertEqual(result["unlabelled_predictions_excluded"], 1)

    def test_reference_motion_strata_are_not_inferred_from_prediction(self):
        data = synthetic_dataset()
        data["recordings"][4]["window_annotations"] = [{"start_s": 0, "end_s": 300,
            "annotation_source": "synthetic_functional_annotator", "labels": {"motion": "high", "rate_range": "prespecified_fast"}}]
        result = evaluate(data, predictions(data), predictions(data, "candidate"), split_fixture(), config())
        self.assertEqual(result["window_strata"]["motion=high"]["respiratory_rate_bpm"]["native"]["candidate"]["n"], 1)

    def test_candidate_abstention_changes_native_coverage_not_common_comparison(self):
        data = synthetic_dataset()
        baseline, candidate = predictions(data), predictions(data, "candidate")
        window = candidate["recordings"][4]["windows"][1]
        window.update(value=None, abstention_reason="synthetic_dropout", observed_duration_s=0)
        report = evaluate(data, baseline, candidate, split_fixture(), config())
        result = report["numeric"]["respiratory_rate_bpm"]
        self.assertEqual(result["native"]["baseline"]["n"], 4)
        self.assertEqual(result["native"]["candidate"]["n"], 3)
        self.assertEqual(result["common"]["baseline"]["n"], 3)
        self.assertEqual(result["native"]["candidate"]["accepted_coverage"], 0.75)
        self.assertEqual(result["common"]["candidate_minus_baseline_mae"], -1)
        self.assertFalse(report["reference_validation_ready"])

    def test_missing_prediction_recording_counts_as_abstention(self):
        data = synthetic_dataset()
        candidate = predictions(data, "candidate")
        candidate["recordings"] = candidate["recordings"][:4]
        result = evaluate(data, predictions(data), candidate, split_fixture(), config())
        stats = result["numeric"]["respiratory_rate_bpm"]["native"]["candidate"]
        self.assertEqual(stats["accepted_coverage"], 0)
        self.assertIsNone(stats["mae"])

    def test_synthetic_cannot_be_reference_ready_even_when_adjudicated_flag_set(self):
        data = synthetic_dataset()
        for row in data["recordings"]:
            row["reference"]["adjudicated"] = True
        result = evaluate(data, predictions(data), predictions(data, "candidate"), split_fixture(), config())
        self.assertFalse(result["reference_validation_ready"])

    def test_subgroup_report_retains_insufficient_sample_status(self):
        data = synthetic_dataset()
        result = evaluate(data, predictions(data), predictions(data, "candidate"), split_fixture(), config())
        group = result["subgroups"]["fixture_group=a"]
        self.assertEqual(group["participant_n"], 1)
        self.assertEqual(group["numeric"]["respiratory_rate_bpm"]["native"]["candidate"]["mae_participant_ci"]["reason"],
                         "insufficient_participants")

    def test_duplicate_source_context_leak_rejected(self):
        data = synthetic_dataset()
        data["recordings"][4]["source_recording_id"] = data["recordings"][0]["source_recording_id"]
        with self.assertRaisesRegex(ContractError, "multiple participants"):
            evaluate(data, predictions(data), predictions(data, "candidate"), split_fixture(), config())

    def test_unverified_real_reference_bytes_cannot_be_ready(self):
        data = synthetic_dataset()
        data["evidence_kind"] = "reference"  # Corrupted declaration, still synthetic test-only data.
        for row in data["recordings"]:
            row["reference"]["adjudicated"] = True
        result = evaluate(data, predictions(data), predictions(data, "candidate"), split_fixture(), config())
        self.assertFalse(result["reference_validation_ready"])

    def test_fit_audit_rejects_heldout_calibration(self):
        split = split_fixture()
        artifacts = [{"component": component, "split_sha256": content_hash(split), "status": "not_fitted",
                      "implementation_sha256": "c" * 64, "reason": "fixed synthetic component", "participants": []}
                     for component in ("normalization", "thresholds", "calibration", "feature_selection", "model_selection")]
        self.assertEqual(audit_fit_artifacts(artifacts, split)["status"], "provenance_passed")
        artifacts[2].update(status="fitted", fit_inputs_sha256="d" * 64, frozen_parameters_sha256="e" * 64,
                            participants=["functional-4"])
        with self.assertRaisesRegex(ContractError, "heldout participant"):
            audit_fit_artifacts(artifacts, split)

    def test_promotion_policy_template_is_not_executable(self):
        with self.assertRaises(ContractError):
            freeze_policy(load_json(ROOT / "promotion-policy.template.json"))

    def test_hmac_tampering_and_untrusted_keys_rejected(self):
        secret = b"synthetic-functional-test-key-000000"
        envelope = sign({"schema_version": 1, "meaning": "functional"}, secret, "unit-test")
        keys = {hashlib.sha256(secret).hexdigest(): secret}
        self.assertEqual(verify(envelope, keys)["meaning"], "functional")
        with self.assertRaisesRegex(ContractError, "untrusted"):
            verify(envelope, {})
        envelope["payload"]["meaning"] = "tampered"
        with self.assertRaisesRegex(ContractError, "signature mismatch"):
            verify(envelope, keys)

    def test_signature_authenticates_signer_identity(self):
        secret = b"synthetic-functional-test-key-000000"
        envelope = sign({"meaning": "synthetic"}, secret, "unit-test")
        envelope["signature"]["signer"] = "different-reviewer"
        with self.assertRaisesRegex(ContractError, "signature mismatch"):
            verify(envelope, {hashlib.sha256(secret).hexdigest(): secret})

    def test_frozen_policy_cannot_call_degradation_improvement(self):
        policy, _ = synthetic_gate_payload()
        policy["criteria"][0]["limit"] = 1
        with self.assertRaisesRegex(ContractError, "strict improvement"):
            freeze_policy(policy)

    def test_sleep_policy_requires_detection_not_only_preselected_staging(self):
        policy, _ = synthetic_gate_payload()
        policy["metric_family"] = "sleep"
        with self.assertRaises(ContractError):
            freeze_policy(policy)

    def test_policy_rejects_other_family_coverage_and_subgroup_metrics(self):
        for index, path in ((1, "report/stages/native/candidate_minus_baseline_accepted_coverage"),
                            (2, "report/subgroups/fixture=only/numeric/rmssd_ms/common/candidate_minus_baseline_mae")):
            policy, _ = synthetic_gate_payload()
            policy["criteria"][index]["path"] = path
            with self.assertRaisesRegex(ContractError, "feature's"):
                freeze_policy(policy)

    def test_qualified_feature_counts_exclude_other_modality_and_missing_predictions(self):
        data = synthetic_dataset()
        other = data["recordings"][-1]
        other["reference"]["modality"] = "PSG"
        del other["respiration"]
        other["epochs"] = [{"start_s": 0, "end_s": 30, "stage": "N2", "scorable": True}]
        report = evaluate(data, predictions(data), predictions(data, "candidate"), split_fixture(), config())
        common = report["numeric"]["respiratory_rate_bpm"]["common"]
        self.assertEqual(len(report["evaluated_participants"]), 2)
        self.assertEqual(common["participants"], ["functional-4"])
        self.assertEqual(common["participant_n"], 1)
        self.assertEqual(common["mae_difference_participant_ci"]["reason"], "insufficient_participants")
        data = synthetic_dataset()
        candidate = predictions(data, "candidate")
        candidate["recordings"][-1]["windows"] = []
        report = evaluate(data, predictions(data), candidate, split_fixture(), config())
        self.assertEqual(report["numeric"]["respiratory_rate_bpm"]["common"]["participant_n"], 1)

    def test_reference_quality_rejections_do_not_pad_hrv_participants(self):
        data = synthetic_dataset()
        for row in data["recordings"]:
            row["reference"]["modality"] = "ECG"
            del row["respiration"]
            row["beats"] = [{"id": str(i), "time_s": i, "nn_eligible": row["participant_id"] != "functional-5"}
                            for i in range(600)]
            row["observed_spans"] = [{"start_s": 0, "end_s": 600}]
        baseline = predictions(data)
        for row in baseline["recordings"]:
            row["windows"] = [{"metric": "rmssd_ms", "unit": "ms", "start_s": t, "end_s": t + 300,
                               "input_start_s": t, "input_end_s": t + 300, "observed_duration_s": 300,
                               "confidence": None, "value": 0} for t in (0, 300)]
        settings = {**config(), "beat_tolerance_s": 0.05}
        report = evaluate(data, baseline, baseline, split_fixture(), settings)
        self.assertEqual(len(report["evaluated_participants"]), 2)
        self.assertEqual(report["numeric"]["rmssd_ms"]["common"]["participant_n"], 1)
        self.assertTrue(report["reference_exclusions"])

    def test_gate_requires_qualified_heldout_participants_and_paired_uncertainty(self):
        secret = b"synthetic-functional-test-key-000000"
        keys = {hashlib.sha256(secret).hexdigest(): secret}
        def check(manifest):
            return promotion_decision(sign(policy, secret, "fixture"), sign(manifest, secret, "fixture"), keys)
        for scope in ("overall", "subgroup"):
            for failure in ("one_participant", "training_participant", "undefined_uncertainty"):
                policy, manifest = synthetic_gate_payload()
                report = manifest["report"] if scope == "overall" else manifest["report"]["subgroups"]["fixture=only"]
                common = report["numeric"]["respiratory_rate_bpm"]["common"]
                if failure == "one_participant":
                    common.update(participant_n=1, participants=["functional-4"])
                elif failure == "training_participant":
                    common["participants"][0] = "functional-0"
                else:
                    common["mae_difference_participant_ci"]["lower"] = None
                with self.subTest(scope=scope, failure=failure):
                    self.assertEqual(check(manifest)["decision"], "NOT_READY")

    def test_gate_simulation_never_enables_publication_and_missing_evidence_fails(self):
        policy, manifest = synthetic_gate_payload()
        secret = b"synthetic-functional-test-key-000000"
        keys = {hashlib.sha256(secret).hexdigest(): secret}
        check = lambda p, m: promotion_decision(sign(p, secret, "synthetic-test"), sign(m, secret, "synthetic-test"), keys)
        self.assertEqual(check(policy, manifest)["decision"], "ELIGIBLE_FOR_HUMAN_REVIEW")
        self.assertFalse(check(policy, manifest)["canonical_publication_enabled"])
        for gate in manifest["evidence"]:
            changed = copy.deepcopy(manifest)
            del changed["evidence"][gate]
            self.assertEqual(check(policy, changed)["decision"], "NOT_READY")
        changed = copy.deepcopy(manifest)
        changed["evaluation_started_at"] = "2025-01-01T00:00:00Z"
        self.assertEqual(check(policy, changed)["decision"], "NOT_READY")
        changed = copy.deepcopy(manifest)
        changed["resources"]["p95_latency_ms"] = 2
        self.assertIn("criterion failed", " ".join(check(policy, changed)["reasons"]))
        changed = copy.deepcopy(manifest)
        del changed["fit_audit"]
        self.assertEqual(check(policy, changed)["decision"], "NOT_READY")
        changed = copy.deepcopy(manifest)
        changed["model_manifest"]["operational_status"] = "metadata_only"
        self.assertEqual(check(policy, changed)["decision"], "NOT_READY")

    def test_resource_limits_are_required_for_model_execution(self):
        _, manifest = synthetic_gate_payload()
        model = manifest["model_manifest"]
        validate_model(model, for_execution=True)
        model["resource_limits"]["timeout_seconds"] = None
        with self.assertRaises(ContractError):
            validate_model(model, for_execution=True)

    def test_cgroup_memory_requires_explicit_frozen_metric_and_matching_accounting(self):
        policy, manifest = synthetic_gate_payload()
        secret = b"synthetic-functional-test-key-000000"
        keys = {hashlib.sha256(secret).hexdigest(): secret}
        check = lambda p, m: promotion_decision(sign(p, secret, "synthetic-test"), sign(m, secret, "synthetic-test"), keys)
        policy["memory_resource_metric"] = "process_tree_memory_peak_bytes"
        for criterion in policy["criteria"]:
            if criterion["path"] == "resources/maximum_rss_bytes":
                criterion["path"] = "resources/process_tree_memory_peak_bytes"
        manifest["policy_sha256"] = content_hash(policy)
        manifest["resources"].pop("maximum_rss_bytes")
        manifest["resources"]["process_tree_memory_peak_bytes"] = 1
        manifest["resource_accounting"] = {"method": "dedicated_cgroup_v2_process_tree",
            "memory_semantics": "kernel_cgroup_lifetime_charged_memory_peak", "dedicated_scope_checked": True}
        result = check(policy, manifest)
        self.assertEqual(result["decision"], "ELIGIBLE_FOR_HUMAN_REVIEW")
        self.assertFalse(result["canonical_publication_enabled"])
        for field, value in (("method", "python_worker_rusage"), ("dedicated_scope_checked", False),
                             ("memory_semantics", "single_worker_peak_rss")):
            changed = copy.deepcopy(manifest); changed["resource_accounting"][field] = value
            self.assertEqual(check(policy, changed)["decision"], "NOT_READY")
        changed = copy.deepcopy(manifest); changed["resources"]["process_tree_memory_peak_bytes"] = 2
        self.assertEqual(check(policy, changed)["decision"], "NOT_READY")
        changed = copy.deepcopy(manifest); changed["resources"]["process_tree_memory_peak_bytes"] = None
        self.assertEqual(check(policy, changed)["decision"], "NOT_READY")
        implicit = copy.deepcopy(policy); implicit.pop("memory_resource_metric")
        changed = copy.deepcopy(manifest); changed["policy_sha256"] = content_hash(implicit)
        self.assertEqual(check(implicit, changed)["decision"], "NOT_READY")
        rss_policy, rss_manifest = synthetic_gate_payload()
        rss_manifest["resource_accounting"] = manifest["resource_accounting"]
        self.assertEqual(check(rss_policy, rss_manifest)["decision"], "NOT_READY")
        rss_manifest["resource_accounting"] = {"method": "python_worker_rusage", "memory_semantics": "single_worker_peak_rss"}
        self.assertEqual(check(rss_policy, rss_manifest)["decision"], "ELIGIBLE_FOR_HUMAN_REVIEW")

    def test_execution_rights_need_evidence_or_explicit_nonapplicability(self):
        for kind in ("code", "weights", "training_data"):
            for field in ("identifier", "evidence_url"):
                _, manifest = synthetic_gate_payload()
                manifest["model_manifest"]["licenses"][kind][field] = None
                with self.subTest(kind=kind, field=field), self.assertRaisesRegex(ContractError, "reviewed rights require"):
                    validate_model(manifest["model_manifest"], for_execution=True)
        _, manifest = synthetic_gate_payload()
        model = manifest["model_manifest"]
        model["licenses"]["weights"].update(status="not_applicable")
        with self.assertRaisesRegex(ContractError, "require a reason"):
            validate_model(model, for_execution=True)
        model["licenses"]["weights"]["reason"] = "Synthetic deterministic model has no learned checkpoint"
        validate_model(model, for_execution=True)
        model["weights_required"] = True
        with self.assertRaisesRegex(ContractError, "required weights"):
            validate_model(model, for_execution=True)

    def test_missing_all_promotion_evidence_is_not_ready(self):
        result = promotion_decision({}, {}, {})
        self.assertEqual(result["decision"], "NOT_READY")
        self.assertFalse(result["canonical_publication_enabled"])

    def test_all_candidates_have_valid_manifests_and_metadata_only_cannot_execute(self):
        files = sorted((REPO / "models" / "manifests").glob("*.json"))
        models = [path for path in files if not path.name.endswith("schema.json")]
        required = {"feature-sleep-learner", "wav2sleep-cardiorespiratory", "walch-sleep-classifiers", "sleepecg",
                    "rr-estimation", "correncoder", "rrest", "neurokit2"}
        self.assertTrue(required <= {path.stem for path in models})
        for path in models:
            manifest = load_json(path)
            validate_model(manifest)
            if manifest["operational_status"] == "metadata_only":
                with self.assertRaisesRegex(ContractError, "metadata only"):
                    validate_model(manifest, for_execution=True)

    def test_cli_evaluation_is_serializable_and_missing_evidence_stays_not_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            data = synthetic_dataset()
            documents = {"dataset": data, "baseline": predictions(data), "candidate": predictions(data, "candidate"),
                         "split": split_fixture(), "config": config(), "policy": load_json(ROOT / "promotion-policy.template.json")}
            command = [sys.executable, str(ROOT / "bench.py"), "evaluate"]
            for name, document in documents.items():
                path = folder / (name + ".json")
                path.write_text(json.dumps(document))
                command += ["--" + name, str(path)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads(result.stdout)
            self.assertFalse(manifest["report"]["reference_validation_ready"])
            self.assertFalse(manifest["functional_gates_passed"])
            self.assertEqual(manifest["evidence"], {})
            secret = b"synthetic-functional-test-key-000000"
            keys = {hashlib.sha256(secret).hexdigest(): secret}
            decision = promotion_decision(sign(documents["policy"], secret, "test"), sign(manifest, secret, "test"), keys)
            self.assertEqual(decision["decision"], "NOT_READY")

    def test_cli_roundtrip_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            path, output = folder / "reference.json", folder / "split.json"
            path.write_text(json.dumps(synthetic_dataset()))
            command = [sys.executable, str(ROOT / "bench.py"), "split", "--dataset", str(path),
                       "--seed", "functional-test", "--output", str(output)]
            first = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(load_json(output)["unit"], "participant")
            again = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(again.returncode, 2)


if __name__ == "__main__":
    unittest.main()
