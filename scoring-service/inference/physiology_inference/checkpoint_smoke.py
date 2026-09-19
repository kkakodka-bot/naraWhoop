"""Offline synthetic execution of a released checkpoint, never an activation or accuracy evaluation."""
import argparse
from hashlib import sha256
import json
import math
from pathlib import Path
import platform
import resource
import sys
import time

from .adapters import wav2sleep_predict
from .contracts import Abstain, Signal, canonical_hash, verify_asset, implementation_hash


def run(checkpoint_root, epochs=20):
    if not 1 <= epochs <= 1680:
        raise Abstain("smoke_duration_invalid")
    lock = json.loads((Path(__file__).parent / "upstream-lock.json").read_text())["models"]["wav2sleep-cardiorespiratory"]
    paths = {name: verify_asset({"path": filename, "sha256": lock[key]}, checkpoint_root) for name, filename, key in
             (("weights", "state_dict.pth", "checkpoint_sha256"), ("config", "config.yaml", "config_sha256"))}
    rate = 24; count = epochs * 30 * rate + 1
    signal = Signal.parse({"name": "PPG", "unit": "adc_count", "sample_rate_hz": rate, "start": 0,
        "values": [round(1000 * math.sin(2 * math.pi * i / rate) + 100 * math.sin(2 * math.pi * .2 * i / rate)) for i in range(count)],
        "observed": [True] * count, "timing_verified": True, "semantics_verified": True, "clock_id": "synthetic-clock",
        "acquisition_id": "synthetic-no-person-no-reference", "wavelength_nm": 525})
    began = time.monotonic(); usage = resource.getrusage(resource.RUSAGE_SELF)
    first = wav2sleep_predict({"PPG": signal}, epochs, paths, lock["package_tree_sha256"])
    second = wav2sleep_predict({"PPG": signal}, epochs, paths, lock["package_tree_sha256"])
    after = resource.getrusage(resource.RUSAGE_SELF)
    if first != second:
        raise Abstain("checkpoint_smoke_nondeterministic")
    gapped = Signal(**{**signal.__dict__, "observed": tuple(False if i == count // 2 else True for i in range(count))})
    try:
        wav2sleep_predict({"PPG": gapped}, epochs, paths, lock["package_tree_sha256"])
    except Abstain as failure:
        if str(failure) != "acquisition_gap":
            raise
    else:
        raise AssertionError("gapped input must abstain")
    return {"schema_version": 1, "model_id": "wav2sleep-cardiorespiratory", "publication_mode": "shadow",
        "canonical_outputs_allowed": False, "evidence_kind": "synthetic_checkpoint_execution_not_reference_validation",
        "checkpoint_sha256": lock["checkpoint_sha256"], "config_sha256": lock["config_sha256"],
        "implementation_sha256": implementation_hash(), "upstream_code_revision": lock["code_revision"],
        "epochs": epochs, "repeated_exact_output": True, "gap_rejected": True, "output_sha256": canonical_hash(first),
        "elapsed_seconds_two_runs": time.monotonic() - began,
        "cpu_seconds_two_runs": after.ru_utime + after.ru_stime - usage.ru_utime - usage.ru_stime,
        "maximum_rss_bytes": after.ru_maxrss if sys.platform == "darwin" else after.ru_maxrss * 1024,
        "host": {"system": platform.system(), "machine": platform.machine(), "python": platform.python_version()},
        "target_vps": False, "activation_qualified": False, "reference_accuracy": None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint-root", required=True); parser.add_argument("--output", required=True)
    parser.add_argument("--epochs", type=int, default=20)
    args = parser.parse_args()
    result = run(args.checkpoint_root, args.epochs)
    with Path(args.output).open("x") as stream:
        json.dump(result, stream, sort_keys=True, indent=2, allow_nan=False); stream.write("\n")


if __name__ == "__main__":
    main()
