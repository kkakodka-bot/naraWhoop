"""Synthetic functional controls, never physiological reference-validation evidence."""

import copy
from hashlib import sha256
import importlib.util
import math
import os
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from physiology_inference.contracts import Abstain, Signal, canonical_hash, validate_job, verify_asset, validate_activation, implementation_hash
from physiology_inference.preprocessing import wav2sleep_ppg, rr_estimation, aligned
from physiology_inference.adapters import lipponen_corrections, neurokit_detectors
from physiology_inference.feature_sleep import fit, predict
from physiology_inference.runtime import Limits, ShadowRuntime


def signal(name="PPG", rate=24, count=1441, start=0, unit="adc_count", orientation=None):
    return {"name": name, "unit": unit, "sample_rate_hz": rate, "start": start,
            "values": [math.sin(2 * math.pi * i / rate) for i in range(count)], "observed": [True] * count,
            "timing_verified": True, "semantics_verified": True, "clock_id": "fixture-clock",
            "acquisition_id": "synthetic-not-reference", "wavelength_nm": 525, "orientation": orientation}


def job(signals=None, **kwargs):
    result = {"user_id": "owner", "device_id": "device", "input_revision": "1", "mode": "retrospective",
              "signals": signals or [], **kwargs}
    result["input_hash"] = canonical_hash(result)
    return result


def rows(participant="train"):
    return [{"participant": participant, "recording": "fixture", "start": i * 30, "end": (i + 1) * 30,
             "source_recording_id": "synthetic-" + participant, "source_sha256": sha256(participant.encode()).hexdigest(),
             "evidence_coverage": {"hr": 1.0, "motion": 1.0},
             "features": {"hr_mean": 50 + i % 4 * 10, "motion": 1 if i % 4 == 0 else 0},
             "label": ("wake", "light", "deep", "rem")[i % 4], "label_source": "independent_psg",
             "fixture_type": "synthetic_not_reference"} for i in range(40)]


