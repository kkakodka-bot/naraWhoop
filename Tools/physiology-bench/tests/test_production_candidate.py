"""Synthetic engineering regressions, never reference accuracy evidence."""

import copy
import hashlib
import hmac
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from physiology_bench.approval import create_approval
from physiology_bench.contracts import ContractError, canonical_bytes, content_hash, validate_predictions
from physiology_bench.evaluate import _nightly_report, evaluate
from physiology_bench.promotion import freeze_policy, promotion_decision, sign
from test_harness import (ROOT, config, predictions, split_fixture, synthetic_dataset,
                          synthetic_gate_payload, synthetic_psg_dataset)


EVALUATION_KEY = b"SYNTHETIC_ONLY_EVALUATION_KEY_00000000"
APPROVAL_KEY = b"SYNTHETIC_ONLY_APPROVAL_KEY_0000000000"
KEYS = {hashlib.sha256(EVALUATION_KEY).hexdigest(): EVALUATION_KEY}


def approval_fixture():
    policy, evaluation = synthetic_gate_payload()
    model = evaluation["model_manifest"]
    model.update(preprocessing_version="synthetic-preprocess-1", quality_policy_version="synthetic-quality-1")
    policy["model_manifest_sha256"] = content_hash(model)
    evaluation["report"]["model_manifest_sha256"] = content_hash(model)
    manifest = {"schema_version": 1, "algorithm_version": "synthetic-physiology-not-for-release",
                "feature": "respiration", "checkpoint_kind": "deterministic_source_not_learned_weights",
                "checkpoint_sha256": model["adapter_sha256"], "mode": "retrospective",
                **{key: model[key] for key in ("preprocessing_version", "quality_policy_version",
                                             "preprocessing_sha256", "quality_policy_sha256")}}
    registration = {**manifest, "manifest": manifest, "canonical_manifest": canonical_bytes(manifest).decode(),
                    "manifest_sha256": content_hash(manifest), "algorithm_manifest_sha256": "c" * 64}
    for key, value in (("feature_manifest_sha256", content_hash(manifest)), ("algorithm_manifest_sha256", "c" * 64)):
        policy[key] = evaluation[key] = value
    evaluation["report"]["prediction_provenance"] = {"candidate": {
        "algorithm_version": manifest["algorithm_version"], "computation_mode": "retrospective"}}
    evaluation["policy_sha256"] = content_hash(policy)
    approval = {"schema_version": 1, "decision": "approved", "reviewer": "SYNTHETIC_REVIEWER_ONLY",
                "approval_id": "00000000-0000-4000-8000-000000000001", "approved_at": "2026-01-03T00:00:00Z",
                "feature": "respiration", "algorithm_version": manifest["algorithm_version"],
                "manifest_sha256": content_hash(manifest), "policy_sha256": content_hash(policy),
                "evaluation_sha256": content_hash(evaluation)}
    return policy, evaluation, registration, approval


def approve(policy, evaluation, registration, approval, approval_key=APPROVAL_KEY):
    return create_approval(sign(policy, EVALUATION_KEY, "synthetic-evaluator"),
        sign(evaluation, EVALUATION_KEY, "synthetic-evaluator"), KEYS, registration, approval, approval_key)


