"""Synthetic comparison controls; no ECG-reference accuracy or reviewed activation is fabricated."""

import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from physiology_inference.correction_comparison import compare, interval_metrics, malik_mask, prediction_export, validate_input


class IdentityCorrection:
    @staticmethod
    def signal_fixpeaks(peaks, **kwargs):
        return {}, peaks


def fixture(gap=False):
    spans = [{"start_s": 0, "end_s": 140}, {"start_s": 160, "end_s": 300}] if gap else [{"start_s": 0, "end_s": 300}]
    return {"schema_version": 1, "evidence_kind": "synthetic_functional", "dataset_id": "synthetic-comparison-only",
            "recordings": [{"id": "recording", "participant_id": "participant", "source_recording_id": "original",
                "user_id": "owner", "device_id": "device", "source_sha256": "a" * 64,
                "start_s": 0, "end_s": 300, "sample_rate_hz": 1000, "timing_verified": True,
                "modality": "ppg_pulse_intervals", "observed_spans": spans,
                "peaks": [{"id": f"original:{i}", "sample_index": i * 1000} for i in range(300)
                          if not gap or i < 140 or i >= 160]}]}


class ComparisonTest(unittest.TestCase):
    def test_comparison_exports_bind_runtime_activation_and_environment(self):
        provenance = {"status": "synthetic_fixture_only", "activation_sha256": "a" * 64,
                      "environment_manifest_sha256": "b" * 64}
        report = compare(fixture(), IdentityCorrection(), runtime_provenance=provenance)
        exported = prediction_export(report, "lipponen_observed", 0.9, 0.1)
        self.assertEqual(report["runtime_provenance"], provenance)
        self.assertEqual(exported["comparison_manifest"]["runtime_provenance"], provenance)
        other = compare(fixture(), IdentityCorrection(), runtime_provenance={**provenance, "environment_manifest_sha256": "c" * 64})
        self.assertNotEqual(exported["model_manifest_sha256"], prediction_export(other, "lipponen_observed", 0.9, 0.1)["model_manifest_sha256"])
        direct = compare(fixture(), IdentityCorrection())
        self.assertEqual(direct["runtime_provenance"]["status"], "unverified_injected_backend")
        self.assertIsNone(direct["runtime_provenance"]["activation_sha256"])

    def test_same_inputs_zero_rmssd_and_all_prespecified_sweeps(self):
        report = compare(fixture(), IdentityCorrection())
        self.assertEqual(len(report["sweeps"]), 36)
        self.assertFalse(report["canonical_outputs_allowed"])
        self.assertEqual(report["reference_validation_status"], "not_run")
        for sweep in report["sweeps"]:
            self.assertEqual(sweep["accepted_windows"], 1)
            self.assertEqual(sweep["predictions"][0]["value"], 0)
        self.assertEqual(len(report["windows"][0]["original_peak_ids"]), 300)
        self.assertEqual(report["windows"][0]["methods"]["censor_only"]["valid_pair_count"], 298)
        self.assertEqual(report, compare(fixture(), IdentityCorrection()))

    def test_malik_exact_local_median_and_original_pair_masks(self):
        values = [1000, 1000, 1300, 1000, 1000]
        mask = malik_mask(values)
        self.assertEqual(mask, [True, True, False, True, True])
        self.assertEqual(malik_mask([299, 300, 2000, 2001]), [False, True, True, False])
        peaks = [0, 1000, 2000, 3300, 4300, 5300]
        metrics = interval_metrics(peaks, 1000, [(0, 6000)], mask)
        self.assertEqual(metrics["pair_mask"], [False, True, False, False, True])
        self.assertEqual(metrics["rmssd_ms"], 0)
        self.assertGreater(interval_metrics(peaks, 1000, [(0, 6000)])["rmssd_ms"], 0)

    def test_observed_coverage_sweep_and_gap_never_form_an_original_pair(self):
        report = compare(fixture(gap=True), IdentityCorrection())
        metrics = report["windows"][0]["methods"]["censor_only"]
        self.assertFalse(metrics["pair_mask"][139]); self.assertFalse(metrics["pair_mask"][140])
        for sweep in report["sweeps"]:
            self.assertEqual(sweep["accepted_windows"], int(sweep["minimum_observed_fraction"] < 0.95))
        self.assertAlmostEqual(report["windows"][0]["observed_duration_s"], 280)

    def test_cumulative_ledger_and_correction_limit_use_original_interval_denominator(self):
        class RemoveOne:
            @staticmethod
            def signal_fixpeaks(peaks, **kwargs):
                return ({"extra": [150]}, [value for value in peaks if value != 150000]) if len(peaks) == 300 else ({}, peaks)
        report = compare(fixture(), RemoveOne())
        methods = report["windows"][0]["methods"]
        observed = methods["lipponen_observed"]
        self.assertEqual(observed["affected_original_interval_indices"], [148, 149, 150])
        self.assertAlmostEqual(observed["correction_fraction"], 3 / 299)
        self.assertEqual(observed["correction_event_count"], 1)
        self.assertEqual(len(observed["correction_events"]), 1)
        self.assertEqual(methods["lipponen_corrected_research"]["pair_identity"], "corrected_research_beats")
        for sweep in report["sweeps"]:
            if sweep["method"].startswith("lipponen"):
                self.assertEqual(sweep["accepted_windows"], int(sweep["maximum_correction_fraction"] > 0))

    def test_bad_timing_identity_and_unobserved_peaks_fail_closed(self):
        for edit in (lambda r: r.update(timing_verified=False),
                     lambda r: r["peaks"][1].update(id="original:0"),
                     lambda r: r["peaks"][1].update(sample_index=0),
                     lambda r: r.update(observed_spans=[{"start_s": 10, "end_s": 300}])):
            data = fixture(); edit(data["recordings"][0])
            with self.assertRaises(ValueError):
                validate_input(data)

    def test_lipponen_failure_cannot_disable_independent_comparators(self):
        class Failed:
            @staticmethod
            def signal_fixpeaks(*args, **kwargs):
                raise RuntimeError("synthetic controlled failure")
        report = compare(fixture(), Failed())
        for sweep in report["sweeps"]:
            self.assertEqual(sweep["accepted_windows"], int(not sweep["method"].startswith("lipponen")))

    def test_prediction_export_matches_benchmark_contract_but_is_not_promotable(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "Tools" / "physiology-bench"))
        from physiology_bench.contracts import validate_predictions
        from physiology_bench.manifests import validate_model
        output = prediction_export(compare(fixture(), IdentityCorrection()), "censor_only", 0.9, 0.1)
        data = {"recordings": [{"id": "recording", "start_s": 0, "end_s": 300}]}
        self.assertEqual(validate_predictions(output, data), output)
        with self.assertRaises(ValueError):
            validate_model(output["comparison_manifest"], for_execution=True)

    def test_cli_refuses_unreviewed_activation_before_dependency_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "input.json").write_text(json.dumps(fixture()))
            (root / "activation.json").write_text("{}")
            result = subprocess.run([sys.executable, "-m", "physiology_inference.correction_comparison",
                "--input", str(root / "input.json"), "--activation", str(root / "activation.json"), "--asset-root", temp],
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertIn("shadow_activation_required", result.stderr)

    @unittest.skipUnless(importlib.util.find_spec("neurokit2"), "Pinned NeuroKit source required")
    def test_actual_pinned_lipponen_on_synthetic_variable_intervals(self):
        import neurokit2 as nk
        data = fixture(); time = 0
        for i, peak in enumerate(data["recordings"][0]["peaks"]):
            peak["sample_index"] = round(time * 1000)
            time += 1 + 0.01 * math.sin(i / 8)
        report = compare(data, nk)
        self.assertIsNone(report["windows"][0]["lipponen_unavailable_detail"])
        self.assertEqual(report["windows"][0]["methods"]["lipponen_observed"]["pair_identity"], "original_beats")
