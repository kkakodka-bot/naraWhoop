"""Adversarial functional cases. All generated rows are synthetic, not reference qualification."""
import copy
from hashlib import sha256
import json
from unittest.mock import patch
import unittest

from physiology_inference.contracts import Abstain, canonical_hash, typed_hash, validate_job
from physiology_inference.feature_sleep import fit, predict, calibrate
from physiology_inference.contracts import shadow_result
from physiology_inference.runtime import ShadowRuntime
from physiology_inference.preprocessing import wav2sleep_ppg
from test_inference import rows, job, signal


class ProductionModelTest(unittest.TestCase):
    def test_stale_interior_waveform_epoch_abstains_despite_variable_whole_night(self):
        data = signal(count=2881)
        data["values"][720:1440] = [100] * 720
        with self.assertRaisesRegex(Abstain, "flat_ppg_epoch"):
            wav2sleep_ppg(validate_job(job([data])), 4)

    def test_joint_modalities_coverage_and_quality_are_required(self):
        model = fit(rows(), ["train"], iterations=5)
        cases = rows("heldout")[:5]
        cases[0]["features"] = {"hr_mean": 60}
        cases[1]["features"] = {"motion": 0.0}
        cases[2]["evidence_coverage"]["motion"] = 0.89
        cases[3]["quality_rejection_reasons"] = ["off_body"]
        output = predict(model, cases)
        self.assertEqual(output["stages"][:4], ["unknown"] * 4)
        self.assertEqual(output["probabilities"][:4], [None] * 4)
        self.assertIsNotNone(output["probabilities"][4])
        self.assertEqual(output["abstention_reasons"][:4], ["qualified_motion_unavailable", "qualified_hr_unavailable",
            "joint_modality_coverage_insufficient", "signal_quality_rejected"])

    def test_acquisition_aliases_and_duplicate_exports_are_rejected(self):
        first = rows("train")
        alias = copy.deepcopy(first)
        for row in alias:
            row["participant"] = "alias"
        with self.assertRaisesRegex(Abstain, "acquisition_alias"):
            fit(first + alias, ["train", "alias"])
        alias = copy.deepcopy(first)
        for row in alias:
            row["recording"] = "renamed"
        with self.assertRaisesRegex(Abstain, "acquisition_overlap"):
            fit(first + alias, ["train"])

    def test_development_calibration_is_bound_and_heldout_is_not_fitted(self):
        model = fit(rows(), ["train"], iterations=10)
        development = rows("development")
        for row in development:
            row["partition"] = "development"
        calibrated = calibrate(model, development, ["development"])
        self.assertFalse(model["calibrated"])
        result = predict(calibrated, rows("heldout"))
        self.assertTrue(result["calibrated"])
        self.assertEqual(result["calibration"]["scope"], "emission_probabilities_not_duration_decoded_marginals")
        for row in development:
            row["partition"] = "test"
        with self.assertRaisesRegex(Abstain, "development_evidence"):
            calibrate(model, development, ["development"])
        with self.assertRaisesRegex(Abstain, "training_overlap"):
            calibrate(model, rows(), ["train"])

    def test_malformed_checkpoint_is_not_a_stage(self):
        model = fit(rows(), ["train"], iterations=5)
        model["scales"][0] = 0
        model["model_hash"] = canonical_hash({k: v for k, v in model.items() if k != "model_hash"})
        with self.assertRaisesRegex(Abstain, "parameters_invalid"):
            predict(model, rows("heldout"))
        model = fit(rows(), ["train"], iterations=5)
        model["calibration"] = {"temperature": 2.0}
        model["model_hash"] = canonical_hash({k: v for k, v in model.items() if k != "model_hash"})
        with self.assertRaisesRegex(Abstain, "calibration_invalid"):
            predict(model, rows("heldout"))

    def test_corrupt_or_other_model_checkpoint_output_cannot_escape_worker(self):
        request = job(); activation = {"assets": {"weights": {"sha256": "a" * 64}}, "code_revision": "b" * 40,
                                      "preprocess_version": "synthetic", "quality_policy_version": "synthetic"}
        valid = shadow_result(request, "synthetic", output={}, activation=activation)
        cases = [[], {**valid, "model_id": "other"}, {**valid, "checkpoint_sha256": "c" * 64},
                 {**valid, "activation_hash": "d" * 64}, {**valid, "input_revision": "2"},
                 {**valid, "user_id": "other"}, {**valid, "device_id": "other"}, {**valid, "output": None}]
        def fake_worker(output):
            class Child:
                returncode = 0
                def __enter__(self): return self
                def __exit__(self, *args): return None
                def communicate(self, *args, **kwargs): output.write(json.dumps(result).encode())
            return Child()
        runtime = ShadowRuntime()
        for result in cases:
            with patch("physiology_inference.runtime.subprocess.Popen", side_effect=lambda *args, **kw: fake_worker(kw["stdout"])):
                self.assertEqual(runtime.run(request, "synthetic", activation, ".")["reason"], "inference_output_contract_invalid")
        result = valid
        with patch("physiology_inference.runtime.subprocess.Popen", side_effect=lambda *args, **kw: fake_worker(kw["stdout"])):
            self.assertEqual(runtime.run(request, "synthetic", activation, ".")["status"], "complete")

    def test_cross_language_hash_golden_and_complete_identity(self):
        value = {"n": [None, True, False, 1, 1.5, "é"], "x": "abc"}
        # Hand-encoded typed wire representation is shared with the JVM test.
        expected = b'{s1:n[ntfd' + bytes.fromhex("3ff0000000000000") + b'd' + bytes.fromhex("3ff8000000000000") + b's2:\xc3\xa9]s1:xs3:abc}'
        self.assertEqual(typed_hash(value), sha256(expected).hexdigest())
        job = {"user_id": "a", "device_id": "b", "input_revision": "2", "mode": "retrospective", "signals": [],
               "input_hash_encoding": "typed-json-sha256-1", "checkpoint_sha256": "c" * 64}
        job["input_hash"] = typed_hash(job)
        validate_job(job)
        job["checkpoint_sha256"] = "d" * 64
        with self.assertRaisesRegex(Abstain, "immutable_input_hash"):
            validate_job(job)


if __name__ == "__main__":
    unittest.main()
