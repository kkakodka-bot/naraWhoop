"""Exercise the remote deployment script with a disposable filesystem and fake Docker."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/deploy-scoring-service.sh"
SHA = "a" * 40


class ScoringDeployTest(unittest.TestCase):
    def run_remote(self, fail_preflight=False, missing_hosted_key=False, missing_b2=False, invalid_compose=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / "frwhoop"
            (base / "build/frwhoop-scoring").mkdir(parents=True)
            (base / "supabase-docker/docker").mkdir(parents=True)
            secrets = (
                "SCORING_DATABASE_URL='postgresql://postgres.project:password@pooler.supabase.com/postgres'\n"
                "SCORING_SUPABASE_URL='https://project.supabase.co/rest/v1'\n"
                "SCORING_INGEST_SECRET='hosted-ingest'\n"
                "INGEST_SECRET='wrong-local-ingest'\n"
                "SERVICE_ROLE_KEY='wrong-local-key'\n"
            )
            if not missing_hosted_key:
                secrets += "SCORING_SUPABASE_SERVICE_ROLE_KEY='hosted-key'\n"
            (base / "secrets.env").write_text(secrets)
            (base / "scoring.env").write_text("existing-worker-config\n")
            if not missing_b2:
                (base / "b2.env").write_text("B2_BUCKET_NAME=fixture-bucket\n")
            binary_dir = root / "bin"
            binary_dir.mkdir()
            docker = binary_dir / "docker"
            docker.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['DOCKER_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[0] == 'run':
    env_files = [pathlib.Path(args[i + 1]) for i, arg in enumerate(args) if arg == '--env-file']
    assert len(env_files) == 2
    if not all(p.is_file() for p in env_files): sys.exit(1)
    env_path = pathlib.Path(args[args.index('--env-file') + 1])
    env = dict(line.split('=', 1) for line in env_path.read_text().splitlines())
    assert env['SUPABASE_SERVICE_ROLE_KEY'] == 'hosted-key'
    assert env['INGEST_SECRET'] == 'hosted-ingest'
    assert args[-1] == '--check-config'
    sys.exit(1 if os.environ['FAIL_PREFLIGHT'] == '1' else 0)
elif args[0] == 'compose' and 'config' in args:
    assert pathlib.Path(os.environ['SCORING_ENV_FILE']).is_file()
    sys.exit(1 if os.environ['INVALID_COMPOSE'] == '1' else 0)
elif args[0] == 'ps':
    print('old-v2\\nold-v1' if '-aq' in args else 'new-v2')
elif args[0] == 'inspect':
    if '.Config.Env' in args[2]:
        print('SCORING_ALGORITHM_VERSION=' + ('frwhoop-server-1' if args[-1] == 'old-v1' else 'frwhoop-physiology-2'))
    elif 'org.opencontainers.image.revision' in args[2]:
        print('a' * 40)
    elif '.Id' in args[2]:
        print('new-v2')
""")
            docker.chmod(0o755)
            remote = SCRIPT.read_text().split("<<'REMOTE'\n", 1)[1].split("\nREMOTE\n", 1)[0]
            remote = remote.replace('BASE="/opt/frwhoop"', 'BASE="' + str(base) + '"')
            env = os.environ.copy()
            env.update(PATH=str(binary_dir) + os.pathsep + env["PATH"],
                       DOCKER_LOG=str(root / "docker.jsonl"),
                       FAIL_PREFLIGHT="1" if fail_preflight else "0",
                       INVALID_COMPOSE="1" if invalid_compose else "0")
            # The deployed host uses modern Bash; macOS also has Homebrew Bash for mapfile.
            bash = "/opt/homebrew/bin/bash" if Path("/opt/homebrew/bin/bash").exists() else "bash"
            result = subprocess.run([bash, "-s", "--", SHA], input=remote, text=True,
                                    capture_output=True, env=env, timeout=15)
            log_path = root / "docker.jsonl"
            commands = [json.loads(line) for line in log_path.read_text().splitlines()] if log_path.exists() else []
            return result, commands, (base / "scoring.env").read_text(), (base / "scoring.env.new").exists()

    def test_rejected_preflight_preserves_worker_and_previous_configuration(self):
        result, commands, config, pending_exists = self.run_remote(fail_preflight=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([args[0] for args in commands], ["build", "run"])
        self.assertEqual(config, "existing-worker-config\n")
        self.assertFalse(pending_exists)

    def test_success_uses_hosted_secrets_and_checks_before_replacing_only_v2(self):
        result, commands, config, pending_exists = self.run_remote()
        self.assertEqual(result.returncode, 0, result.stderr)
        checked = next(i for i, args in enumerate(commands) if args[0] == "run")
        removed = next(i for i, args in enumerate(commands) if args[0] == "rm")
        composed = next(i for i, args in enumerate(commands) if args[0] == "compose" and "config" in args)
        self.assertLess(checked, removed)
        self.assertLess(composed, removed)
        self.assertEqual(commands[removed], ["rm", "-f", "old-v2"])
        self.assertIn("SUPABASE_SERVICE_ROLE_KEY=hosted-key\n", config)
        self.assertNotIn("wrong-local", config)
        self.assertFalse(pending_exists)

    def test_missing_final_env_file_and_bad_compose_preserve_running_worker(self):
        for failure in [{"missing_b2": True}, {"invalid_compose": True}]:
            with self.subTest(failure=failure):
                result, commands, config, pending_exists = self.run_remote(**failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("rm", [args[0] for args in commands])
                self.assertEqual(config, "existing-worker-config\n")
                self.assertFalse(pending_exists)

    def test_missing_hosted_key_never_falls_back_to_self_hosted_key(self):
        result, commands, config, pending_exists = self.run_remote(missing_hosted_key=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SCORING_SUPABASE_SERVICE_ROLE_KEY", result.stderr)
        self.assertEqual(commands, [])
        self.assertEqual(config, "existing-worker-config\n")
        self.assertFalse(pending_exists)


if __name__ == "__main__":
    unittest.main()
