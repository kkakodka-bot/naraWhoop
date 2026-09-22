#!/usr/bin/env python3
"""Prepare/build the frozen baseline plus the reviewed transport-only patch from local Git."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess

BASELINE = "5caa31689da0023e111beb36850d3f81d67e1be2"
PREFIX = "scoring-service/service/src/"
DEFAULT_BUILD_IMAGE = (
    "docker.io/library/eclipse-temurin@"
    "sha256:e573c097106f35634857604fdfbe70a2a2bbcaa52574bca3d2025703d0df994d"
)
DEFAULT_RUNTIME_IMAGE = (
    "docker.io/library/eclipse-temurin@"
    "sha256:24cd8eed18b5976441d27b45823490eb5e8efff4b3ecdc632e442717ea66f160"
)
RELEASE_PLATFORM = "linux/amd64"
IMAGE_REFERENCE = re.compile(
    r"^[a-z0-9][a-z0-9.-]*(?::[0-9]{1,5})?/"
    r"[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*"
    r"@sha256:[0-9a-f]{64}$"
)
ALLOWED = {
    PREFIX + "main/kotlin/com/frwhoop/scoring/ScoringApplication.kt",
    PREFIX + "main/kotlin/com/frwhoop/scoring/db/EngineIngestWriter.kt",
    PREFIX + "main/kotlin/com/frwhoop/scoring/db/PostgresClient.kt",
    PREFIX + "main/kotlin/com/frwhoop/scoring/db/ScoringWorkQueue.kt",
    PREFIX + "main/kotlin/com/frwhoop/scoring/derived/DerivedArtifactWriter.kt",
    PREFIX + "main/kotlin/com/frwhoop/scoring/scoring/ScoringPoller.kt",
    PREFIX + "main/kotlin/com/frwhoop/scoring/health/HeartbeatReporter.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/DerivedArtifactWriterTest.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/LegacyQueueIntegrationTest.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/LegacyTransportTest.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/PostgresClientTest.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/ScoringWorkQueueSqlTest.kt",
    PREFIX + "test/kotlin/com/frwhoop/scoring/WorkItemCompletionTest.kt",
}


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, **kwargs)


def validate_image_inputs(platform, build_image, runtime_image):
    if platform != RELEASE_PLATFORM:
        raise ValueError(f"Baseline image platform must be explicit {RELEASE_PLATFORM}")
    for label, value in (("build image", build_image), ("runtime image", runtime_image)):
        if not isinstance(value, str) or len(value) > 300 or not IMAGE_REFERENCE.fullmatch(value):
            raise ValueError(f"{label} must be a digest-qualified registry reference")
    return {
        "platform": platform,
        "build_image": build_image,
        "runtime_image": runtime_image,
    }


def docker_build_command(image, release_sha, provenance, image_inputs, dockerfile):
    return [
        "docker", "build", "--platform", image_inputs["platform"],
        "-t", image, "-f", str(dockerfile),
        "--build-arg", "RELEASE_PLATFORM=" + image_inputs["platform"],
        "--build-arg", "BUILD_IMAGE=" + image_inputs["build_image"],
        "--build-arg", "RUNTIME_IMAGE=" + image_inputs["runtime_image"],
        "--build-arg", "RELEASE_SHA=" + release_sha,
        "--build-arg", "TRANSPORT_PATCH_SHA256=" + provenance["transport_patch_sha256"],
        "--build-arg", "IDENTITY_PATCH_SHA256=" + provenance["identity_patch_sha256"],
        ".",
    ]


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


def prepare(repository, context, patch, identity_patch=None):
    head = subprocess.check_output(["git", "-C", str(repository), "rev-parse", "HEAD"], text=True).strip()
    if head != BASELINE:
        raise ValueError(f"Expected exact baseline checkout {BASELINE}; got {head}")
    # A dirty input worktree cannot leak into this context: only committed baseline bytes are archived.
    if context.exists():
        raise ValueError(f"Build context must be a new directory: {context}")
    patches = [patch] + ([identity_patch] if identity_patch is not None else [])
    numstat = b"".join(subprocess.check_output(["git", "apply", "--numstat", "-z", str(item)]) for item in patches)
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
    for item in patches:
        run(["git", "apply", "--check", str(item)], cwd=context)
        run(["git", "apply", str(item)], cwd=context)
    after = frozen_digest(context)
    if mapper_digest(context) != mapper_before:
        raise RuntimeError("Frozen baseline result mapping changed")
    if after != before:
        raise RuntimeError("A source outside the reviewed transport allowlist changed")
    provenance = {
        "baseline_commit": BASELINE,
        "transport_patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
        "identity_patch_sha256": hashlib.sha256(identity_patch.read_bytes()).hexdigest() if identity_patch else None,
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
    parser.add_argument("--release-sha", help="Exact repair source commit for immutable image identity")
    parser.add_argument("--platform", help=f"Explicit release image platform; must be {RELEASE_PLATFORM}")
    parser.add_argument("--build-image", help="Digest-qualified JDK builder image; audited default when omitted")
    parser.add_argument("--runtime-image", help="Digest-qualified JRE runtime image; audited default when omitted")
    args = parser.parse_args()
    image_inputs = None
    if args.image:
        if not args.release_sha or not re.fullmatch(r"[0-9a-f]{40}", args.release_sha):
            raise ValueError("--image requires the exact --release-sha of this repair")
        repair_root = Path(__file__).resolve().parents[2]
        for relative in ("scoring-service/legacy-baseline/build.py", "scoring-service/legacy-baseline/transport.patch",
                         "scoring-service/legacy-baseline/runtime-identity.patch", "infra/vps/templates/Dockerfile.baseline"):
            committed = subprocess.check_output(["git", "-C", str(repair_root), "show", args.release_sha + ":" + relative])
            if committed != (repair_root / relative).read_bytes():
                raise ValueError("Baseline build input differs from declared repair revision: " + relative)
        image_inputs = validate_image_inputs(
            args.platform, args.build_image or DEFAULT_BUILD_IMAGE, args.runtime_image or DEFAULT_RUNTIME_IMAGE)
    elif args.platform is not None or args.build_image is not None or args.runtime_image is not None:
        raise ValueError("Image platform/base-image options require --image")
    context = args.context.resolve()
    provenance = prepare(args.repository.resolve(), context, Path(__file__).resolve().with_name("transport.patch"),
                         Path(__file__).resolve().with_name("runtime-identity.patch"))
    if args.build or args.image:
        run(["./gradlew", "--no-daemon", "--max-workers=1", ":analytics-kernel:test", ":service:test", ":service:installDist"],
            cwd=context / "scoring-service")
        provenance["build_status"] = "built_and_repository_tests_passed"
        provenance["database_integration_environment"] = bool(os.environ.get("PHYSIOLOGY_TEST_DATABASE_URL"))
        if image_inputs is not None:
            provenance["image_build"] = image_inputs
        (context / "baseline-transport-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    if args.image:
        dockerfile = Path(__file__).resolve().parents[2] / "infra/vps/templates/Dockerfile.baseline"
        run(docker_build_command(args.image, args.release_sha, provenance, image_inputs, dockerfile), cwd=context)
    print(json.dumps(provenance, indent=2))


if __name__ == "__main__":
    main()
