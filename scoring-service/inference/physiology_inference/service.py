"""JVM process bridge: one JSON request and one bounded shadow response; no network service."""
import json
import sys

from .runtime import Limits, ShadowRuntime


def main():
    encoded = sys.stdin.buffer.read(16 * 1024**2 + 1)
    if len(encoded) > 16 * 1024**2:
        raise ValueError("request exceeds limit")
    request = json.loads(encoded)
    result = ShadowRuntime(Limits(**request.get("limits", {}))).run(
        request["job"], request["model_id"], request["activation"], request["asset_root"])
    sys.stdout.write(json.dumps(result, allow_nan=False, sort_keys=True))


if __name__ == "__main__":
    main()
