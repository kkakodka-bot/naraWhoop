#!/usr/bin/env python3
"""Bounded synthetic NPB1 transport-cost probe; it never measures physiological accuracy."""

import argparse
import gzip
import hashlib
import json
import math
import platform
import random
import resource
import statistics
import struct
import subprocess
import sys
import time
import tracemalloc
from pathlib import Path

VERSION = "sensor-transport-capacity-fixture-1"
SECONDS = 300


def fixture(kind, entropy):
    if kind not in (1, 4) or entropy not in ("periodic", "random"):
        raise ValueError("unsupported fixture")
    width = 24 if kind == 1 else 600
    generator = random.Random(55)
    data = bytearray(struct.pack("<4sBBI", b"NPB1", 2 if kind == 1 else 1, kind, SECONDS))
    for second in range(SECONDS):
        data.extend(struct.pack("<qq", second + 1, second))
        if kind == 1:
            data.extend(struct.pack("<Bq", 0, second))
        values = [generator.randint(-32768, 32767) if entropy == "random"
                  else ((second * width + sample) % 200) - 100 for sample in range(width)]
        samples = struct.pack(f"<{width}h", *values)
        data.extend(struct.pack("<I", len(samples)))
        data.extend(samples)
    return bytes(data), width * SECONDS


def validate_container(payload):
    magic, version, kind, records = struct.unpack_from("<4sBBI", payload)
    if magic != b"NPB1" or (version, kind) not in ((2, 1), (1, 4)) or records != SECONDS:
        raise ValueError("fixture header invalid")
    offset, samples = 10, 0
    for second in range(records):
        row, timestamp = struct.unpack_from("<qq", payload, offset)
        offset += 16
        if row != second + 1 or timestamp != second:
            raise ValueError("fixture identity invalid")
        if kind == 1:
            burst, index = struct.unpack_from("<Bq", payload, offset)
            if burst or index != second:
                raise ValueError("fixture PPG identity invalid")
            offset += 9
        size = struct.unpack_from("<I", payload, offset)[0]
        offset += 4
        if size != (48 if kind == 1 else 1200) or offset + size > len(payload):
            raise ValueError("fixture payload shape invalid")
        samples += size // 2
        offset += size
    if offset != len(payload):
        raise ValueError("fixture trailing bytes")
    return samples


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def measure(kind, entropy, iterations):
    raw, expected_samples = fixture(kind, entropy)
    digest = hashlib.sha256(raw).hexdigest()
    compressed = gzip.compress(raw, compresslevel=6, mtime=0)

    def decode():
        decoded = gzip.decompress(compressed)
        if hashlib.sha256(decoded).hexdigest() != digest or validate_container(decoded) != expected_samples:
            raise ValueError("fixture readback mismatch")

    for _ in range(3):
        decode()
    wall, cpu = [], []
    for _ in range(iterations):
        start_wall, start_cpu = time.perf_counter(), time.process_time()
        decode()
        cpu.append(time.process_time() - start_cpu)
        wall.append(time.perf_counter() - start_wall)
    tracemalloc.start()
    decode()
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    return {
        "stream": "ppgWaveformSample" if kind == 1 else "imuRawSample", "fixture_entropy": entropy,
        "synthetic_window_seconds": SECONDS, "records": SECONDS, "signed_count_values": expected_samples,
        "assumed_rate_hz": 24 if kind == 1 else 100, "assumed_channel_count": 1 if kind == 1 else 6,
        "rate_is_hardware_measurement": False, "raw_sha256": digest,
        "uncompressed_bytes": len(raw), "compressed_bytes": len(compressed),
        "compressed_to_raw_ratio": len(compressed) / len(raw), "measured_iterations": iterations,
        "readback_wall_seconds_p50": statistics.median(wall), "readback_wall_seconds_p95": percentile(wall, .95),
        "readback_wall_seconds_p99": percentile(wall, .99), "readback_cpu_seconds_mean": statistics.mean(cpu),
        "python_traced_peak_bytes_separate_readback": peak,
        "measurement_scope": "python_gzip_decompress_sha256_and_fixture_record_shape_only",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=16)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 64:
        parser.error("iterations must be between 1 and 64")
    repository = Path(__file__).resolve().parents[2]
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    source_digest = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    output = {
        "schema_version": 1, "benchmark_version": VERSION, "evidence_kind": "local_synthetic_transport_probe",
        "repository_base_revision": revision, "benchmark_source_sha256": source_digest,
        "python_version": platform.python_version(), "os": platform.system(), "os_release": platform.release(),
        "architecture": platform.machine(), "scenarios": [measure(kind, entropy, args.iterations)
            for kind in (1, 4) for entropy in ("periodic", "random")],
        "not_measured": ["jvm_decoder", "sensor_acquisition_proof", "physiological_estimator", "database",
                         "object_network_io", "phone_battery", "reference_accuracy", "target_vps", "fleet_concurrency"],
        "target_vps_capacity": "NOT_MEASURED", "production_activation_allowed": False,
    }
    usage = resource.getrusage(resource.RUSAGE_SELF)
    output["whole_process_peak_rss_bytes"] = int(usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024))
    print(json.dumps(output, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
