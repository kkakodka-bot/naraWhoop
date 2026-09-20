"""Participant-explicit reproduction of the released MSE CorrEncoder, not an invented checkpoint.

Architecture: Harry J Davies, 2023, MIT, revision 70689270bd68f10dedf41acbe7d252dcee709614.
The released script uses MSE. This adapter does not label that training objective correlation loss.
"""

from .contracts import Abstain, canonical_hash
import math
import re


def model():
    import torch.nn as nn
    return nn.Sequential(
        nn.Conv1d(1, 8, 150, padding=20), nn.ReLU(), nn.Dropout(0.5),
        nn.Conv1d(8, 8, 75, padding=20), nn.ReLU(), nn.Dropout(0.5),
        nn.Conv1d(8, 8, 50, padding=10), nn.Sigmoid(), nn.Dropout(0.5),
        nn.ConvTranspose1d(8, 8, 50, padding=10), nn.Sigmoid(),
        nn.ConvTranspose1d(8, 8, 75, padding=20), nn.ReLU(),
        nn.ConvTranspose1d(8, 1, 150, padding=20),
    )


def train(segments, training_participants, development_participants, epochs=80, batch_size=30, seed=55):
    """Presegmented standardized PPG/reference rows require explicit participant, timing and rights."""
    import numpy as np
    import torch
    if set(training_participants) & set(development_participants) or not training_participants or not development_participants:
        raise Abstain("participant_split_overlap_or_empty")
    if not 1 <= epochs <= 1000 or not 1 <= batch_size <= 256:
        raise Abstain("training_limits_invalid")
    seen = set(); lengths = set(); rates = set()
    source_owners = {}; source_hashes = {}; hash_owners = {}
    for row in segments:
        if row.get("participant") not in set(training_participants) | set(development_participants):
            raise Abstain("unassigned_training_participant")
        source = row.get("source_recording_id")
        source_hash = row.get("source_sha256")
        if not isinstance(source, str) or not source.strip() or not isinstance(source_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", source_hash):
            raise Abstain("correncoder_original_acquisition_identity_missing")
        participant = row["participant"]
        if source_owners.get(source, participant) != participant or hash_owners.get(source_hash, participant) != participant:
            raise Abstain("correncoder_original_acquisition_participant_overlap")
        if source_hashes.get(source, source_hash) != source_hash:
            raise Abstain("correncoder_original_acquisition_hash_conflict")
        source_owners[source] = participant; source_hashes[source] = source_hash; hash_owners[source_hash] = participant
        if not all(isinstance(row.get(k), (int, float)) and not isinstance(row[k], bool) and math.isfinite(row[k]) for k in ("start", "end")) or row["end"] <= row["start"]:
            raise Abstain("correncoder_sample_timing_invalid")
        if row.get("reference_source") not in ("capnography", "airflow", "respiratory_effort") or row.get("rights_reviewed") is not True:
            raise Abstain("reference_or_dataset_rights_unverified")
        if row.get("preprocessing") != "upstream_presegmented_standardized" or row.get("observed_complete") is not True:
            raise Abstain("correncoder_preprocessing_unverified")
        if not isinstance(row.get("sample_rate_hz"), (int, float)) or not 1 <= row["sample_rate_hz"] <= 2000 or abs(
                (row["end"] - row["start"]) * row["sample_rate_hz"] - len(row["ppg"])) > 1e-6:
            raise Abstain("correncoder_sample_timing_invalid")
        rates.add(row["sample_rate_hz"])
        key = (source_hash, row["start"], row["end"])
        if key in seen or len(row["ppg"]) != len(row["reference"]) or len(row["ppg"]) < 175:
            raise Abstain("correncoder_segment_invalid")
        seen.add(key); lengths.add(len(row["ppg"]))
        if not np.isfinite(row["ppg"]).all() or not np.isfinite(row["reference"]).all():
            raise Abstain("correncoder_nonfinite")
    if len(lengths) != 1 or len(rates) != 1:
        raise Abstain("correncoder_mixed_lengths")
    torch.set_num_threads(1); torch.manual_seed(seed); torch.use_deterministic_algorithms(True)
    train_rows = [r for r in segments if r["participant"] in training_participants]
    dev_rows = [r for r in segments if r["participant"] in development_participants]
    if not train_rows or not dev_rows:
        raise Abstain("empty_participant_partition")
    x = torch.tensor(np.array([r["ppg"] for r in train_rows], dtype=np.float32)[:, None, :])
    y = torch.tensor(np.array([r["reference"] for r in train_rows], dtype=np.float32)[:, None, :])
    dx = torch.tensor(np.array([r["ppg"] for r in dev_rows], dtype=np.float32)[:, None, :])
    dy = torch.tensor(np.array([r["reference"] for r in dev_rows], dtype=np.float32)[:, None, :])
    candidate = model(); optimizer = torch.optim.Adam(candidate.parameters(), lr=0.001); loss_fn = torch.nn.MSELoss()
    history = []; best = None; best_loss = float("inf")
    for epoch in range(epochs):
        candidate.train()
        order = torch.randperm(len(x), generator=torch.Generator().manual_seed(seed + epoch))
        for indices in order.split(batch_size):
            optimizer.zero_grad(); loss = loss_fn(candidate(x[indices]), y[indices]); loss.backward(); optimizer.step()
        candidate.eval()
        with torch.inference_mode():
            dev_loss = float(loss_fn(candidate(dx), dy))
        history.append(dev_loss)
        if dev_loss < best_loss:
            best_loss = dev_loss; best = {k: v.detach().clone() for k, v in candidate.state_dict().items()}
    candidate.load_state_dict(best)
    return candidate, {"experiment": "correncoder-released-mse-participant-split-1", "loss": "MSE", "seed": seed,
                       "training_participants": sorted(training_participants), "development_participants": sorted(development_participants),
                       "input_hash": canonical_hash(segments), "development_mse": history, "publication_mode": "shadow",
                       "original_acquisition_owners": source_owners, "original_acquisition_sha256": source_hashes,
                       "target_reference_validation": "not_run", "released_checkpoint_claimed": False,
                       "sample_rate_hz": next(iter(rates)), "samples_per_segment": next(iter(lengths))}


def infer(signal, weights, report):
    import torch
    signal.require_contiguous()
    if report.get("experiment") != "correncoder-released-mse-participant-split-1" or signal.unit != "upstream_preprocessed" or signal.wavelength_nm is None:
        raise Abstain("correncoder_training_or_preprocessing_unverified")
    if signal.sample_rate_hz != report.get("sample_rate_hz") or len(signal.values) != report.get("samples_per_segment"):
        raise Abstain("correncoder_training_inference_shape_mismatch")
    torch.set_num_threads(1); torch.manual_seed(report["seed"]); torch.use_deterministic_algorithms(True)
    candidate = model(); candidate.load_state_dict(torch.load(weights, map_location="cpu", weights_only=True)); candidate.eval()
    with torch.inference_mode():
        reconstructed = candidate(torch.tensor(signal.values, dtype=torch.float32)[None, None, :]).reshape(-1)
    if len(reconstructed) != len(signal.values) or not torch.isfinite(reconstructed).all():
        raise Abstain("correncoder_output_invalid")
    return {"respiratory_waveform": reconstructed.tolist(), "sample_rate_hz": signal.sample_rate_hz,
            "breaths_per_minute": None, "rate_reason": "requires_separately_qualified_spectral_estimator",
            "training_report": report, "released_checkpoint_claimed": False}
