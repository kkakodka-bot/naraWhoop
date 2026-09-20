"""Versioned, optional research comparators. No four-stage invention or license workaround."""

import importlib
import math
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace

from .contracts import Abstain, verify_loaded_package


def sleepecg_compare(job, checkpoint, package_hash):
    import numpy as np
    import sleepecg
    verify_loaded_package(sleepecg, package_hash)
    beats = job.get("beat_times", {})
    values = np.array(beats.get("seconds", []), dtype=float)
    if beats.get("modality") != "ecg_nn" or beats.get("timing_verified") is not True or beats.get("observed_complete") is not True:
        raise Abstain("sleepecg_requires_verified_ecg_beat_times")
    if len(values) < 300 or not np.isfinite(values).all() or np.any(np.diff(values) <= 0):
        raise Abstain("sleepecg_beat_times_invalid")
    if job["mode"] != "retrospective":
        raise Abstain("noncausal_model_requires_retrospective_mode")
    if checkpoint.suffix != ".zip":
        raise Abstain("sleepecg_checkpoint_shape_invalid")
    clf = sleepecg.load_classifier(checkpoint.stem, classifiers_dir=str(checkpoint.parent))
    if clf.stages_mode not in ("wake-sleep", "wake-rem-nrem"):
        raise Abstain("sleepecg_unqualified_stage_vocabulary")
    # Force feature extraction serially; no package-default multiprocessing inside our bounded worker.
    clf.feature_extraction_params["n_jobs"] = 1
    record = sleepecg.SleepRecord(heartbeat_times=values, id=job["input_hash"])
    probabilities = sleepecg.stage(clf, record, return_mode="prob")
    expected_columns = 3 if clf.stages_mode == "wake-sleep" else 4
    if probabilities.ndim != 2 or probabilities.shape[1] != expected_columns or not np.isfinite(probabilities).all():
        raise Abstain("sleepecg_output_invalid")
    # Class zero is UNDEFINED; do not renormalize it away or split NREM into light/deep.
    labels = ["unknown", "sleep_unstaged", "wake"] if clf.stages_mode == "wake-sleep" else ["unknown", "nrem_unsplit", "rem", "wake"]
    return {"labels": labels, "probabilities": probabilities.tolist(), "four_stage_eligible": False,
            "modality": "ecg_nn", "ppg_transfer_qualified": False}


def walch_compare(job, source_root, package_hash):
    """Use upstream feature/label assembly with a serial logistic comparator, no published-score claim."""
    if job.get("mode") != "retrospective":
        raise Abstain("noncausal_model_requires_retrospective_mode")
    import numpy as np
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler
    source_root = Path(source_root).resolve()
    sys.path.insert(0, str(source_root))
    try:
        import source
        verify_loaded_package(source, package_hash)
        builder = importlib.import_module("source.analysis.classification.classifier_input_builder").ClassifierInputBuilder
        training = job.get("training_participants", []); testing = job.get("testing_participants", [])
        if not training or not testing or set(training) & set(testing):
            raise Abstain("walch_participant_split_invalid")
        features = job.get("feature_names", [])
        if not features or len(features) > 100:
            raise Abstain("walch_feature_contract_missing")
        subjects = {}
        for row in job.get("subjects", []):
            if row.get("label_source") != "independent_psg" or row.get("preprocessing_version") != "walch-upstream-features-v1":
                raise Abstain("walch_reference_or_preprocessing_unverified")
            values = np.array(row["features"], dtype=float); labels = np.array(row["psg_stage_codes"], dtype=int)
            if values.ndim != 2 or values.shape[1] != len(features) or len(labels) != len(values) or not np.isfinite(values).all() or not np.isin(labels, [0, 1, 2, 3, 4, 5]).all():
                raise Abstain("walch_feature_shape_invalid")
            if row["participant"] in subjects:
                raise Abstain("walch_duplicate_participant")
            subjects[row["participant"]] = SimpleNamespace(feature_dictionary={name: values[:, i] for i, name in enumerate(features)}, labeled_sleep=labels)
        if set(subjects) != set(training) | set(testing):
            raise Abstain("walch_unassigned_participant")
        three_class = job.get("stage_mode") == "wake-nrem-rem"
        if job.get("stage_mode") not in ("wake-sleep", "wake-nrem-rem"):
            raise Abstain("walch_stage_mode_invalid")
        build = builder.get_three_class_inputs if three_class else builder.get_sleep_wake_inputs
        train_x, train_y = build(training, subjects, features); test_x, test_y = build(testing, subjects, features)
        classifier = make_pipeline(StandardScaler(), LogisticRegression(class_weight="balanced", max_iter=1000, random_state=55))
        classifier.fit(train_x, train_y.ravel())
        probabilities = classifier.predict_proba(test_x)
        expected = [0, 1, 2] if three_class else [0, 1]
        if list(classifier.classes_) != expected:
            raise Abstain("walch_training_classes_incomplete")
        return {"labels": ["wake", "nrem_unsplit", "rem"] if three_class else ["wake", "sleep_unstaged"],
                "probabilities": probabilities.tolist(), "reference_labels": test_y.reshape(-1).tolist(),
                "four_stage_eligible": False, "variant": "upstream-feature-assembly-serial-logistic-1",
                "training_participants": training, "testing_participants": testing}
    finally:
        sys.path.remove(str(source_root))