class ApprovalTests(unittest.TestCase):
    def test_exact_utf8_signature_and_offline_only_result(self):
        result = approve(*approval_fixture())
        self.assertFalse(result["canonical_publication_enabled"])
        self.assertEqual(result["rpc"]["function"], "register_physiology_promotion")
        args = result["rpc"]["arguments"]
        expected = hmac.new(APPROVAL_KEY, args["p_payload"].encode("utf-8"), hashlib.sha256).hexdigest()
        self.assertEqual(args["p_signature"], expected)
        self.assertEqual(json.loads(args["p_payload"]), result["approval"])
        self.assertEqual(result["approval"]["reference_artifact_sha256"],
                         content_hash({"reference_artifact_sha256": ["f" * 64]}))

    def test_unqualified_evaluation_and_absent_human_approval_fail_closed(self):
        for mutation in ("functional", "draft", "no_approval", "wrong_evaluation", "future", "before_finish"):
            policy, evaluation, registration, approval = approval_fixture()
            if mutation == "functional":
                evaluation["functional_gates_passed"] = False
            elif mutation == "draft":
                policy["status"] = "draft"
            elif mutation == "no_approval":
                approval["decision"] = "pending"
            elif mutation == "wrong_evaluation":
                approval["evaluation_sha256"] = "d" * 64
            elif mutation == "future":
                approval["approved_at"] = "2099-01-01T00:00:00Z"
            else:
                approval["approved_at"] = "2026-01-01T00:00:00Z"
            with self.subTest(mutation=mutation), self.assertRaises(ContractError):
                approve(policy, evaluation, registration, approval)

    def test_checkpoint_preprocessing_quality_and_feature_isolation(self):
        for key in ("checkpoint_sha256", "preprocessing_sha256", "quality_policy_sha256",
                    "preprocessing_version", "quality_policy_version", "feature", "algorithm_version"):
            policy, evaluation, registration, approval = approval_fixture()
            registration[key] = "d" * 64 if key.endswith("sha256") else "different"
            with self.subTest(key=key), self.assertRaises(ContractError):
                approve(policy, evaluation, registration, approval)

    def test_post_hoc_manifest_binding_or_same_signing_key_rejected(self):
        for key in ("feature_manifest_sha256", "algorithm_manifest_sha256"):
            policy, evaluation, registration, approval = approval_fixture()
            del policy[key]
            evaluation["policy_sha256"] = content_hash(policy)
            with self.subTest(key=key), self.assertRaisesRegex(ContractError, "bound before heldout"):
                approve(policy, evaluation, registration, approval)
        with self.assertRaisesRegex(ContractError, "separate key"):
            approve(*approval_fixture(), approval_key=EVALUATION_KEY)

    def test_manifest_bytes_and_evaluated_mode_cannot_change(self):
        policy, evaluation, registration, approval = approval_fixture()
        registration["canonical_manifest"] += " "
        with self.assertRaisesRegex(ContractError, "canonical manifest"):
            approve(policy, evaluation, registration, approval)
        policy, evaluation, registration, approval = approval_fixture()
        evaluation["report"]["prediction_provenance"]["candidate"]["computation_mode"] = "causal"
        with self.assertRaisesRegex(ContractError, "computation mode"):
            approve(policy, evaluation, registration, approval)

    def test_promotion_rejects_wrong_reference_and_unfinished_evaluation(self):
        for failure in ("wrong_modality", "no_finish", "reversed", "future"):
            policy, evaluation = synthetic_gate_payload()
            if failure == "wrong_modality":
                evaluation["report"]["reference_provenance"][0]["modality"] = "PSG"
            elif failure == "no_finish":
                del evaluation["evaluation_finished_at"]
            else:
                evaluation["evaluation_finished_at"] = "2025-01-01T00:00:00Z" if failure == "reversed" else "2099-01-01T00:00:00Z"
            result = promotion_decision(sign(policy, EVALUATION_KEY, "fixture"),
                                        sign(evaluation, EVALUATION_KEY, "fixture"), KEYS)
            with self.subTest(failure=failure):
                self.assertEqual(result["decision"], "NOT_READY")


