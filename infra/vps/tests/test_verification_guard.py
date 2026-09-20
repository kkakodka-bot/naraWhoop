"""Exercise exact-head guards in disposable Git repositories, never the working checkout."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scoring-service/scripts/verify-physiology-candidate.sh"


class VerificationGuardTest(unittest.TestCase):
    def run_fixture(self, mode="clean", gate="edge", before_untracked=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            repo.mkdir()
            files = {
                ".gitignore": "ignored.out\n**/build/\n",
                "supabase/functions/fixture": "synthetic\n",
                "docs/physiology-v2/candidate-algorithm-manifests.json": "{}\n",
                "scoring-service/gradlew": '''#!/bin/sh
printf '%s\\n' "$@" > "$FIXTURE_ROOT/gradle-args"
[ "$FIXTURE_MODE" != build-fails ] || exit 7
touch "$FIXTURE_ROOT/fresh-build"
if [ "$FIXTURE_MODE" = kernel-snapshot ]; then
  for project in analytics-kernel service; do
    mkdir -p "$FIXTURE_REPO/scoring-service/$project/build/test-results/test"
    printf '<testsuite tests="1" skipped="0" failures="0"/>\\n' > "$FIXTURE_REPO/scoring-service/$project/build/test-results/test/TEST-fixture.xml"
  done
fi
''',
            }
            for name, value in files.items():
                path = repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(value)
            (repo / "scoring-service/gradlew").chmod(0o755)
            copied = repo / "scoring-service/scripts/verify-physiology-candidate.sh"
            copied.parent.mkdir(parents=True)
            shutil.copyfile(SCRIPT, copied)
            binary = root / "bin"
            binary.mkdir()
            stubs = {
                "npx": '''#!/bin/sh
touch "$FIXTURE_ROOT/invoked"
case "$FIXTURE_MODE" in
  untracked) touch "$FIXTURE_REPO/new_source.py" ;;
  ignored) touch "$FIXTURE_REPO/ignored.out" ;;
  changed-head) git -C "$FIXTURE_REPO" commit --quiet --allow-empty -m fixture-change ;;
esac
''',
                "java": '''#!/bin/sh
[ -f "$FIXTURE_ROOT/fresh-build" ] || exit 9
touch "$FIXTURE_ROOT/java-invoked"
printf '{}\\n'
''',
            }
            for name, value in stubs.items():
                path = binary / name
                path.write_text(value)
                path.chmod(0o755)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()
            git("init", "--quiet")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            git("add", ".")
            git("commit", "--quiet", "-m", "fixture")
            revision = git("rev-parse", "HEAD")
            if before_untracked:
                (repo / "new_source.py").write_text("synthetic\n")
            environment = os.environ.copy()
            environment.update(PATH=str(binary) + os.pathsep + environment["PATH"],
                               FIXTURE_ROOT=str(root), FIXTURE_REPO=str(repo), FIXTURE_MODE=mode,
                               PHYSIOLOGY_BUILD_ROOT=str(root / "build"), PHYSIOLOGY_PACKAGE_CACHE=str(root / "packages"),
                               PHYSIOLOGY_PYTHON=sys.executable, PHYSIOLOGY_PR_BASE=revision, TMPDIR=str(root))
            result = subprocess.run(["bash", str(copied), gate], env=environment, capture_output=True,
                                    text=True, timeout=15)
            if gate == "kernel" and result.returncode == 0:
                for suite in ("kernel-junit", "service-junit"):
                    copied_results = list(root.glob("physiology-exact-head.*/" + suite + "/TEST-fixture.xml"))
                    self.assertEqual(len(copied_results), 1)
                    self.assertIn('tests="1"', copied_results[0].read_text())
            if mode in ("untracked", "changed-head"):
                self.assertNotIn("\tPASS", result.stdout)
            args = root / "gradle-args"
            return result, (root / "invoked").exists(), (root / "java-invoked").exists(), args.read_text() if args.exists() else ""

    def test_untracked_source_before_gate_is_rejected(self):
        result, invoked, _, _ = self.run_fixture(before_untracked=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(invoked)
        self.assertIn("Commit all candidate sources", result.stderr)

    def test_untracked_source_created_by_gate_invalidates_exact_head(self):
        result, invoked, _, _ = self.run_fixture(mode="untracked")
        self.assertEqual(result.returncode, 2)
        self.assertTrue(invoked)
        self.assertIn("Candidate changed", result.stderr)

    def test_ignored_build_products_are_not_source_drift(self):
        result, invoked, _, _ = self.run_fixture(mode="ignored")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(invoked)

    def test_head_change_is_rejected_even_with_clean_tree(self):
        result, invoked, _, _ = self.run_fixture(mode="changed-head")
        self.assertEqual(result.returncode, 2)
        self.assertTrue(invoked)

    def test_manifest_gate_refreshes_distribution_before_using_java(self):
        result, _, java, args = self.run_fixture(gate="manifests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(java)
        self.assertIn(":service:installDist", args)
        self.assertIn("--rerun-tasks", args)

    def test_failed_manifest_build_never_uses_old_distribution(self):
        result, _, java, _ = self.run_fixture(mode="build-fails", gate="manifests")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(java)

    def test_kernel_results_are_snapshotted_outside_overwritten_gradle_output(self):
        result, _, _, args = self.run_fixture(mode="kernel-snapshot", gate="kernel")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(":analytics-kernel:test", args)
        self.assertIn(":service:test", args)


if __name__ == "__main__":
    unittest.main()
