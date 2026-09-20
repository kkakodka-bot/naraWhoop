"""Versioned adapters do not pad, bridge missing time, rename modalities, or infer units."""

import math
from .contracts import Abstain


def aligned(signals, names):
    if set(signals) != set(names):
        raise Abstain("unsupported_channel_set")
    chosen = [signals[name] for name in names]
    for signal in chosen:
        signal.require_contiguous()
    if len({x.clock_id for x in chosen}) != 1 or max(x.start for x in chosen) - min(x.start for x in chosen) > 0.002:
        raise Abstain("channels_not_time_aligned")
    return chosen


def resample(signal, target_rate, count, first_sample_offset=0.0):
    """Linear interpolation matches wav2sleep upstream; dense original samples must bracket targets."""
    import numpy as np
    signal.require_contiguous()
    if count < 1 or count > 5_000_000 or target_rate <= 0:
        raise Abstain("resample_shape_invalid")
    source_times = np.arange(len(signal.values), dtype=np.float64) / signal.sample_rate_hz
    target_times = np.arange(count, dtype=np.float64) / target_rate + first_sample_offset
    if target_times[0] < source_times[0] or target_times[-1] > source_times[-1] + 1e-9:
        raise Abstain("resampling_would_extrapolate")
    if target_rate < signal.sample_rate_hz:
        # Explicit anti-aliasing is separate from the upstream linear-only adapter version.
        raise Abstain("downsampling_requires_frozen_antialias_adapter")
    return np.interp(target_times, source_times, signal.values).astype(np.float32)


def wav2sleep_ppg(signals, epochs):
    import numpy as np
    (ppg,) = aligned(signals, ["PPG"])
    if ppg.unit not in ("adc_count", "normalized_physical_range") or ppg.wavelength_nm is None:
        raise Abstain("ppg_units_or_wavelength_unverified")
    if not 10 <= ppg.sample_rate_hz <= 1024 / 30 or not isinstance(epochs, int) or not 1 <= epochs <= 1680:
        raise Abstain("wav2sleep_input_range_unsupported")
    x = resample(ppg, 1024 / 30, epochs * 1024, first_sample_offset=30 / 1024)
    # Upstream ParquetDataset uses torch.std's sample standard deviation, eps=1e-6.
    std = float(np.std(x, ddof=1))
    if std < 1e-6:
        raise Abstain("flat_ppg")
    return ((x - np.mean(x)) / max(std, 1e-6))[None, :]


def rr_estimation(signals, preprocessing_contract):
    import numpy as np
    selected = aligned(signals, ["PPG", "ACC_X", "ACC_Y", "ACC_Z"])
    if selected[0].unit != "upstream_preprocessed" or preprocessing_contract != "rr-estimation-released-preprocessed-v1":
        # Released example starts with externally preprocessed pickle arrays. Inventing raw
        # normalization would not reproduce it. The caller must supply the frozen upstream stage.
        raise Abstain("rr_estimation_external_preprocessing_unverified")
    if selected[0].wavelength_nm is None or any(x.unit != "upstream_preprocessed" or not x.orientation for x in selected[1:]):
        raise Abstain("rr_estimation_channel_units_unverified")
    if any(x.sample_rate_hz != 64 or len(x.values) != 2048 for x in selected):
        raise Abstain("rr_estimation_requires_2048x4_at_64hz")
    return np.around(np.stack([x.values for x in selected], axis=-1), decimals=4).astype(np.float32)[None, :, :]


def detector_signal(signals, name):
    (signal,) = aligned(signals, [name])
    if name == "PPG" and (signal.unit != "adc_count" or signal.wavelength_nm is None):
        raise Abstain("ppg_units_or_wavelength_unverified")
    if name == "ECG" and signal.unit != "mV":
        raise Abstain("ecg_units_unverified")
    if len(signal.values) / signal.sample_rate_hz < 30:
        raise Abstain("detector_insufficient_duration")
    if min(signal.values) == max(signal.values):
        raise Abstain("flat_waveform")
    return signal
