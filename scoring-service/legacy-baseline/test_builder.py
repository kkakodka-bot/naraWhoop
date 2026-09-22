import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).with_name("build.py")
spec = importlib.util.spec_from_file_location("baseline_builder", MODULE_PATH)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BaselineBuilderTests(unittest.TestCase):
    def test_wrong_checkout_is_rejected_before_context_creation(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "new-context"
            with mock.patch.object(builder.subprocess, "check_output", return_value="0" * 40):
                with self.assertRaisesRegex(ValueError, "Expected exact baseline"):
                    builder.prepare(Path(scratch), output, Path(scratch) / "unused.patch")
            self.assertFalse(output.exists())

    def test_existing_context_is_preserved(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "existing"
            output.mkdir()
            marker = output / "preserve.txt"
            marker.write_text("existing work")
            with mock.patch.object(builder.subprocess, "check_output", return_value=builder.BASELINE):
                with self.assertRaisesRegex(ValueError, "new directory"):
                    builder.prepare(Path(scratch), output, Path(scratch) / "unused.patch")
            self.assertEqual("existing work", marker.read_text())

    def test_numerical_patch_is_rejected_before_context_creation(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "new-context"
            numerical_path = builder.PREFIX + "main/kotlin/com/frwhoop/scoring/scoring/DayScorer.kt"
            with mock.patch.object(builder.subprocess, "check_output", side_effect=[builder.BASELINE, ("1\t1\t" + numerical_path + "\0").encode()]):
                with self.assertRaisesRegex(ValueError, "outside the transport allowlist"):
                    builder.prepare(Path(scratch), output, Path(scratch) / "unused.patch")
            self.assertFalse(output.exists())

    def test_identity_patch_cannot_change_the_numerical_baseline(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "new-context"
            transport = builder.PREFIX + "main/kotlin/com/frwhoop/scoring/ScoringApplication.kt"
            numerical = builder.PREFIX + "main/kotlin/com/frwhoop/scoring/scoring/DayScorer.kt"
            with mock.patch.object(builder.subprocess, "check_output", side_effect=[builder.BASELINE,
                    ("1\t1\t" + transport + "\0").encode(), ("1\t1\t" + numerical + "\0").encode()]):
                with self.assertRaisesRegex(ValueError, "outside the transport allowlist"):
                    builder.prepare(Path(scratch), output, Path("transport.patch"), Path("identity.patch"))
            self.assertFalse(output.exists())

    def test_image_requires_explicit_exact_repair_revision_before_building(self):
        with mock.patch("sys.argv", ["build.py", "--repository", "/unused", "--context", "/unused-context",
                                     "--image", "fixture.invalid/baseline:reviewed"]):
            with mock.patch.object(builder, "prepare") as prepare:
                with self.assertRaisesRegex(ValueError, "exact --release-sha"):
                    builder.main()
                prepare.assert_not_called()

    def test_image_refuses_dirty_inputs_mislabeled_as_a_release(self):
        with mock.patch("sys.argv", ["build.py", "--repository", "/unused", "--context", "/unused-context",
                                     "--image", "fixture.invalid/baseline:reviewed", "--release-sha", "a" * 40]):
            with mock.patch.object(builder.subprocess, "check_output", return_value=b"different source"), \
                    mock.patch.object(builder, "prepare") as prepare:
                with self.assertRaisesRegex(ValueError, "differs from declared repair revision"):
                    builder.main()
                prepare.assert_not_called()

    def test_image_requires_explicit_audited_platform(self):
        with self.assertRaisesRegex(ValueError, "platform must be explicit linux/amd64"):
            builder.validate_image_inputs(None, builder.DEFAULT_BUILD_IMAGE, builder.DEFAULT_RUNTIME_IMAGE)
        with self.assertRaisesRegex(ValueError, "platform must be explicit linux/amd64"):
            builder.validate_image_inputs("linux/arm64", builder.DEFAULT_BUILD_IMAGE, builder.DEFAULT_RUNTIME_IMAGE)

    def test_mutable_or_malformed_base_images_are_rejected(self):
        for value in (
            "eclipse-temurin:17-jdk-jammy",
            "docker.io/library/eclipse-temurin:17-jdk-jammy",
            "docker.io/library/eclipse-temurin@sha256:" + "A" * 64,
            "docker.io/library/eclipse-temurin@sha256:" + "a" * 63,
            "docker.io/library/eclipse-temurin@sha256:" + "a" * 64 + "\n",
        ):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "digest-qualified registry reference"):
                    builder.validate_image_inputs(builder.RELEASE_PLATFORM, value, builder.DEFAULT_RUNTIME_IMAGE)

    def test_docker_build_command_passes_platform_and_both_base_digests(self):
        provenance = {
            "transport_patch_sha256": "1" * 64,
            "identity_patch_sha256": "2" * 64,
        }
        inputs = builder.validate_image_inputs(
            builder.RELEASE_PLATFORM, builder.DEFAULT_BUILD_IMAGE, builder.DEFAULT_RUNTIME_IMAGE)
        command = builder.docker_build_command(
            "fixture.invalid/baseline:reviewed", "a" * 40, provenance, inputs, Path("Dockerfile.baseline"))
        self.assertEqual(command[:4], ["docker", "build", "--platform", "linux/amd64"])
        self.assertIn("RELEASE_PLATFORM=linux/amd64", command)
        self.assertIn("BUILD_IMAGE=" + builder.DEFAULT_BUILD_IMAGE, command)
        self.assertIn("RUNTIME_IMAGE=" + builder.DEFAULT_RUNTIME_IMAGE, command)
        self.assertIn("RELEASE_SHA=" + "a" * 40, command)
        self.assertEqual(command[-1], ".")

    def test_dockerfile_defaults_match_the_audited_builder_inputs(self):
        dockerfile = MODULE_PATH.parents[2] / "infra/vps/templates/Dockerfile.baseline"
        source = dockerfile.read_text()
        self.assertIn("ARG BUILD_IMAGE=" + builder.DEFAULT_BUILD_IMAGE, source)
        self.assertIn("ARG RUNTIME_IMAGE=" + builder.DEFAULT_RUNTIME_IMAGE, source)
        self.assertIn("ARG RELEASE_PLATFORM=linux/amd64", source)
        self.assertIn("FROM --platform=${RELEASE_PLATFORM} ${BUILD_IMAGE} AS build", source)
        self.assertIn("FROM --platform=${RELEASE_PLATFORM} ${RUNTIME_IMAGE}", source)
        self.assertIn("io.frwhoop.image.platform=$RELEASE_PLATFORM", source)


if __name__ == "__main__":
    unittest.main()
