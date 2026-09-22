#!/usr/bin/env python3
"""Release C-codec measurements on synthetic data; no phone or account data is read."""
import argparse
import base64
import hashlib
import json
import platform
from pathlib import Path
import random
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
CODEC = ROOT / "Packages/NoopPush/Sources/CNoopZstd"
GOLDEN = ROOT / "Packages/NoopPush/Tests/NoopPushTests/Resources/zstd-1.5.7-golden.json"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def corpora():
    scalar = b"".join((json.dumps({"source_index": i, "synthetic_channel": i % 3,
                                  "synthetic_reading": i % 128}, separators=(",", ":")) + "\n").encode()
                      for i in range(32_000))
    waveform = bytearray()
    rng = random.Random(1729)
    for i in range(500_000):
        waveform.extend(struct.pack("<hh", i % 4096 + rng.randrange(-3, 4), (i // 24) % 1024))
    return {"synthetic_scalar_ndjson": scalar, "synthetic_packed_waveform": bytes(waveform),
            "synthetic_incompressible": random.Random(104729).randbytes(2 * 1_048_576)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--write-goldens", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        raise SystemExit("Keep benchmark artifacts outside the repository")
    output.mkdir(parents=True, exist_ok=True)
    binary = output / "codec-benchmark"
    sources = [CODEC / "noop_zstd.c", ROOT / "Tools/compression/benchmark.c"]
    for folder in ("common", "compress", "decompress"):
        sources.extend(sorted((CODEC / "vendor/zstd/lib" / folder).glob("*.c")))
    command = ["cc", "-O3", "-DNDEBUG", "-DZSTD_DISABLE_ASM=1", "-DZSTD_LEGACY_SUPPORT=0", "-DZSTD_TRACE=0",
               "-I" + str(CODEC / "include"), "-I" + str(CODEC / "vendor/zstd/lib"),
               *map(str, sources), "-o", str(binary)]
    subprocess.run(command, check=True)
    results = []
    for name, data in corpora().items():
        source = output / (name + ".bin")
        source.write_bytes(data)
        for level in (1, 3):
            destination = output / (name + f".level-{level}.zst")
            measurement = json.loads(subprocess.check_output([str(binary), str(source), str(level), "100", str(destination)]))
            measurement.update(corpus=name, input_sha256=digest(data), wire_sha256=digest(destination.read_bytes()),
                               wire_ratio=measurement["wire_bytes"] / len(data),
                               prior_raw_frame_bytes=10 + 3 * max(1, (len(data) + 131071) // 131072) + len(data))
            results.append(measurement)
    manifest = {"schema_version": 1, "generated_unix": int(time.time()),
                "git_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "source_sha256": {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in sources},
                "platform": {"os": platform.system(), "version": platform.mac_ver()[0], "architecture": platform.machine()},
                "build": "Release C -O3, single thread, vendored zstd 1.5.7", "data": "synthetic only",
                "physical_energy": "NOT_MEASURED", "physical_thermal": "NOT_MEASURED",
                "iphone_cpu_rss": "NOT_MEASURED", "measurements": results}
    (output / "benchmark.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    if args.write_goldens:
        vectors = []
        values = {"empty": b"", "synthetic_repetition": b"NARA synthetic codec compatibility fixture\n" * 256,
                  "synthetic_bytes": random.Random(19).randbytes(4096)}
        for name, data in values.items():
            source = output / (name + ".golden.bin")
            source.write_bytes(data)
            vector = {"name": name, "decoded_base64": base64.b64encode(data).decode(), "decoded_sha256": digest(data), "frames": []}
            for level in (1, 3):
                destination = output / (name + f".golden.level-{level}.zst")
                subprocess.run([str(binary), str(source), str(level), "1", str(destination)], check=True, stdout=subprocess.DEVNULL)
                wire = destination.read_bytes()
                vector["frames"].append({"level": level, "wire_base64": base64.b64encode(wire).decode(), "wire_sha256": digest(wire)})
            vectors.append(vector)
        GOLDEN.write_text(json.dumps({"codec": "zstd", "upstream_version": "1.5.7", "vectors": vectors}, indent=2) + "\n")
    print(json.dumps({"benchmark": str(output / "benchmark.json"), "measurements": len(results)}))


if __name__ == "__main__":
    main()