class EvaluationTests(unittest.TestCase):
    def test_stage_wake_never_replaces_independent_binary_sleep(self):
        data = synthetic_psg_dataset()
        baseline = predictions(data)
        for record, reference in zip(baseline["recordings"], data["recordings"]):
            record["epochs"] = [{"start_s": row["start_s"], "end_s": row["end_s"],
                "input_start_s": row["start_s"], "input_end_s": row["end_s"], "observed_duration_s": 30,
                "stage": "wake", "binary_state": "sleep" if row["stage"] == "N2" else "wake",
                "binary_provenance": "synthetic-independent-detector", "confidence": None}
                for row in reference["epochs"]]
            record["episodes"] = [{**row, "input_start_s": row["start_s"], "input_end_s": row["end_s"]}
                                   for row in reference["opportunities"]]
        report = evaluate(data, baseline, baseline, split_fixture(), config())
        self.assertEqual(report["binary"]["candidate"]["sleep_sensitivity_all_reference"], 1)
        self.assertEqual(report["stages"]["native"]["candidate"]["sleep_sensitivity_all_reference"], 0)
        self.assertEqual(report["detection"]["candidate"]["tst_seconds"]["bias"], 0)
        self.assertEqual(report["detection"]["candidate"]["by_episode_type"]["nap"]["recall"], 1)
        self.assertEqual(set(report["per_participant"]), {"functional-4", "functional-5"})
        self.assertIn("detection", report["subgroups"]["fixture_group=b"])

    def test_real_reference_stage_output_requires_independent_binary_contract(self):
        data = synthetic_psg_dataset()
        data["evidence_kind"] = "reference"
        candidate = predictions(data)
        epoch = {"start_s": 0, "end_s": 30, "input_start_s": 0, "input_end_s": 30,
                 "stage": "light", "observed_duration_s": 30, "confidence": None}
        candidate["recordings"][0]["epochs"] = [epoch]
        with self.assertRaisesRegex(ContractError, "independent binary_state"):
            validate_predictions(candidate, data)
        epoch.update(binary_state="wake", binary_provenance="stage_inferred")
        with self.assertRaisesRegex(ContractError, "cannot establish binary"):
            validate_predictions(candidate, data)
        epoch["binary_provenance"] = "independent-binary-detector"
        validate_predictions(candidate, data)
        epoch["observed_duration_s"] = 0
        with self.assertRaisesRegex(ContractError, "stage without observed"):
            validate_predictions(candidate, data)

    def test_early_island_is_not_a_qualified_nightly_error(self):
        rows = [{"start_s": t, "end_s": t + 300, "reference": 10, "candidate": 10 if t < 1800 else None}
                for t in range(0, 3600, 300)]
        settings = {**config(), "nightly_coverage_policy": {"minimum_accepted_seconds": 1800,
                     "minimum_accepted_fraction": 0.5, "minimum_third_fraction": 0.1}}
        groups = {("person", "night", 0, 3600): rows}
        result = _nightly_report(groups, "candidate", settings, None)
        self.assertEqual(result["accepted_nights"], 0)
        self.assertIsNone(result["errors"]["mae"])
        self.assertEqual(result["per_night"][0]["coverage_by_third"][-1], 0)
        self.assertEqual(_nightly_report(groups, "candidate", config(), None)["reason"],
                         "nightly_coverage_policy_not_prespecified")

    def test_nightly_error_compares_all_reference_windows_not_only_retained_islands(self):
        rows = [{"start_s": i * 300, "end_s": (i + 1) * 300, "reference": 10 if i % 4 < 2 else 30,
                 "candidate": 10 if i % 4 < 2 else None} for i in range(12)]
        settings = {**config(), "nightly_coverage_policy": {"minimum_accepted_seconds": 1800,
                     "minimum_accepted_fraction": 0.5, "minimum_third_fraction": 0.1}}
        result = _nightly_report({("person", "night", 0, 3600): rows}, "candidate", settings, None)
        self.assertEqual(result["accepted_nights"], 1)
        self.assertEqual(result["errors"]["bias"], -10)
        self.assertEqual(result["mae_participant_ci"]["reason"], "insufficient_participants")

    def test_censored_reference_does_not_shorten_independent_night_bounds(self):
        rows = [{"start_s": t, "end_s": t + 300, "reference": 10, "candidate": 10}
                for t in range(0, 1800, 300)]
        settings = {**config(), "nightly_coverage_policy": {"minimum_accepted_seconds": 1800,
                     "minimum_accepted_fraction": 0.5, "minimum_third_fraction": 0.1}}
        result = _nightly_report({("person", "night", 0, 21600): rows}, "candidate", settings, None)
        self.assertEqual(result["accepted_nights"], 0)
        self.assertEqual(result["per_night"][0]["opportunity_end_s"], 21600)
        self.assertAlmostEqual(result["per_night"][0]["accepted_fraction"], 1 / 12)
        missing = _nightly_report({}, "candidate", settings, None)
        self.assertEqual(missing["reason"], "independent_main_sleep_opportunity_unavailable")

    def test_sleep_promotion_wake_budget_cannot_use_staging_as_binary_state(self):
        policy, _ = synthetic_gate_payload()
        policy["metric_family"] = "sleep"
        policy["criteria"] = [row for row in policy["criteria"] if not row["role"].startswith("nightly_")]
        for criterion in policy["criteria"]:
            criterion["path"] = criterion["path"].replace("numeric/respiratory_rate_bpm", "stages")
            if criterion["path"].endswith("candidate_minus_baseline_mae"):
                criterion.update(path=criterion["path"].replace("candidate_minus_baseline_mae", "candidate_minus_baseline_kappa"),
                                 operator=">=", limit=0.1 if criterion["role"] == "primary_improvement" else 0)
        wake = {"role": "wake_noninferiority", "path": "report/stages/native/candidate_minus_baseline_wake_specificity_all_reference",
                "operator": ">=", "limit": 0}
        policy["criteria"] += [wake,
            {"role": "end_to_end_detection", "path": "report/detection/candidate/recall", "operator": ">=", "limit": 0.1},
            {"role": "end_to_end_detection", "path": "report/detection/candidate/false_episodes_per_24h", "operator": "<=", "limit": 1}]
        with self.assertRaisesRegex(ContractError, "independent binary"):
            freeze_policy(policy)
        wake["path"] = "report/binary/candidate_minus_baseline_wake_specificity_all_reference"
        freeze_policy(policy)

    def test_window_accuracy_cannot_promote_without_representative_nightly_evidence(self):
        for mutation in ("missing_budget", "wrong_aggregation", "diagnostic_only", "no_nights", "one_person", "no_uncertainty", "no_subgroup_nights"):
            policy, evaluation = synthetic_gate_payload()
            nightly = evaluation["report"]["numeric"]["respiratory_rate_bpm"]["nightly_representative"]["candidate"]
            if mutation == "missing_budget":
                policy["criteria"] = [row for row in policy["criteria"] if row["role"] != "nightly_coverage"]
            elif mutation == "wrong_aggregation":
                next(row for row in policy["criteria"] if row["role"] == "nightly_accuracy")["path"] = \
                    "report/numeric/respiratory_rate_bpm/nightly_representative/candidate/errors/mae"
            elif mutation == "diagnostic_only":
                del evaluation["report"]["numeric"]["respiratory_rate_bpm"]["nightly_representative"]
            elif mutation == "no_nights":
                nightly["retained_night_coverage"] = 0
            elif mutation == "one_person":
                nightly.update(participants=["functional-4"], participant_n=1)
            elif mutation == "no_subgroup_nights":
                del evaluation["report"]["subgroups"]["fixture=only"]["numeric"]["respiratory_rate_bpm"]["nightly_representative"]
            else:
                nightly["median_mae_participant_ci"]["lower"] = None
            evaluation["policy_sha256"] = content_hash(policy)
            decision = promotion_decision(sign(policy, EVALUATION_KEY, "fixture"),
                                          sign(evaluation, EVALUATION_KEY, "fixture"), KEYS)
            with self.subTest(mutation=mutation):
                self.assertEqual(decision["decision"], "NOT_READY")

    def test_nightly_evaluation_joins_independent_opportunity_bounds(self):
        data = synthetic_dataset()
        psg = synthetic_psg_dataset()["recordings"]
        for row in psg:
            row["id"] += "-psg"
            row["source_recording_id"] += "-psg"
            row["end_s"] = 3600
            row["epochs"] = [{"start_s": t, "end_s": t + 30, "stage": "N2", "scorable": True}
                             for t in range(0, 3600, 30)]
            row["opportunities"] = [{"start_s": 0, "end_s": 3600, "type": "main_sleep", "annotation_source": "independent_fixture"}]
            row["opportunity_annotation_spans"][0]["end_s"] = 3600
        data["recordings"] += psg
        prediction = predictions(data)
        settings = {**config(), "nightly_coverage_policy": {"minimum_accepted_seconds": 300,
                     "minimum_accepted_fraction": 0.1, "minimum_third_fraction": 0.1}}
        report = evaluate(data, prediction, prediction, split_fixture(), settings)
        nightly = report["numeric"]["respiratory_rate_bpm"]["nightly_representative"]["candidate"]
        self.assertEqual(nightly["eligible_nights"], 2)
        self.assertEqual(nightly["accepted_nights"], 0)
        self.assertEqual(nightly["per_night"][0]["opportunity_end_s"], 3600)
        for row in psg:
            row["opportunity_annotation_spans"] = []
        report = evaluate(data, prediction, prediction, split_fixture(), settings)
        self.assertEqual(report["numeric"]["respiratory_rate_bpm"]["nightly_representative"]["candidate"]["eligible_nights"], 0)

    def test_real_heldout_cli_refuses_draft_or_missing_fit_before_reading_predictions(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            data = synthetic_dataset()
            data["evidence_kind"] = "reference"
            documents = {"dataset": data, "split": split_fixture(), "config": config(),
                         "policy": {"schema_version": 1, "status": "draft"}}
            command = [sys.executable, str(ROOT / "bench.py"), "evaluate", "--baseline", "absent-baseline.json",
                       "--candidate", "absent-candidate.json"]
            for name, value in documents.items():
                path = directory / (name + ".json")
                path.write_text(json.dumps(value))
                command += ["--" + name, str(path)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("policy is not frozen", result.stderr)
            self.assertNotIn("No such file", result.stderr)
            policy, _ = synthetic_gate_payload()
            policy.update({key + "_sha256": content_hash(documents[key]) for key in ("dataset", "split", "config")})
            policy.update(feature_manifest_sha256="c" * 64, algorithm_manifest_sha256="d" * 64)
            (directory / "policy.json").write_text(json.dumps(policy))
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("frozen fit audit and model manifest required", result.stderr)
            self.assertNotIn("No such file", result.stderr)


if __name__ == "__main__":
    unittest.main()