class ContractsTest(unittest.TestCase):
    def test_noncausal_walch_rejects_online_modes_before_importing_or_reading_assets(self):
        from physiology_inference.comparators import walch_compare
        for mode in ("causal", "windowed"):
            with self.assertRaisesRegex(Abstain, "noncausal_model_requires_retrospective_mode"):
                walch_compare({"mode": mode}, Path("/nonexistent/walch"), "unused")

    def test_inventory_hashes_bind_runtime_and_preprocessing_source_bytes(self):
        repo = Path(__file__).resolve().parents[3]
        runtime_hash = implementation_hash()
        manifests = [path for path in (repo / "models/manifests").glob("*.json")
                     if path.name != "model-manifest.schema.json"]
        self.assertEqual(len(manifests), 8)
        for path in manifests:
            with self.subTest(model=path.stem):
                manifest = json.loads(path.read_text())
                source = (repo / manifest["preprocessing_source"]).resolve()
                self.assertTrue(source.is_relative_to(repo))
                self.assertEqual(manifest["preprocessing_sha256"], sha256(source.read_bytes()).hexdigest())
                policy = (repo / manifest["quality_policy_source"]).resolve()
                self.assertTrue(policy.is_relative_to(repo))
                self.assertEqual(manifest["quality_policy_sha256"], sha256(policy.read_bytes()).hexdigest())
                self.assertEqual(manifest["adapter_sha256"], runtime_hash)
                self.assertEqual(manifest["implementation"]["implementation_sha256"], runtime_hash)
                self.assertIn(manifest["operational_status"], ("metadata_only", "adapter_ready"))
                self.assertEqual(manifest["publication_mode"], "shadow")
                self.assertIs(manifest["canonical_outputs_allowed"], False)

    def test_feature_inventory_identifies_actual_local_softmax_and_feature_contract(self):
        from physiology_inference.feature_sleep import FEATURES
        repo = Path(__file__).resolve().parents[3]
        manifest = json.loads((repo / "models/manifests/feature-sleep-learner.json").read_text())
        self.assertIn("softmax", manifest["purpose"].lower())
        self.assertEqual(manifest["code"]["repository"], "https://github.com/kkakodka-bot/naraWhoop")
        self.assertEqual(manifest["code"]["path"], "scoring-service/inference/physiology_inference/feature_sleep.py")
        self.assertEqual(manifest["preprocessing_source"], manifest["code"]["path"])
        self.assertEqual(manifest["licenses"]["code"]["identifier"], "PolyForm-Noncommercial-1.0.0")
        self.assertIn("PolyForm Noncommercial License 1.0.0", (repo / "LICENSE").read_text())
        self.assertEqual(manifest["input_contract"]["channels"], list(FEATURES))
        self.assertEqual(manifest["input_contract"]["epoch_seconds"], 30)
        self.assertEqual(manifest["input_contract"]["allowed_modes"], ["causal", "retrospective"])

    def test_job_hash_covers_model_options_and_features(self):
        request = job([signal()], epochs=2)
        validate_job(request)
        request["epochs"] = 3
        with self.assertRaisesRegex(Abstain, "immutable_input_hash"):
            validate_job(request)

    def test_unknown_timing_and_channel_reject(self):
        for key, reason in (("timing_verified", "timing"), ("semantics_verified", "semantics")):
            data = signal(); data[key] = False
            with self.assertRaisesRegex(Abstain, reason): Signal.parse(data)

    def test_wrong_mask_nonfinite_and_duplicate_channels_reject(self):
        data = signal(); data["observed"] = [True]
        with self.assertRaises(Abstain): Signal.parse(data)
        data = signal(); data["values"][0] = float("nan")
        with self.assertRaises(Abstain): Signal.parse(data)
        with self.assertRaisesRegex(Abstain, "duplicate"): validate_job(job([signal(), signal()]))

    def test_asset_hash_and_path(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "weights"
            path.write_bytes(b"synthetic test asset")
            asset = {"path": "weights", "sha256": sha256(path.read_bytes()).hexdigest()}
            self.assertEqual(verify_asset(asset, root), path.resolve())
            with self.assertRaisesRegex(Abstain, "hash_mismatch"): verify_asset({**asset, "sha256": "0" * 64}, root)
            with self.assertRaisesRegex(Abstain, "path_invalid"): verify_asset({**asset, "path": "../weights"}, root)

    def test_activation_cannot_bypass_separate_rights(self):
        activation = {"model_id": "x", "publication_mode": "shadow", "canonical_outputs_allowed": False,
                      "code_revision": "a" * 40, "rights": {"code": {"status": "reviewed", "identifier": "synthetic-only", "evidence": "fixture"}}}
        with self.assertRaisesRegex(Abstain, "weights_rights"): validate_activation(activation, ".", "x")

    def test_code_and_checkpoint_consumers_cannot_waive_rights_review(self):
        for model_id, right in (("neurokit2", "code"), *[(name, "weights") for name in (
                "wav2sleep-cardiorespiratory", "rr-estimation", "feature-sleep-learner", "sleepecg", "correncoder")]):
            activation = {"model_id": model_id, "publication_mode": "shadow", "canonical_outputs_allowed": False,
                          "code_revision": "a" * 40, "rights": {key: {"status": "reviewed", "identifier": "synthetic-only",
                              "evidence": "synthetic contract test only"} for key in ("code", "weights", "training_data")}}
            activation["rights"][right].update(status="not_applicable", reason="synthetic invalid waiver")
            with self.subTest(model_id=model_id, right=right), self.assertRaisesRegex(Abstain, f"{right}_rights_not_reviewed"):
                validate_activation(activation, ".", model_id)

    def test_runtime_reviewed_evidence_and_nonapplicability_are_meaningful(self):
        base = {"model_id": "neurokit2", "publication_mode": "shadow", "canonical_outputs_allowed": False,
                "code_revision": "a" * 40, "rights": {key: {"status": "reviewed", "identifier": "synthetic-only",
                    "evidence": "synthetic contract test only"} for key in ("code", "weights", "training_data")}}
        for right in ("code", "weights", "training_data"):
            for field in ("identifier", "evidence"):
                activation = copy.deepcopy(base)
                activation["rights"][right][field] = " "
                with self.subTest(right=right, field=field), self.assertRaisesRegex(Abstain, f"{right}_rights_{field}_missing"):
                    validate_activation(activation, ".", "neurokit2")
        activation = copy.deepcopy(base)
        activation["rights"]["weights"].update(status="not_applicable")
        with self.assertRaisesRegex(Abstain, "nonapplicability_reason_missing"):
            validate_activation(activation, ".", "neurokit2")
        activation["rights"]["weights"]["reason"] = "Synthetic detector fixture has no checkpoint"
        with self.assertRaisesRegex(Abstain, "execution_assets_missing"):
            validate_activation(activation, ".", "neurokit2")

    def test_correncoder_refuses_causal_or_windowed_waveforms_before_inference(self):
        from physiology_inference.adapters import execute
        for mode in ("causal", "windowed"):
            with patch("physiology_inference.adapters.validate_activation", return_value={}), \
                    patch("physiology_inference.correncoder.infer") as inference:
                with self.assertRaisesRegex(Abstain, "requires_retrospective_mode"):
                    execute(job(mode=mode), "correncoder", {}, ".")
                inference.assert_not_called()


class PreprocessingTest(unittest.TestCase):
    def test_wav2sleep_exact_target_grid_and_sample_std(self):
        import numpy as np
        prepared = wav2sleep_ppg(validate_job(job([signal()])), 2)
        self.assertEqual(prepared.shape, (1, 2048))
        self.assertAlmostEqual(float(np.mean(prepared)), 0, places=6)
        self.assertAlmostEqual(float(np.std(prepared, ddof=1)), 1, places=6)

    def test_gaps_wrong_wavelength_and_causal_extrapolation_reject(self):
        data = signal(); data["observed"][10] = False
        with self.assertRaisesRegex(Abstain, "gap"): wav2sleep_ppg(validate_job(job([data])), 2)
        data = signal(); data["wavelength_nm"] = None
        with self.assertRaisesRegex(Abstain, "wavelength"): wav2sleep_ppg(validate_job(job([data])), 2)
        with self.assertRaisesRegex(Abstain, "extrapolate"): wav2sleep_ppg(validate_job(job([signal(count=1440)])), 2)

    def test_rr_exact_shape_units_and_alignment(self):
        signals = [signal(name=n, rate=64, count=2048, unit="upstream_preprocessed", orientation="device_xyz")
                   for n in ("PPG", "ACC_X", "ACC_Y", "ACC_Z")]
        prepared = rr_estimation(validate_job(job(signals)), "rr-estimation-released-preprocessed-v1")
        self.assertEqual(prepared.shape, (1, 2048, 4))
        signals[1]["start"] = 0.1
        with self.assertRaisesRegex(Abstain, "aligned"): rr_estimation(validate_job(job(signals)), "rr-estimation-released-preprocessed-v1")

    def test_rr_does_not_invent_missing_external_preprocessing(self):
        signals = [signal(name=n, rate=64, count=2048, orientation="device_xyz") for n in ("PPG", "ACC_X", "ACC_Y", "ACC_Z")]
        with self.assertRaisesRegex(Abstain, "external_preprocessing"): rr_estimation(validate_job(job(signals)), "guessed-zscore")


class CorrectionTest(unittest.TestCase):
    def test_zero_and_gap_pair_masks(self):
        class Identity:
            @staticmethod
            def signal_fixpeaks(peaks, **kwargs): return {}, peaks
        result = lipponen_corrections([0, 1000, 2000, 3000, 8000, 9000, 10000, 11000], 1000,
                                     [(0, 4000), (8000, 12000)], Identity)
        self.assertEqual(result["research_observed_rmssd_ms"], 0)
        self.assertFalse(result["observed_pair_mask"][3]); self.assertFalse(result["observed_pair_mask"][4])
        self.assertEqual(result["research_corrected_rmssd_ms"], 0)

    def test_cumulative_passes_preserve_original_identities(self):
        import numpy as np
        class TwoPass:
            calls = 0
            def signal_fixpeaks(self, peaks, **kwargs):
                self.calls += 1
                if self.calls <= 2:
                    out = peaks.copy(); out[self.calls + 1] += 50
                    return {"longshort": [self.calls + 1]}, out
                return {}, peaks
        result = lipponen_corrections(np.arange(20) * 1000, 1000, [(0, 20000)], TwoPass())
        self.assertEqual(len(result["correction_events"]), 2)
        self.assertEqual(result["correction_event_count"], 4)
        self.assertEqual(result["original_peak_samples"][2], 2000)
        self.assertGreater(result["correction_fraction"], 0)

    def test_unobserved_peak_and_overlapping_runs_reject(self):
        with self.assertRaisesRegex(Abstain, "outside"): lipponen_corrections([0, 1, 2, 9], 1, [(0, 3)], None)
        with self.assertRaisesRegex(Abstain, "overlap"): lipponen_corrections([0, 1, 2, 3], 1, [(0, 3), (2, 4)], None)


class FeatureLearnerTest(unittest.TestCase):
    def test_training_only_transform_determinism_and_missing_abstention(self):
        model = fit(rows(), ["train"], iterations=50)
        self.assertEqual(model, fit(rows(), ["train"], iterations=50))
        before = copy.deepcopy(model)
        test = rows("heldout"); test[0]["features"] = {"hr_mean": 10000}
        result = predict(model, test)
        self.assertEqual(model, before); self.assertEqual(len(result["stages"]), len(test))
        test[2]["features"] = {}
        missing = predict(model, test)
        self.assertEqual(missing["stages"][2], "unknown"); self.assertIsNone(missing["probabilities"][2])

    def test_self_generated_labels_and_participant_leakage_reject(self):
        bad = rows(); bad[0]["label_source"] = "app_estimate"
        with self.assertRaisesRegex(Abstain, "independent_psg"): fit(bad, ["train"])
        with self.assertRaisesRegex(Abstain, "participant"): fit(rows(), ["heldout"])

    def test_causal_predictions_are_prefix_invariant(self):
        model = fit(rows(), ["train"], iterations=10)
        full = predict(model, rows("test"), mode="causal")
        prefix = predict(model, rows("test")[:10], mode="causal")
        self.assertEqual(full["stages"][:10], prefix["stages"])
        self.assertEqual(full["probabilities"][:10], prefix["probabilities"])


class RuntimeTest(unittest.TestCase):
    def test_actual_bounded_feature_model_and_implementation_binding(self):
        with tempfile.TemporaryDirectory() as root:
            weights = Path(root) / "synthetic-model.json"
            weights.write_text(json.dumps(fit(rows(), ["train"], iterations=5)))
            from physiology_inference.environment import capture
            environment = capture("feature-sleep-learner")
            environment["qualification_status"] = "qualified_shadow_environment"
            environment_path = Path(root) / "synthetic-environment.json"
            environment_path.write_text(json.dumps(environment))
            activation = {"model_id": "feature-sleep-learner", "publication_mode": "shadow", "canonical_outputs_allowed": False,
                          "code_revision": "a" * 40, "implementation_sha256": implementation_hash(),
                          "preprocess_version": "feature-training-only-1", "quality_policy_version": "synthetic-contract-1",
                          "rights": {key: {"status": "reviewed", "identifier": "synthetic-fixture-only",
                                           "evidence": "synthetic fixture only; no external data or weights"}
                                     for key in ("code", "weights", "training_data")},
                          "environment_review": {"status": "reviewed_for_shadow", "identifier": "synthetic-fixture-only",
                                                 "evidence": "functional test only, not target qualification"},
                          "assets": {"weights": {"path": weights.name, "sha256": sha256(weights.read_bytes()).hexdigest()},
                                     "environment_manifest": {"path": environment_path.name,
                                                              "sha256": sha256(environment_path.read_bytes()).hexdigest()}}}
            runtime = ShadowRuntime()
            request = job(feature_rows=rows("heldout"))
            result = runtime.run(request, "feature-sleep-learner", activation, root)
            self.assertEqual(result["status"], "complete", result)
            self.assertEqual(len(result["output"]["stages"]), 40)
            self.assertFalse(result["canonical_outputs_allowed"])
            self.assertGreaterEqual(result["cpu_user_seconds"], 0)
            self.assertGreaterEqual(result["cpu_system_seconds"], 0)
            self.assertGreater(result["peak_rss_platform_units"], 0)
            activation["implementation_sha256"] = "0" * 64
            self.assertEqual(runtime.run(request, "feature-sleep-learner", activation, root)["reason"], "adapter_implementation_hash_mismatch")

    def test_failure_does_not_poison_next_user(self):
        runtime = ShadowRuntime()
        first = runtime.run(job(), "neurokit2", {}, ".")
        second = runtime.run(job(user_id="other"), "neurokit2", {}, ".")
        self.assertEqual(first["reason"], "shadow_activation_required")
        self.assertEqual(second["user_id"], "other"); self.assertFalse(second["canonical_outputs_allowed"])

    def test_timeout_kills_worker_and_releases_slot(self):
        runtime = ShadowRuntime(Limits(timeout_seconds=0.00001))
        self.assertEqual(runtime.run(job(), "x", {}, ".")["reason"], "inference_timeout")
        self.assertNotEqual(runtime.run(job(), "x", {}, ".")["reason"], "inference_busy")

    def test_busy_is_immediate_and_bounded(self):
        runtime = ShadowRuntime(); runtime._slot.acquire()
        try: self.assertEqual(runtime.run(job(), "x", {}, ".")["reason"], "inference_busy")
        finally: runtime._slot.release()


class ComparatorTest(unittest.TestCase):
    def test_validated_environment_asset_is_not_passed_as_rrest_model_source(self):
        from physiology_inference.adapters import execute
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {"fts": "FTS.m", "acf": "ACF.m", "spectral_peak": "find_spectral_peak.m",
                     "environment_manifest": "synthetic-environment.json"}
            for filename in files.values():
                (root / filename).write_text("{}")
            activation = {"model_id": "rrest", "publication_mode": "shadow", "canonical_outputs_allowed": False,
                "code_revision": "f5022e7029c5b6d6b8159b665dccc2c8f267976e", "implementation_sha256": implementation_hash(),
                "preprocess_version": "synthetic", "quality_policy_version": "synthetic",
                "rights": {key: {"status": "reviewed", "identifier": "synthetic-fixture-only", "evidence": "synthetic files only"}
                           for key in ("code", "weights", "training_data")},
                "assets": {name: {"path": filename, "sha256": sha256((root / filename).read_bytes()).hexdigest()}
                           for name, filename in files.items()}, "octave_executable": "/nonexistent/octave"}
            request = job(signals=[signal(name="RESP_MODULATION", rate=8, count=960, unit="arbitrary_verified")])
            # Only environment qualification is stubbed. Real rights/assets/layout validation runs;
            # no Octave execution or qualified external environment is claimed by this fixture.
            with patch("physiology_inference.environment.verify") as verify_environment:
                with self.assertRaisesRegex(Abstain, "rrest_octave_unavailable"):
                    execute(request, "rrest", activation, root)
                verify_environment.assert_called_once()

    def test_sleepecg_preserves_upstream_class_order_and_undefined(self):
        import numpy as np
        from physiology_inference.comparators import sleepecg_compare
        for mode, expected in (("wake-sleep", ["unknown", "sleep_unstaged", "wake"]),
                               ("wake-rem-nrem", ["unknown", "nrem_unsplit", "rem", "wake"])):
            classifier = SimpleNamespace(stages_mode=mode, feature_extraction_params={})
            fake = SimpleNamespace(load_classifier=lambda *a, **kw: classifier, SleepRecord=lambda **kw: kw,
                                   stage=lambda *a, **kw: np.full((5, len(expected)), 1 / len(expected)))
            with patch.dict("sys.modules", {"sleepecg": fake}), patch("physiology_inference.comparators.verify_loaded_package"):
                result = sleepecg_compare(job(beat_times={"seconds": list(range(400)), "modality": "ecg_nn",
                                                         "timing_verified": True, "observed_complete": True}), Path("local.zip"), "fixture")
            self.assertEqual(result["labels"], expected)
            self.assertFalse(result["four_stage_eligible"])
            self.assertEqual(classifier.feature_extraction_params["n_jobs"], 1)

    def test_rrest_requires_an_actual_octave_runtime(self):
        from physiology_inference.comparators import rrest_compare
        paths = {"fts": Path("/reviewed/FTS.m"), "acf": Path("/reviewed/ACF.m"), "spectral_peak": Path("/reviewed/find_spectral_peak.m")}
        with self.assertRaisesRegex(Abstain, "octave_unavailable"):
            rrest_compare(Signal.parse(signal(name="RESP_MODULATION", rate=8, count=960, unit="arbitrary_verified")), paths, "/nonexistent/octave")

    @unittest.skipUnless(os.environ.get("WALCH_SOURCE"), "pinned Walch checkout not configured")
    def test_actual_walch_feature_assembly_serial_comparator(self):
        from physiology_inference.comparators import walch_compare
        root = Path(os.environ["WALCH_SOURCE"])
        source = root / "source"
        digest = canonical_hash({str(p.relative_to(source)): sha256(p.read_bytes()).hexdigest() for p in sorted(source.rglob("*.py"))})
        request = job(training_participants=["train"], testing_participants=["heldout"], feature_names=["hr", "motion"],
                      stage_mode="wake-nrem-rem", subjects=[{"participant": participant, "label_source": "independent_psg",
                        "preprocessing_version": "walch-upstream-features-v1", "features": [[50 + i % 3 * 10, i % 3] for i in range(30)],
                        "psg_stage_codes": [[0, 2, 5][i % 3] for i in range(30)]} for participant in ("train", "heldout")])
        result = walch_compare(request, root, digest)
        self.assertEqual(result["labels"], ["wake", "nrem_unsplit", "rem"])
        self.assertEqual(len(result["probabilities"]), 30)
        self.assertEqual(result["reference_labels"][:3], [0, 1, 2])
        self.assertFalse(result["four_stage_eligible"])


@unittest.skipUnless(importlib.util.find_spec("neurokit2"), "pinned NeuroKit source not installed")
class ActualNeuroKitTest(unittest.TestCase):
    def test_actual_ppg_detectors_and_lipponen_on_synthetic_signal(self):
        import neurokit2 as nk
        data = signal(rate=50, count=3000)
        data["values"] = nk.ppg_simulate(duration=60, sampling_rate=50, random_state=55).tolist()
        result = neurokit_detectors({"PPG": Signal.parse(data)}, nk)
        self.assertGreater(len(result["peak_sets"]["elgendi"]), 30)
        self.assertGreater(len(result["peak_sets"]["msptdfast"]), 30)
        self.assertEqual(result["modality"], "ppg_ibi")

    def test_actual_ecg_detector_keeps_ecg_modality(self):
        import neurokit2 as nk
        data = signal(name="ECG", rate=100, count=3000, unit="mV")
        data["values"] = nk.ecg_simulate(duration=30, sampling_rate=100, random_state=55).tolist()
        result = neurokit_detectors({"ECG": Signal.parse(data)}, nk)
        self.assertEqual(result["modality"], "ecg_nn")


@unittest.skipUnless(importlib.util.find_spec("torch"), "pinned Torch unavailable")
class CorrEncoderTest(unittest.TestCase):
    def test_acquisition_aliases_hash_conflicts_and_duplicate_exports_fail_before_training(self):
        from physiology_inference.correncoder import train
        rows = [{"participant": participant, "recording": "export", "start": 0, "end": 10,
                 "source_recording_id": "acquisition-" + participant,
                 "source_sha256": sha256(participant.encode()).hexdigest(), "sample_rate_hz": 20,
                 "ppg": [0.0] * 200, "reference": [0.0] * 200, "reference_source": "capnography",
                 "rights_reviewed": True, "preprocessing": "upstream_presegmented_standardized",
                 "observed_complete": True} for participant in ("train", "dev")]
        cases = []
        same_id = copy.deepcopy(rows)
        same_id[1]["source_recording_id"] = same_id[0]["source_recording_id"]
        cases.append(("same_source_id_different_hash", same_id, "participant_overlap"))
        same_hash = copy.deepcopy(rows)
        same_hash[1]["source_sha256"] = same_hash[0]["source_sha256"]
        cases.append(("same_hash_different_source_id", same_hash, "participant_overlap"))
        hash_conflict = copy.deepcopy(rows) + [copy.deepcopy(rows[0])]
        hash_conflict[-1].update(source_sha256="a" * 64, start=10, end=20)
        cases.append(("same_owner_source_hash_changed", hash_conflict, "hash_conflict"))
        duplicate = copy.deepcopy(rows) + [copy.deepcopy(rows[0])]
        duplicate[-1].update(recording="renamed-export", source_recording_id="renamed-acquisition")
        cases.append(("duplicate_span_renamed_export", duplicate, "segment_invalid"))
        for name, segments, reason in cases:
            with self.subTest(case=name), patch("physiology_inference.correncoder.model") as build_model:
                with self.assertRaisesRegex(Abstain, reason):
                    train(segments, ["train"], ["dev"], epochs=1)
                build_model.assert_not_called()

    def test_one_epoch_reproduction_is_deterministic_and_participant_disjoint(self):
        import torch
        from physiology_inference.correncoder import train
        segments = [{"participant": p, "recording": "synthetic", "start": 0, "end": 10,
                     "source_recording_id": f"synthetic-{p}", "source_sha256": sha256(p.encode()).hexdigest(),
                     "sample_rate_hz": 20,
                     "ppg": [math.sin(i / 10) for i in range(200)], "reference": [math.sin(i / 30) for i in range(200)],
                     "reference_source": "capnography", "rights_reviewed": True,
                     "preprocessing": "upstream_presegmented_standardized", "observed_complete": True,
                     "fixture_type": "synthetic_not_reference"} for p in ("train", "dev")]
        a, report = train(segments, ["train"], ["dev"], epochs=1)
        b, _ = train(segments, ["train"], ["dev"], epochs=1)
        self.assertTrue(all(torch.equal(a.state_dict()[k], v) for k, v in b.state_dict().items()))
        self.assertEqual(report["loss"], "MSE"); self.assertFalse(report["released_checkpoint_claimed"])
        from physiology_inference.correncoder import infer
        with tempfile.TemporaryDirectory() as root:
            weights = Path(root) / "weights.pth"; torch.save(a.state_dict(), weights)
            restored = infer(Signal.parse(signal(rate=20, count=200, unit="upstream_preprocessed")), weights, report)
            self.assertEqual(len(restored["respiratory_waveform"]), 200)
            self.assertIsNone(restored["breaths_per_minute"])
        with self.assertRaisesRegex(Abstain, "overlap"): train(segments, ["train"], ["train"], epochs=1)
        for alias_kind in ("same_original_id", "same_content_hash"):
            aliased = copy.deepcopy(segments)
            aliased[1]["source_sha256"] = aliased[0]["source_sha256"]
            if alias_kind == "same_original_id":
                aliased[1]["source_recording_id"] = aliased[0]["source_recording_id"]
            with self.assertRaisesRegex(Abstain, "original_acquisition_participant_overlap"):
                train(aliased, ["train"], ["dev"], epochs=1)
        missing = copy.deepcopy(segments)
        del missing[0]["source_sha256"]
        with self.assertRaisesRegex(Abstain, "original_acquisition_identity_missing"):
            train(missing, ["train"], ["dev"], epochs=1)


if __name__ == "__main__":
    unittest.main()