def rrest_compare(signal, paths, octave_executable, timeout=20):
    """Invoke unmodified pinned MATLAB/Octave FTS and ACF paths; no GPL source is copied here."""
    import numpy as np
    from scipy.io import loadmat, savemat
    signal.require_contiguous()
    if signal.name != "RESP_MODULATION" or signal.unit != "arbitrary_verified" or signal.sample_rate_hz % 4 != 0 or signal.sample_rate_hz < 8:
        raise Abstain("rrest_modulation_contract_invalid")
    if set(paths) != {"fts", "acf", "spectral_peak"} or len({p.parent for p in paths.values()}) != 1:
        raise Abstain("rrest_reviewed_source_layout_invalid")
    if any(paths[k].name != name for k, name in (("fts", "FTS.m"), ("acf", "ACF.m"), ("spectral_peak", "find_spectral_peak.m"))):
        raise Abstain("rrest_reviewed_source_layout_invalid")
    if not Path(octave_executable).is_file():
        raise Abstain("rrest_octave_unavailable")
    duration = len(signal.values) / signal.sample_rate_hz
    if not 32 <= duration <= 300:
        raise Abstain("rrest_duration_invalid")
    with tempfile.TemporaryDirectory(prefix="physiology-rrest-") as temporary:
        source = Path(temporary) / "input.mat"; output = Path(temporary) / "output.mat"
        savemat(source, {"rel_data": {"v": np.asarray(signal.values)[:, None],
                                       "t": (np.arange(len(signal.values)) / signal.sample_rate_hz)[:, None], "fs": signal.sample_rate_hz},
                         "wins": {"t_start": 0.0, "t_end": duration}, "up": {"paramSet": {"fft_resample_freq": 4, "rr_range": [4, 40]}}})
        quote = lambda p: str(p).replace("'", "''")
        expression = f"pkg load signal; addpath('{quote(paths['fts'].parent)}'); load('{quote(source)}'); fts=FTS(rel_data,wins,up); acf=ACF(rel_data,wins,up); save('-mat7-binary','{quote(output)}','fts','acf');"
        try:
            subprocess.run([str(octave_executable), "--quiet", "--no-gui", "--eval", expression],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=timeout, check=True)
        except (subprocess.SubprocessError, OSError):
            raise Abstain("rrest_execution_failed") from None
        decoded = loadmat(output, simplify_cells=True)
        estimates = {name: float(decoded[name]["v"]) for name in ("fts", "acf")}
        if not all(math.isfinite(v) and 4 < v < 40 for v in estimates.values()):
            raise Abstain("rrest_out_of_supported_range")
        return {"breaths_per_minute": estimates, "publication_mode": "shadow", "method": "unmodified-rrest-fts-acf",
                "license_boundary": "separate_process_does_not_remove_gpl_obligations"}
