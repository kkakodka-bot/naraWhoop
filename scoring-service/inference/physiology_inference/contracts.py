"""Immutable signal, asset and shadow-output contracts; fail closed before model loading."""

from dataclasses import dataclass
from hashlib import sha256
import json
import math
from pathlib import Path
import re


class Abstain(ValueError):
    """A machine-readable input/availability failure, not a numeric estimate."""


def canonical_hash(value):
    return sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def implementation_hash():
    root = Path(__file__).parent
    files = sorted(root.glob("*.py")) + [root / "upstream-lock.json"]
    return canonical_hash({p.name: sha256(p.read_bytes()).hexdigest() for p in files})


@dataclass(frozen=True)
class Signal:
    name: str
    unit: str
    sample_rate_hz: float
    start: float
    values: tuple
    observed: tuple
    timing_verified: bool
    semantics_verified: bool
    clock_id: str
    acquisition_id: str
    orientation: str | None = None
    wavelength_nm: float | None = None

    @classmethod
    def parse(cls, data):
        required = ("name", "unit", "sample_rate_hz", "start", "values", "observed",
                    "timing_verified", "semantics_verified", "clock_id", "acquisition_id")
        if any(k not in data for k in required):
            raise Abstain("signal_contract_missing")
        if not isinstance(data["values"], list) or not isinstance(data["observed"], list):
            raise Abstain("signal_shape_invalid")
        signal = cls(**{k: tuple(data[k]) if k in ("values", "observed") else data[k] for k in required},
                     orientation=data.get("orientation"), wavelength_nm=data.get("wavelength_nm"))
        signal.validate()
        return signal

    def validate(self):
        if not isinstance(self.name, str) or not isinstance(self.unit, str):
            raise Abstain("signal_identity_invalid")
        if not isinstance(self.sample_rate_hz, (int, float)) or not math.isfinite(self.sample_rate_hz) or not 1 <= self.sample_rate_hz <= 2000:
            raise Abstain("signal_sample_rate_invalid")
        if not math.isfinite(self.start) or not 2 <= len(self.values) <= 5_000_000 or len(self.values) != len(self.observed):
            raise Abstain("signal_shape_invalid")
        if not all(type(v) is bool for v in self.observed):
            raise Abstain("mask_invalid")
        if self.timing_verified is not True or not self.clock_id or not self.acquisition_id:
            raise Abstain("signal_timing_unverified")
        if self.semantics_verified is not True:
            raise Abstain("channel_semantics_unverified")
        if not all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
                   for x, observed in zip(self.values, self.observed) if observed):
            raise Abstain("observed_sample_nonfinite")

    def require_contiguous(self):
        if not all(self.observed):
            raise Abstain("acquisition_gap")
        if not all(math.isfinite(x) for x in self.values):
            raise Abstain("signal_nonfinite")


def validate_job(job):
    required = ("user_id", "device_id", "input_revision", "input_hash", "mode", "signals")
    if any(k not in job for k in required):
        raise Abstain("job_contract_missing")
    if not all(isinstance(job[k], str) and job[k] for k in ("user_id", "device_id", "input_revision")):
        raise Abstain("job_identity_missing")
    if job["mode"] not in ("causal", "retrospective", "windowed"):
        raise Abstain("computation_mode_invalid")
    expected = canonical_hash({k: v for k, v in job.items() if k != "input_hash"})
    if job["input_hash"] != expected:
        raise Abstain("immutable_input_hash_mismatch")
    signals = [Signal.parse(x) for x in job["signals"]]
    if len(signals) > 8 or len({x.name for x in signals}) != len(signals):
        raise Abstain("duplicate_or_excess_channels")
    return {x.name: x for x in signals}


def verify_asset(asset, root):
    if not isinstance(asset, dict) or not re.fullmatch(r"[0-9a-f]{64}", asset.get("sha256", "")):
        raise Abstain("asset_hash_missing")
    root = Path(root).resolve()
    path = (root / asset.get("path", "")).resolve()
    if not path.is_relative_to(root) or not path.is_file() or path.stat().st_size > 2_000_000_000:
        raise Abstain("asset_path_invalid")
    digest = sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != asset["sha256"]:
        raise Abstain("asset_hash_mismatch")
    return path


