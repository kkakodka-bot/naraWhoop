"""Explicit upstream adapters. Optional packages and artifacts load only after contract checks."""

import importlib.util
import math
from pathlib import Path
import sys

from .contracts import Abstain, validate_activation, validate_job, shadow_result, verify_loaded_package
from .preprocessing import detector_signal, rr_estimation, wav2sleep_ppg


def load_reviewed_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise Abstain("reviewed_module_unloadable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def lipponen_corrections(peaks, sample_rate, observed_runs, nk, maximum_passes=5):
    """Correct each observed run independently, retain every pass and original pair censor mask."""
    import numpy as np
    original = np.asarray(peaks, dtype=float)
    if len(original) < 4 or not np.all(np.isfinite(original)) or np.any(np.diff(original) <= 0):
        raise Abstain("original_peaks_invalid")
    if not math.isfinite(sample_rate) or sample_rate <= 0 or not 1 <= maximum_passes <= 10:
        raise Abstain("correction_configuration_invalid")
    ordered = sorted(observed_runs)
    if not ordered or any(not math.isfinite(a) or not math.isfinite(b) or b <= a for a, b in ordered):
        raise Abstain("observed_runs_missing")
    if any(ordered[i][0] < ordered[i - 1][1] for i in range(1, len(ordered))):
        raise Abstain("observed_runs_overlap")
    if any(sum(a <= p < b for a, b in ordered) != 1 for p in original):
        raise Abstain("peak_outside_observed_run")
    changed_original = set(); ledger = []; corrected = []
    for run_index, (lo, hi) in enumerate(ordered):
        current = original[(original >= lo) & (original < hi)].copy()
        if len(current) < 4:
            corrected.extend(current.tolist()); continue
        for pass_index in range(maximum_passes):
            before = current.copy()
            # iterative=False is deliberate: upstream returns the final iteration's artifact map.
            # Owning the bounded loop makes correction burden cumulative and auditable.
            info, after = nk.signal_fixpeaks(before, sampling_rate=sample_rate, iterative=False, method="Kubios")
            after = np.asarray(after, dtype=float)
            if not np.all(np.isfinite(after)) or np.any(np.diff(after) <= 0) or np.any(after < lo) or np.any(after >= hi):
                raise Abstain("correction_crossed_observed_run")
            removed = sorted(set(before) - set(after)); inserted = sorted(set(after) - set(before))
            classes = {k: [int(x) for x in info.get(k, [])] for k in ("ectopic", "missed", "extra", "longshort")}
            if not removed and not inserted:
                break
            affected = set()
            for sample in removed + inserted:
                pos = int(np.searchsorted(original, sample))
                affected.update(i for i in (pos - 1, pos) if 0 <= i < len(original))
            changed_original.update(affected)
            ledger.append({"run": run_index, "pass": pass_index + 1, "removed_sample_positions": removed,
                           "inserted_sample_positions": inserted, "upstream_classes": classes,
                           "affected_original_beats": sorted(affected)})
            current = after
        corrected.extend(current.tolist())
    # Pair i is RR[i]-RR[i-1], requiring original beats i-1, i and i+1 in the same observed run.
    pair_mask = [False] * max(0, len(original) - 1)
    for i in range(1, len(pair_mask)):
        pair_mask[i] = not any(j in changed_original for j in (i - 1, i, i + 1)) and any(
            lo <= original[i - 1] and original[i + 1] < hi for lo, hi in ordered)
    original_rr = np.diff(original) * 1000 / sample_rate
    differences = np.diff(original_rr)
    qualified = [float(differences[i - 1]) for i in range(1, len(pair_mask)) if pair_mask[i]]
    observed_rmssd = math.sqrt(sum(x * x for x in qualified) / len(qualified)) if qualified else None
    corrected_differences = []
    for lo, hi in ordered:
        rr = np.diff([p for p in corrected if lo <= p < hi]) * 1000 / sample_rate
        corrected_differences.extend(np.diff(rr).tolist())
    corrected_rmssd = math.sqrt(sum(x * x for x in corrected_differences) / len(corrected_differences)) if corrected_differences else None
    return {"original_peak_samples": original.tolist(), "corrected_peak_samples": corrected,
            "correction_events": ledger, "correction_event_count": sum(len(x["removed_sample_positions"]) + len(x["inserted_sample_positions"]) for x in ledger),
            "affected_original_beats": sorted(changed_original), "correction_fraction": len(changed_original) / len(original),
            "observed_pair_mask": pair_mask, "research_observed_rmssd_ms": observed_rmssd,
            "research_corrected_rmssd_ms": corrected_rmssd, "method": "neurokit-kubios-lipponen2019-bounded-passes-1",
            "diagnostic_interpretation": "rhythm_ambiguity_not_arrhythmia_diagnosis"}


def neurokit_detectors(signals, nk):
    import numpy as np
    name = "PPG" if "PPG" in signals else "ECG"
    signal = detector_signal(signals, name)
    rate = signal.sample_rate_hz
    if name == "PPG":
        cleaned = nk.ppg_clean(signal.values, sampling_rate=rate, method="elgendi")
        a = nk.ppg_findpeaks(cleaned, sampling_rate=rate, method="elgendi")["PPG_Peaks"]
        b = nk.ppg_findpeaks(cleaned, sampling_rate=rate, method="msptdfast")["PPG_Peaks"]
        peak_sets = {"elgendi": a.tolist(), "msptdfast": b.tolist()}
        tolerance = max(1, round(rate * 0.08))
        matched = 0; right = 0
        for p in a:
            while right < len(b) and int(b[right]) < int(p) - tolerance:
                right += 1
            if right < len(b) and abs(int(p) - int(b[right])) <= tolerance:
                matched += 1; right += 1
        disagreement = 1 - 2 * matched / (len(a) + len(b)) if len(a) + len(b) else 1.0
        quality = nk.ppg_quality(cleaned, sampling_rate=rate, peaks=a, method="templatematch")
        morphology = float(np.nanmean(quality))
    else:
        cleaned = nk.ecg_clean(signal.values, sampling_rate=rate, method="neurokit")
        a = nk.ecg_findpeaks(cleaned, sampling_rate=rate, method="neurokit")["ECG_R_Peaks"]
        peak_sets = {"neurokit_ecg": a.tolist()}; disagreement = None; morphology = None
    minimum, maximum = min(signal.values), max(signal.values)
    clipped_fraction = sum(x == minimum or x == maximum for x in signal.values) / len(signal.values)
    corrections = lipponen_corrections(a, rate, [(0, len(signal.values))], nk)
    return {"modality": "ppg_ibi" if name == "PPG" else "ecg_nn", "peak_sets": peak_sets,
            "detector_disagreement": disagreement, "template_morphology_similarity": morphology,
            "extreme_value_fraction": clipped_fraction, "perfusion_index": None,
            "perfusion_reason": "dc_calibration_not_available", "correction_comparison": corrections}


def execute(job, model_id, activation, asset_root):
    signals = validate_job(job)
    paths = validate_activation(activation, asset_root, model_id)
    # Ancillary qualification evidence is validated, but is not a model input asset.
    paths = {name: path for name, path in paths.items() if name != "environment_manifest"}
    output = None
    if model_id == "wav2sleep-cardiorespiratory":
        if job["mode"] != "retrospective":
            raise Abstain("noncausal_model_requires_retrospective_mode")
        import numpy as np
        import torch
        import wav2sleep
        verify_loaded_package(wav2sleep, activation.get("package_tree_sha256"))
        load_model = wav2sleep.load_model
        x = wav2sleep_ppg(signals, job.get("epochs"))
        if set(paths) != {"config", "weights"} or paths["config"].name != "config.yaml" or paths["weights"].name != "state_dict.pth" or paths["config"].parent != paths["weights"].parent:
            raise Abstain("wav2sleep_checkpoint_layout_invalid")
        torch.set_num_threads(1); torch.use_deterministic_algorithms(True)
        model = load_model(str(paths["weights"].parent), device="cpu", compile=False)
        if model.num_classes != 4 or "PPG" not in model.valid_signals:
            raise Abstain("wav2sleep_checkpoint_modality_mismatch")
        with torch.inference_mode():
            probabilities = torch.softmax(model({"PPG": torch.from_numpy(x)}), dim=-1).cpu().numpy()[0]
        if probabilities.shape != (job["epochs"], 4) or not np.isfinite(probabilities).all():
            raise Abstain("model_output_shape_invalid")
        output = {"labels": ["wake", "light", "deep", "rem"], "probabilities": probabilities.tolist(), "epoch_seconds": 30}
    elif model_id == "rr-estimation":
        x = rr_estimation(signals, job.get("preprocessing_contract"))
        import tensorflow as tf
        tf.config.threading.set_intra_op_parallelism_threads(1); tf.config.threading.set_inter_op_parallelism_threads(1)
        tf.random.set_seed(55)
        module = load_reviewed_module(paths["model_source"], "reviewed_rr_model")
        model = module.Multi_class_CNN((2048, 4)); model(tf.zeros((1, 2048, 4)))
        model.load_weights(str(paths["weights"]))
        prediction = model(x, training=False).numpy().reshape(-1)
        if len(prediction) != 1 or not math.isfinite(float(prediction[0])) or float(prediction[0]) <= 0:
            raise Abstain("model_output_invalid")
        output = {"breaths_per_minute": float(prediction[0]), "duration_seconds": 32,
                  "range_qualification": "unvalidated_target_domain_no_clamping"}
    elif model_id == "neurokit2":
        import neurokit2 as nk
        verify_loaded_package(nk, activation.get("package_tree_sha256"))
        output = neurokit_detectors(signals, nk)
    elif model_id == "feature-sleep-learner":
        import json
        from .feature_sleep import predict
        output = predict(json.loads(paths["weights"].read_text()), job.get("feature_rows", []), job["mode"])
    elif model_id == "sleepecg":
        from .comparators import sleepecg_compare
        output = sleepecg_compare(job, paths["weights"], activation.get("package_tree_sha256"))
    elif model_id == "walch-sleep-classifiers":
        from .comparators import walch_compare
        output = walch_compare(job, paths["package_entry"].parent.parent, activation.get("package_tree_sha256"))
    elif model_id == "rrest":
        from .comparators import rrest_compare
        if set(signals) != {"RESP_MODULATION"}:
            raise Abstain("rrest_modulation_contract_invalid")
        output = rrest_compare(signals["RESP_MODULATION"], paths, activation.get("octave_executable", ""))
    elif model_id == "correncoder":
        if job["mode"] != "retrospective":
            raise Abstain("noncausal_model_requires_retrospective_mode")
        import json
        from .correncoder import infer
        if set(signals) != {"PPG"} or job.get("preprocessing_contract") != "upstream_presegmented_standardized":
            raise Abstain("correncoder_preprocessing_unverified")
        output = infer(signals["PPG"], paths["weights"], json.loads(paths["training_report"].read_text()))
    else:
        raise Abstain("adapter_not_registered")
    return shadow_result(job, model_id, output=output, activation=activation)
