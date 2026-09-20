"""One bounded child per job, no inference thread pool, no credentials or publication client."""

from dataclasses import dataclass
import json
import os
import subprocess
import sys
import threading
import time
import tempfile
import signal

from .contracts import shadow_result


@dataclass(frozen=True)
class Limits:
    timeout_seconds: float = 30
    maximum_memory_bytes: int = 2 * 1024**3
    maximum_input_bytes: int = 16 * 1024**2
    maximum_output_bytes: int = 4 * 1024**2


class ShadowRuntime:
    def __init__(self, limits=Limits(), python=sys.executable, worker_module="physiology_inference.worker"):
        if not 0 < limits.timeout_seconds <= 300 or not 128 * 1024**2 <= limits.maximum_memory_bytes <= 8 * 1024**3:
            raise ValueError("inference resource limits invalid")
        self.limits = limits
        self.python = python
        self.worker_module = worker_module
        self._slot = threading.BoundedSemaphore(1)

    def run(self, job, model_id, activation, asset_root):
        if not self._slot.acquire(blocking=False):
            return shadow_result(job, model_id, reason="inference_busy")
        started = time.monotonic()
        try:
            payload = json.dumps({"job": job, "model_id": model_id, "activation": activation,
                                  "asset_root": str(asset_root), "limits": self.limits.__dict__}, allow_nan=False).encode()
            if len(payload) > self.limits.maximum_input_bytes:
                return shadow_result(job, model_id, reason="inference_input_limit")
            # Deliberately omit DB, B2 and cloud credentials. Only package lookup/cache roots survive.
            env = {k: os.environ[k] for k in ("PATH", "PYTHONPATH", "TMPDIR", "SYSTEMROOT") if k in os.environ}
            env.update({"OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1", "MKL_NUM_THREADS": "1",
                        "NUMEXPR_NUM_THREADS": "1", "VECLIB_MAXIMUM_THREADS": "1", "TF_NUM_INTRAOP_THREADS": "1",
                        "TF_NUM_INTEROP_THREADS": "1", "PYTHONHASHSEED": "55", "HF_HUB_OFFLINE": "1",
                        "TRANSFORMERS_OFFLINE": "1", "MPLBACKEND": "Agg"})
            with tempfile.TemporaryFile() as output_file:
                with subprocess.Popen([self.python, "-m", self.worker_module], stdin=subprocess.PIPE,
                                      stdout=output_file, stderr=subprocess.DEVNULL, env=env, start_new_session=True) as child:
                    try:
                        child.communicate(payload, timeout=self.limits.timeout_seconds)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL); child.communicate()
                        return shadow_result(job, model_id, reason="inference_timeout")
                    if child.returncode:
                        return shadow_result(job, model_id, reason="inference_worker_failed")
                output_file.seek(0)
                output = output_file.read(self.limits.maximum_output_bytes + 1)
                if len(output) > self.limits.maximum_output_bytes:
                    return shadow_result(job, model_id, reason="inference_output_limit")
                def invalid_constant(value):
                    raise ValueError("nonfinite worker output")
                result = json.loads(output, parse_constant=invalid_constant)
                if result.get("publication_mode") != "shadow" or result.get("canonical_outputs_allowed") is not False or any(
                        result.get(k) != job.get(k) for k in ("user_id", "device_id", "input_revision", "input_hash")):
                    return shadow_result(job, model_id, reason="inference_output_contract_invalid")
                result["elapsed_seconds"] = time.monotonic() - started
                result["resource_scope"] = "host_measurement_not_target_vps"
                return result
        except (ValueError, OSError, TypeError):
            return shadow_result(job, model_id, reason="inference_request_failed")
        finally:
            self._slot.release()
