"""Single-request local worker protocol. Standard output is one bounded JSON result."""

import contextlib
import json
import math
import os
import resource
import sys

from .contracts import Abstain, shadow_result


def main():
    raw = sys.stdin.buffer.read(16 * 1024**2 + 1)
    if len(raw) > 16 * 1024**2:
        raise ValueError("input exceeds worker limit")
    request = json.loads(raw)
    limits = request["limits"]
    cpu = max(1, math.ceil(limits["timeout_seconds"]))
    resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu + 1))
    resource.setrlimit(resource.RLIMIT_FSIZE, (limits["maximum_output_bytes"], limits["maximum_output_bytes"]))
    memory_enforced = sys.platform.startswith("linux")
    if memory_enforced:
        resource.setrlimit(resource.RLIMIT_AS, (limits["maximum_memory_bytes"], limits["maximum_memory_bytes"]))
    job, model_id, activation = request["job"], request["model_id"], request["activation"]
    try:
        with contextlib.redirect_stdout(sys.stderr):
            from .adapters import execute
            result = execute(job, model_id, activation, request["asset_root"])
    except Abstain as failure:
        result = shadow_result(job, model_id, reason=str(failure), activation=activation)
    except ImportError:
        result = shadow_result(job, model_id, reason="optional_dependency_unavailable", activation=activation)
    except Exception:
        result = shadow_result(job, model_id, reason="model_execution_failed", activation=activation)
    result["memory_limit_enforced"] = memory_enforced
    usage = resource.getrusage(resource.RUSAGE_SELF)
    result["peak_rss_platform_units"] = usage.ru_maxrss
    result["cpu_user_seconds"] = usage.ru_utime
    result["cpu_system_seconds"] = usage.ru_stime
    result["rss_unit"] = "bytes" if sys.platform == "darwin" else "kilobytes"
    encoded = json.dumps(result, sort_keys=True, allow_nan=False).encode()
    if len(encoded) > limits["maximum_output_bytes"]:
        encoded = json.dumps(shadow_result(job, model_id, reason="inference_output_limit")).encode()
    sys.stdout.buffer.write(encoded)


if __name__ == "__main__":
    main()