def validate_activation(activation, root, model_id):
    if activation.get("model_id") != model_id or activation.get("publication_mode") != "shadow" or activation.get("canonical_outputs_allowed") is not False:
        raise Abstain("shadow_activation_required")
    if not re.fullmatch(r"[0-9a-f]{40}", activation.get("code_revision", "")):
        raise Abstain("code_revision_missing")
    assets = activation.get("assets", {})
    checkpoint_required = model_id in {"wav2sleep-cardiorespiratory", "rr-estimation", "feature-sleep-learner",
                                      "sleepecg", "correncoder"} or "weights" in assets
    for right in ("code", "weights", "training_data"):
        entry = activation.get("rights", {}).get(right, {})
        if entry.get("status") not in ("reviewed", "not_applicable"):
            raise Abstain(f"{right}_rights_not_reviewed")
        if (right == "code" or right == "weights" and checkpoint_required) and entry["status"] != "reviewed":
            raise Abstain(f"{right}_rights_not_reviewed")
        if not isinstance(entry.get("evidence"), str) or not entry["evidence"].strip():
            raise Abstain(f"{right}_rights_evidence_missing")
        if entry["status"] == "reviewed":
            if not isinstance(entry.get("identifier"), str) or not entry["identifier"].strip():
                raise Abstain(f"{right}_rights_identifier_missing")
        elif not isinstance(entry.get("reason"), str) or not entry["reason"].strip():
            raise Abstain(f"{right}_rights_nonapplicability_reason_missing")
    if not assets:
        raise Abstain("execution_assets_missing")
    paths = {name: verify_asset(asset, root) for name, asset in assets.items()}
    for field in ("preprocess_version", "quality_policy_version"):
        if not activation.get(field):
            raise Abstain("pipeline_version_missing")
    if activation.get("implementation_sha256") != implementation_hash():
        raise Abstain("adapter_implementation_hash_mismatch")
    if "environment_manifest" not in paths:
        raise Abstain("environment_manifest_missing")
    from .environment import verify as verify_environment
    environment_path = paths["environment_manifest"]
    if environment_path.stat().st_size > 1024**2:
        raise Abstain("environment_manifest_too_large")
    environment = json.loads(environment_path.read_text())
    verify_environment(environment, model_id, activation.get("environment_review"),
                       {"octave": activation["octave_executable"]} if model_id == "rrest" and activation.get("octave_executable") else None)
    pinned = json.loads((Path(__file__).parent / "upstream-lock.json").read_text())["models"].get(model_id)
    if pinned:
        if activation["code_revision"] != pinned["code_revision"]:
            raise Abstain("upstream_code_revision_mismatch")
        if pinned.get("package_tree_sha256") and activation.get("package_tree_sha256") != pinned["package_tree_sha256"]:
            raise Abstain("upstream_package_hash_mismatch")
        if model_id == "rr-estimation" and (assets.get("weights", {}).get("sha256") != pinned["checkpoint_sha256"] or
                                           assets.get("model_source", {}).get("sha256") != pinned["source_sha256"]):
            raise Abstain("released_rr_assets_mismatch")
    return paths


def verify_loaded_package(module, expected_hash):
    """Hash upstream Python sources; the separate environment manifest binds installed native files."""
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash or ""):
        raise Abstain("installed_package_hash_missing")
    root = Path(module.__file__).resolve().parent
    inventory = {str(path.relative_to(root)): sha256(path.read_bytes()).hexdigest() for path in sorted(root.rglob("*.py"))}
    if canonical_hash(inventory) != expected_hash:
        raise Abstain("installed_package_hash_mismatch")


def shadow_result(job, model_id, output=None, reason=None, activation=None):
    return {"schema_version": 1, "model_id": model_id, "publication_mode": "shadow",
            "canonical_outputs_allowed": False, "user_id": job.get("user_id"), "device_id": job.get("device_id"),
            "input_revision": job.get("input_revision"), "input_hash": job.get("input_hash"),
            "computation_mode": job.get("mode"), "status": "abstained" if reason else "complete",
            "reason": reason, "output": output, "activation_hash": canonical_hash(activation) if activation else None,
            "probabilities_calibrated": False,
            "code_revision": activation.get("code_revision") if activation else None,
            "preprocess_version": activation.get("preprocess_version") if activation else None,
            "quality_policy_version": activation.get("quality_policy_version") if activation else None}
