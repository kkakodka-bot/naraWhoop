#!/usr/bin/env python3
"""Prepare/build the frozen baseline plus the reviewed transport-only patch from local Git."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

BASELINE = "5caa31689da0023e111beb36850d3f81d67e1be2"
PREFIX = "scoring-service/service/src/"
ALLOWED = {
    PREFIX + "main/kotlin/com/frwhoop/scoring/ScoringApplication.kt",
    PREFIX + "main/kotlin/com/frwhoop/scoring/db/EngineIngestWriter.kt",
    PREFIX + "main/kotlin/com/frwhoop/scoring/db/ScoringWorkQueue.kt",
    PREFIX + "main/kotlin/com/frwhoop/scoring/derived/DerivedArtifactWriter.kt",
    PREFIX + "main/kotlin/com/frwhoop/scoring/scoring/ScoringPoller.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/DerivedArtifactWriterTest.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/LegacyQueueIntegrationTest.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/LegacyTransportTest.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/ScoringWorkQueueSqlTest.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/WorkItemCompletionTest.kt",
}


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, **kwargs)


def frozen_digest(context):
    """Every baseline tracked file outside the transport allowlist remains byte-identical."""
    digest = hashlib.sha256()
    for path in sorted(context.rglob("*")):
        relative = path.relative_to(context).as_posix()
        if not path.is_file() or relative in ALLOWED:
            continue
        encoded = relative.encode()
        data = path.read_bytes()
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def mapper_digest(context):
    source = (context / PREFIX / "main/kotlin/com/frwhoop/scoring/db/EngineIngestWriter.kt").read_bytes()
    mapper = source.split(b"    companion object {", 1)[1].split(b"\n    fun write", 1)[0]
    return hashlib.sha256(mapper).hexdigest()


def prepare(repository, context, patch):
    head = subprocess.check_output(["git", "-C", str(repository), "rev-parse", "HEAD"], text=True).strip()
    if head != BASELINE:
        raise ValueError(f"Expected exact baseline checkout {BASELINE}; got {head}")
    # A dirty input worktree cannot leak into this context: only committed baseline bytes are archived.
    if context.exists():
        raise ValueError(f"Build context must be a new directory: {context}")
    numstat = subprocess.check_output(["git", "apply", "--numstat", "-z", str(patch)])
    changed = set()
    for record in numstat.decode().split("\0"):
        if record:
            changed.add(record.split("\t", 2)[2])
    if not changed or not changed <= ALLOWED:
        raise ValueError(f"Patch changes paths outside the transport allowlist: {sorted(changed - ALLOWED)}")
    context.mkdir(parents=True)
    archive = subprocess.Popen(["git", "-C", str(repository), "archive", BASELINE], stdout=subprocess.PIPE)
    try:
        run(["tar", "-x", "-C", str(context)], stdin=archive.stdout)
    finally:
        archive.stdout.close()
    if archive.wait() != 0:
        raise RuntimeError("Baseline git archive failed")
    before = frozen_digest(context)
    mapper_before = mapper_digest(context)
    run(["git", "apply", "--check", str(patch)], cwd=context)
    run(["git", "apply", str(patch)], cwd=context)
    after = frozen_digest(context)
    if mapper_digest(context) != mapper_before:
        raise RuntimeError("Frozen baseline result mapping changed")
    if after != before:
        raise RuntimeError("A source outside the reviewed transport allowlist changed")
    provenance = {
        "baseline_commit": BASELINE,
        "transport_patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
        "frozen_files_sha256": before,
        "baseline_result_mapper_sha256": mapper_before,
        "changed_paths": sorted(changed),
        "algorithm_version": "frwhoop-server-1",
        "canonical_math_changed": False,
        "build_status": "prepared_not_built",
        "deployment_status": "not_deployed",
    }
    (context / "baseline-transport-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True, help="Local checkout whose HEAD is the exact baseline")
    parser.add_argument("--context", type=Path, required=True, help="New isolated output directory; never overwritten")
    parser.add_argument("--build", action="store_true", help="Run baseline kernel/service tests and installDist")
    parser.add_argument("--image", help="Also build this local Docker image after Gradle succeeds; never push it")
    args = parser.parse_args()
    context = args.context.resolve()
    provenance = prepare(args.repository.resolve(), context, Path(__file__).resolve().with_name("transport.patch"))
    if args.build or args.image:
        run(["./gradlew", "--no-daemon", "--max-workers=1", ":analytics-kernel:test", ":service:test", ":service:installDist"],
            cwd=context / "scoring-service")
        provenance["build_status"] = "built_and_repository_tests_passed"
        provenance["database_integration_environment"] = bool(os.environ.get("PHYSIOLOGY_TEST_DATABASE_URL"))
        (context / "baseline-transport-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    if args.image:
        run(["docker", "build", "-t", args.image, "-f", "scoring-service/Dockerfile", "."], cwd=context)
    print(json.dumps(provenance, indent=2))


if __name__ == "__main__":
    main()
