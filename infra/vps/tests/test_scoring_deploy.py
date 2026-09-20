"""Exercise the remote deployment script with a disposable filesystem and fake Docker."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/deploy-scoring-service.sh"
SHA = "a" * 40
RUN_ID = SHA + "-123-456"


class ScoringDeployTest(unittest.TestCase):
    def run_remote(self, fail_preflight=False, missing_hosted_key=False, missing_b2=False,
                   invalid_compose=False, fail_acceptance=False, fail_start=False, fail_rename=False,
                   foreign_fixed_name=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / "frwhoop"
            build = base / "build/frwhoop-scoring" / RUN_ID
            (build / "infra/vps/templates").mkdir(parents=True)
            (build / "infra/vps/scripts/remote").mkdir(parents=True)
            (build / "infra/vps/templates/docker-compose.scoring-override.yml").write_text("services: {}\n")
            (build / "infra/vps/scripts/remote/verify-scoring-runtime.sh").write_text(
                'test "$1" = "' + SHA + '" || exit 2\n'
                'echo acceptance >> "$DOCKER_LOG"\n'
                'test "$FAIL_ACCEPTANCE" != 1\n')
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
            (binary_dir / "flock").write_text("#!/bin/sh\nexit 0\n")
            (binary_dir / "flock").chmod(0o755)
            state_path = root / "state.json"
            initial_state = {
                "old-v2": {"name": "scoring-physiology-v2", "running": True, "version": "frwhoop-physiology-2"},
                "old-v1": {"name": "scoring", "running": True, "version": "frwhoop-server-1"},
                "other-project": {"name": "other-project", "running": True, "version": "frwhoop-physiology-2"},
            }
            if foreign_fixed_name:
                initial_state['old-v2']['name'] = 'legacy-scoring'
                initial_state['other-project']['name'] = 'scoring-physiology-v2'
            state_path.write_text(json.dumps(initial_state))
            docker = binary_dir / "docker"
            docker.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
state_path = pathlib.Path(os.environ['DOCKER_STATE'])
state = json.loads(state_path.read_text())
def identifier(value):
    if value in state: return value
    return next((key for key, item in state.items() if item['name'] == value), None)
def save(): state_path.write_text(json.dumps(state))
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
    assert args.count('-f') == 1
    assert args[args.index('-f') + 1] == 'docker-compose.yml'
    sys.exit(1 if os.environ['INVALID_COMPOSE'] == '1' else 0)
elif args[0] == 'compose' and 'up' in args:
    assert not any(s['name'] == 'scoring-physiology-v2' for s in state.values())
    assert not any(s['version'] == 'frwhoop-physiology-2' and s['running'] for k, s in state.items() if k != 'other-project')
    state['new-v2'] = {'name': 'scoring-physiology-v2', 'running': True, 'version': 'frwhoop-physiology-2',
                       'project': args[args.index('-p') + 1]}
    save()
    sys.exit(1 if os.environ['FAIL_START'] == '1' else 0)
elif args[0] == 'ps':
    print('\\n'.join(key for key, item in state.items() if '-aq' in args or item['running']))
elif args[0] == 'inspect':
    key = identifier(args[-1])
    if key is None: sys.exit(1)
    if '.Config.Env' in args[2]:
        print('SCORING_ALGORITHM_VERSION=' + state[key]['version'])
        print('SUPABASE_URL=https://' + ('different' if key == 'other-project' else 'project') + '.supabase.co/rest/v1')
    elif 'org.opencontainers.image.revision' in args[2]:
        print('a' * 40)
    elif 'com.docker.compose.project' in args[2]: print(state[key].get('project', 'legacy-project'))
    elif '.Id' in args[2]:
        print(key)
    elif '.Name' in args[2]: print('/' + state[key]['name'])
    elif '.State.Running' in args[2]: print(str(state[key]['running']).lower())
elif args[0] == 'rename':
    if os.environ['FAIL_RENAME'] == '1' and '-rollback-' in args[2]: sys.exit(1)
    key = identifier(args[1])
    assert key is not None
    assert not any(s['name'] == args[2] for k, s in state.items() if k != key)
    state[key]['name'] = args[2]; save()
elif args[0] in ['start', 'stop']:
    key = identifier(args[1]); assert key is not None
    state[key]['running'] = args[0] == 'start'; save()
elif args[0] == 'rm':
    for value in args[1:]:
        if value.startswith('-'): continue
        key = identifier(value); assert key is not None
        assert key not in ['old-v1', 'other-project']
        if key == 'old-v2':
            assert 'acceptance' in pathlib.Path(os.environ['DOCKER_LOG']).read_text()
            assert os.environ['FAIL_ACCEPTANCE'] == '0'
        del state[key]
    save()
""")
            docker.chmod(0o755)
            remote = SCRIPT.read_text().split("<<'REMOTE'\n", 1)[1].split("\nREMOTE\n", 1)[0]
            remote = remote.replace('BASE="/opt/frwhoop"', 'BASE="' + str(base) + '"')
            env = os.environ.copy()
            env.update(PATH=str(binary_dir) + os.pathsep + env["PATH"],
                       DOCKER_LOG=str(root / "docker.jsonl"),
                       DOCKER_STATE=str(state_path),
                       FAIL_PREFLIGHT="1" if fail_preflight else "0",
                       FAIL_ACCEPTANCE="1" if fail_acceptance else "0",
                       FAIL_START="1" if fail_start else "0",
                       FAIL_RENAME="1" if fail_rename else "0",
                       INVALID_COMPOSE="1" if invalid_compose else "0")
            # The deployed host uses modern Bash; macOS also has Homebrew Bash for mapfile.
            bash = "/opt/homebrew/bin/bash" if Path("/opt/homebrew/bin/bash").exists() else "bash"
            result = subprocess.run([bash, "-s", "--", SHA, RUN_ID], input=remote, text=True,
                                    capture_output=True, env=env, timeout=15)
            log_path = root / "docker.jsonl"
            commands = [json.loads(line) for line in log_path.read_text().splitlines() if line != "acceptance"] if log_path.exists() else []
            self.final_state = json.loads(state_path.read_text())
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
        self.assertEqual(commands[removed], ["rm", "old-v2"])
        self.assertIn("SUPABASE_SERVICE_ROLE_KEY=hosted-key\n", config)
        self.assertNotIn("wrong-local", config)
        self.assertFalse(pending_exists)
        self.assertEqual(set(self.final_state), {"old-v1", "new-v2", "other-project"})
        self.assertTrue(self.final_state["other-project"]["running"])

    def test_failed_cutover_restores_previous_worker_and_env(self):
        for failure in [{"fail_acceptance": True}, {"fail_start": True}, {"fail_rename": True}]:
            with self.subTest(failure=failure):
                result, commands, config, pending_exists = self.run_remote(**failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(config, "existing-worker-config\n")
                self.assertFalse(pending_exists)
                self.assertEqual(set(self.final_state), {"old-v1", "old-v2", "other-project"})
                self.assertEqual(self.final_state["old-v2"]["name"], "scoring-physiology-v2")
                self.assertTrue(self.final_state["old-v2"]["running"])
                self.assertTrue(self.final_state["old-v1"]["running"])

    def test_missing_final_env_file_and_bad_compose_preserve_running_worker(self):
        for failure in [{"missing_b2": True}, {"invalid_compose": True}]:
            with self.subTest(failure=failure):
                result, commands, config, pending_exists = self.run_remote(**failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("rm", [args[0] for args in commands])
                self.assertEqual(config, "existing-worker-config\n")
                self.assertFalse(pending_exists)

    def test_foreign_fixed_name_is_rejected_before_any_worker_changes(self):
        result, commands, config, pending_exists = self.run_remote(foreign_fixed_name=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config, "existing-worker-config\n")
        self.assertFalse(pending_exists)
        self.assertFalse(any(args[0] in ['stop', 'rename', 'rm', 'start'] for args in commands))
        self.assertEqual(self.final_state['other-project']['name'], 'scoring-physiology-v2')
        self.assertTrue(self.final_state['other-project']['running'])

    def test_missing_hosted_key_never_falls_back_to_self_hosted_key(self):
        result, commands, config, pending_exists = self.run_remote(missing_hosted_key=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SCORING_SUPABASE_SERVICE_ROLE_KEY", result.stderr)
        self.assertEqual(commands, [])
        self.assertEqual(config, "existing-worker-config\n")
        self.assertFalse(pending_exists)


if __name__ == "__main__":
    unittest.main()
