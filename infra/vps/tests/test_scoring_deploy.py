"""Run the remote deployment payload against stateful disposable Docker/DB doubles."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

VPS = Path(__file__).resolve().parents[1]
SCRIPT = VPS / "scripts/deploy-scoring-service.sh"
SHA = "a" * 40

DOCKER = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
base = pathlib.Path(os.environ['FIXTURE_ROOT'])
state_file = base / 'docker-state.json'
state = json.loads(state_file.read_text())
scenario = os.environ['SCENARIO']
with (base / 'docker.jsonl').open('a') as log: log.write(json.dumps(args) + '\n')
def save(): state_file.write_text(json.dumps(state))
def lookup(name):
    for key, row in state['containers'].items():
        if name in (key, row['name']): return key, row
    sys.exit(1)
if args[0] == 'run' and '--check-config' in args:
    paths = [pathlib.Path(args[i+1]) for i, arg in enumerate(args) if arg == '--env-file']
    assert len(paths) == 2
    if not all(p.is_file() for p in paths): sys.exit(1)
    env = dict(line.split('=', 1) for line in paths[0].read_text().splitlines())
    assert env['SUPABASE_SERVICE_ROLE_KEY'] == 'hosted-key'
    assert env['INGEST_SECRET'] == 'hosted-ingest'
    assert env['SCORING_WORKER_SOURCE_REVISION'] == 'a'*40
    import uuid
    assert str(uuid.UUID(env['SCORING_WORKER_INSTANCE_ID'])) == env['SCORING_WORKER_INSTANCE_ID']
    state['candidate_env'] = env; save()
    assert args[-1] == '--check-config'
    sys.exit(1 if scenario == 'preflight' else 0)
elif args[0] == 'compose':
    assert args.count('-f') == 1 and '-p' in args
    assert args[args.index('-p')+1].startswith('frwhoop-scoring-')
    assert os.environ['SCORING_CPUS'] == '2.0' and os.environ['SCORING_MEMORY_LIMIT'] == '2g'
    if 'config' in args:
        assert pathlib.Path(os.environ['SCORING_ENV_FILE']).is_file()
        sys.exit(1 if scenario == 'compose-config' else 0)
    assert 'run' in args and '--no-deps' in args and '--name' in args
    assert not any(row['name'] == 'scoring-physiology-v2' for row in state['containers'].values())
    assert not state['containers']['old-v2']['running']
    if scenario in ('foreign-create-race', 'foreign-create-success-race'):
        state['containers']['racing-foreign'] = dict(name='scoring-physiology-v2', running=True,
            version='frwhoop-physiology-2', mode='[]', project='unrelated-compose-project')
        save(); sys.exit(1 if scenario == 'foreign-create-race' else 0)
    state['containers']['new-v2'] = dict(name='scoring-physiology-v2', running=True, version='frwhoop-physiology-2',
        mode='[]', project=args[args.index('-p')+1])
    save()
    sys.exit(1 if scenario == 'compose-start' else 0)
elif args[0] == 'ps':
    for key,row in state['containers'].items():
        if '--filter' in args and row['name'] != 'scoring-physiology-v2': continue
        if '-aq' in args or row['running']: print(key)
elif args[0] == 'inspect':
    key,row = lookup(args[-1])
    if '-f' not in args: sys.exit(0)
    field = args[args.index('-f')+1]
    if '.Config.Env' in field:
        print('SCORING_ALGORITHM_VERSION=' + row['version'])
        if key == 'new-v2':
            environment = dict(state['candidate_env'])
            if scenario == 'wrong-database': environment['DATABASE_URL'] = 'postgresql://private-token@db/postgres'
            if scenario == 'wrong-rest': environment['SUPABASE_URL'] = 'https://different-project.invalid/rest/v1'
            if scenario == 'wrong-worker': environment['SCORING_WORKER_INSTANCE_ID'] = '11111111-1111-4111-8111-111111111111'
            if scenario == 'wrong-source': environment['SCORING_WORKER_SOURCE_REVISION'] = 'b'*40
            if scenario == 'missing-worker': environment.pop('SCORING_WORKER_INSTANCE_ID')
            for name,value in environment.items(): print(name + '=' + value)
        else:
            print('SUPABASE_URL=https://' + ('foreign' if key == 'foreign' else 'project') + '.supabase.co/rest/v1')
    elif '.Config.Cmd' in field: print(row['mode'])
    elif '.State.Running' in field: print(str(row['running'] and not (key == 'new-v2' and scenario == 'crash')).lower())
    elif '.RestartCount' in field: print(1 if scenario == 'restarts' else 0)
    elif 'org.opencontainers.image.revision' in field: print('b'*40 if scenario == 'wrong-image' else 'a'*40)
    elif 'com.docker.compose.project' in field: print(row.get('project','prior-project'))
    elif '.Name' in field: print('/' + row['name'])
    elif '.Id' in field: print(key)
    elif '.Image' in field: print('sha256:' + 'a'*64)
    else: raise AssertionError(field)
elif args[0] == 'stop':
    key,row = lookup(args[-1]); row['running'] = False; save()
    sys.exit(1 if scenario == 'stop-failed' else 0)
elif args[0] == 'rename':
    key,row = lookup(args[1])
    if any(item['name'] == args[2] for other,item in state['containers'].items() if other != key): sys.exit(1)
    if scenario == 'rename-failed' and args[2].startswith('scoring-rollback-'): sys.exit(1)
    row['name'] = args[2]; save()
    if scenario == 'rename-applied-then-failed' and args[2].startswith('scoring-rollback-'): sys.exit(1)
elif args[0] == 'start':
    key,row = lookup(args[-1]); row['running'] = True; save()
elif args[0] == 'rm':
    key,_ = lookup(args[-1]); assert key == 'new-v2'; del state['containers'][key]; save()
elif args[0] == 'port':
    if scenario == 'ports': print('8080/tcp -> 0.0.0.0:8080')
elif args[0] == 'run' and 'psql' in args:
    body = sys.stdin.read()
    assert os.environ['PGPASSWORD'] == 'password' and os.environ['PGHOST'] == 'pooler.supabase.com'
    assert 'default_transaction_read_only=on' in os.environ['PGOPTIONS']
    assert 'public.physiology_worker_heartbeats' in body and 'public.physiology_work_items' in body
    assert 'public.physiology_service_heartbeats' not in body
    assert 'worker_instance_id=' + state['candidate_env']['SCORING_WORKER_INSTANCE_ID'] in args
    assert 'source_revision=' + 'a'*40 in args
    assert "algorithm_version=:'algorithm_version' limit 2" in body
    assert 'algorithm_version=frwhoop-physiology-2' in args
    assert "status in ('pending','running','retry','exhausted')" in body
    assert 'next_attempt_at<=clock_timestamp()' in body and 'lease_expires_at>clock_timestamp()' in body
    if scenario == 'database': sys.exit(1)
    state['snapshots'] += 1; n = state['snapshots']; save()
    if n > 1 and scenario == 'bad-snapshot': print('private unparseable response'); sys.exit(0)
    poll = (n-1)*10
    score = 0
    debt = scenario in ('debt', 'live-lease', 'no-publication', 'late-debt')
    if scenario == 'late-debt' and n == 1: debt = False
    if scenario == 'debt' and n > 2: score = 20
    if scenario == 'live-lease' and n > 3: score = 30
    if scenario == 'stale-poll': poll = 10
    if scenario == 'score-only': poll = 0; score = n*10
    if scenario == 'future-poll': poll = 2000
    processes = 1
    process_id = '33333333-3333-4333-8333-333333333333'
    if n == 1 or scenario == 'another-worker': processes = 0; process_id = 'none'; poll = 0; score = 0
    if n > 1 and scenario == 'two-processes': processes = 2; process_id = 'none'; poll = 0; score = 0
    if n > 2 and scenario == 'process-changed': process_id = '44444444-4444-4444-8444-444444444444'
    publication = 11 if score > 0 else 10
    print('|'.join(map(str,[processes,process_id,poll,score,'t',int(debt),0,0,0,publication,1000,0,0])))
elif args[0] == 'image' and args[1] == 'inspect': print('sha256:' + 'a'*64)
elif args[0] == 'update':
    key,row = lookup(args[-1]); assert key == 'new-v2' and args[-1] == key
    if scenario == 'restart-policy': sys.exit(1)
elif args[0] != 'build': raise AssertionError(args)
'''


class ScoringDeployTest(unittest.TestCase):
    def run_remote(self, scenario="idle", missing_hosted_key=False, missing_b2=False, missing_database=False,
                   previous_running=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / "frwhoop"
            build = base / "build/frwhoop-scoring" / SHA
            (build / "infra/vps/scripts").mkdir(parents=True)
            (build / "infra/vps/scripts/remote").mkdir()
            (build / "infra/vps/templates").mkdir(parents=True)
            shutil.copy(VPS / "scripts/scoring-progress.sh", build / "infra/vps/scripts")
            shutil.copy(VPS / "scripts/remote/verify-scoring-runtime.sh", build / "infra/vps/scripts/remote")
            shutil.copy(VPS / "scripts/scoring-hosted-query.py", build / "infra/vps/scripts")
            shutil.copy(VPS / "scripts/remote/read-scoring-query.sh", build / "infra/vps/scripts/remote")
            shutil.copy(VPS / "templates/docker-compose.scoring-override.yml", build / "infra/vps/templates")
            compose = base / "scoring/docker-compose.yml"
            compose.parent.mkdir(parents=True)
            compose.write_text("previous-compose\n")
            secrets = (
                "SCORING_DATABASE_URL='postgresql://postgres.project:password@pooler.supabase.com/postgres'\n"
                "SCORING_SUPABASE_URL='https://project.supabase.co/rest/v1'\n"
                "SCORING_INGEST_SECRET='hosted-ingest'\n"
                "INGEST_SECRET='wrong-local-ingest'\nSERVICE_ROLE_KEY='wrong-local-key'\n"
                "SCORING_ACCEPT_SECONDS=15\n"
                "SCORING_BASELINE_IMAGE=fixture.invalid/baseline@sha256:" + 'a'*64 + "\n"
            )
            if not missing_hosted_key:
                secrets += "SCORING_SUPABASE_SERVICE_ROLE_KEY='hosted-key'\n"
            if missing_database:
                secrets = "\n".join(line for line in secrets.splitlines() if not line.startswith('SCORING_DATABASE_URL=')) + "\n"
            (base / "secrets.env").write_text(secrets)
            (base / "scoring.env").write_text("existing-worker-config\n")
            if not missing_b2:
                (base / "b2.env").write_text("B2_BUCKET_NAME=fixture-bucket\n")
            state = dict(snapshots=0, containers={
                "old-v2": dict(name="scoring-physiology-v2", running=previous_running, version="frwhoop-physiology-2", mode="[]"),
                "old-v1": dict(name="scoring-legacy", running=True, version="frwhoop-server-1", mode="[]"),
                "model": dict(name="scoring-model", running=True, version="frwhoop-physiology-2", mode='["--models-only"]'),
                "foreign": dict(name="foreign-worker", running=True, version="frwhoop-physiology-2", mode='[]'),
            })
            if scenario == 'foreign-fixed-name':
                state['containers']['old-v2']['name'] = 'prior-worker'
                state['containers']['foreign']['name'] = 'scoring-physiology-v2'
            (root / "docker-state.json").write_text(json.dumps(state))
            binary_dir = root / "bin"
            binary_dir.mkdir()
            for name, body in {
                "docker": DOCKER,
                "flock": "#!/bin/sh\nexit 0\n",
                "sleep": "#!/bin/sh\nexit 0\n",
                "timeout": '#!/bin/sh\nshift\nexec "$@"\n',
            }.items():
                path = binary_dir / name
                path.write_text(body)
                path.chmod(0o755)
            remote = SCRIPT.read_text().split("<<'REMOTE'\n", 1)[1].split("\nREMOTE\n", 1)[0]
            remote = remote.replace('BASE="/opt/frwhoop"', 'BASE="' + str(base) + '"')
            env = os.environ.copy()
            env.update(PATH=str(binary_dir) + os.pathsep + env["PATH"], FIXTURE_ROOT=str(root), SCENARIO=scenario)
            bash = "/opt/homebrew/bin/bash" if Path("/opt/homebrew/bin/bash").exists() else "bash"
            result = subprocess.run([bash, "-s", "--", SHA, str(build)], input=remote, text=True,
                                    capture_output=True, env=env, timeout=20)
            log = root / "docker.jsonl"
            commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return (result, commands, (base / "scoring.env").read_text(), compose.read_text(),
                    json.loads((root / "docker-state.json").read_text()),
                    [p.name for p in base.glob("scoring-rollback.*/candidate.env")])

    def assert_preserved(self, result, commands, config, compose, state, pending, running=True):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config, "existing-worker-config\n")
        self.assertEqual(compose, "previous-compose\n")
        self.assertEqual(state["containers"]["old-v2"]["name"], "scoring-physiology-v2")
        self.assertEqual(state["containers"]["old-v2"]["running"], running)
        self.assertTrue(state["containers"]["old-v1"]["running"])
        self.assertTrue(state["containers"]["model"]["running"])
        self.assertTrue(state["containers"]["foreign"]["running"])
        self.assertNotIn("new-v2", state["containers"])
        self.assertFalse(pending)
        for args in commands:
            if args[0] in ("stop", "start", "rename", "rm"):
                self.assertNotIn("old-v1", args)
                self.assertNotIn("model", args)
                self.assertNotIn("foreign", args)
        for secret in ("password", "hosted-key", "hosted-ingest", "private unparseable", "private-token", "different-project"):
            self.assertNotIn(secret, result.stdout + result.stderr)

    def test_preflight_failures_do_not_touch_workers_or_configuration(self):
        for kwargs in ({"scenario": "preflight"}, {"missing_hosted_key": True}, {"missing_database": True},
                       {"missing_b2": True}, {"scenario": "compose-config"}):
            with self.subTest(kwargs=kwargs):
                outcome = self.run_remote(**kwargs)
                self.assert_preserved(*outcome)
                self.assertFalse(any(c[0] in ("stop", "start", "rename", "rm") for c in outcome[1]))

    def test_success_requires_two_actual_polls_and_retains_prior_worker(self):
        for scenario in ("idle", "debt", "live-lease"):
            with self.subTest(scenario=scenario):
                result, commands, config, compose, state, pending = self.run_remote(scenario)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(state["snapshots"], 4 if scenario == "live-lease" else 3)
                self.assertFalse(state["containers"]["old-v2"]["running"])
                self.assertTrue(state["containers"]["old-v2"]["name"].startswith("scoring-rollback-"))
                self.assertTrue(state["containers"]["new-v2"]["running"])
                self.assertTrue(state["containers"]["old-v1"]["running"])
                self.assertTrue(state["containers"]["model"]["running"])
                self.assertFalse(any(c[0] == "rm" for c in commands))
                self.assertIn("SUPABASE_SERVICE_ROLE_KEY=hosted-key\n", config)
                self.assertNotIn("wrong-local", config)
                self.assertIn("scoring-physiology-v2:", compose)
                self.assertFalse(pending)
                kinds = [c[0] for c in commands]
                self.assertLess(kinds.index("run"), kinds.index("stop"))
                snapshot_index = next(i for i, args in enumerate(commands) if args[0] == 'run' and 'psql' in args)
                self.assertLess(kinds.index("stop"), snapshot_index)

    def test_foreign_fixed_name_is_rejected_without_touching_any_worker(self):
        result, commands, config, compose, state, pending = self.run_remote('foreign-fixed-name')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config, 'existing-worker-config\n')
        self.assertEqual(compose, 'previous-compose\n')
        self.assertFalse(pending)
        self.assertFalse(any(c[0] in ('stop','start','rename','rm') for c in commands))
        self.assertTrue(state['containers']['foreign']['running'])
        self.assertEqual(state['containers']['foreign']['name'], 'scoring-physiology-v2')

    def assert_foreign_cutover_preserved(self, scenario):
        result, commands, config, compose, state, pending = self.run_remote(scenario)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Rollback incomplete', result.stderr)
        self.assertEqual(config, 'existing-worker-config\n')
        self.assertEqual(compose, 'previous-compose\n')
        self.assertFalse(pending)
        self.assertTrue(state['containers']['racing-foreign']['running'])
        self.assertEqual(state['containers']['racing-foreign']['name'], 'scoring-physiology-v2')
        self.assertFalse(state['containers']['old-v2']['running'])
        self.assertTrue(state['containers']['old-v2']['name'].startswith('scoring-rollback-'))
        self.assertTrue(state['containers']['old-v1']['running'])
        self.assertTrue(state['containers']['model']['running'])
        self.assertFalse(any(command[0] == 'update' for command in commands))
        for command in commands:
            if command[0] in ('rm','stop','start','rename'):
                self.assertNotIn('racing-foreign', command)

    def test_foreign_container_created_during_failed_cutover_is_never_removed_or_stopped(self):
        self.assert_foreign_cutover_preserved('foreign-create-race')

    def test_foreign_container_after_successful_create_is_not_given_restart_policy(self):
        self.assert_foreign_cutover_preserved('foreign-create-success-race')

    def test_startup_and_progress_failures_restore_exact_prior_worker_and_config(self):
        for scenario in ("compose-start", "crash", "restarts", "ports", "wrong-image",
                         "stale-poll", "score-only", "no-publication", "late-debt",
                         "bad-snapshot", "database", "future-poll", "rename-failed", "stop-failed",
                         "rename-applied-then-failed", "restart-policy"):
            with self.subTest(scenario=scenario):
                self.assert_preserved(*self.run_remote(scenario))

    def test_other_destination_or_worker_cannot_supply_acceptance_evidence(self):
        for scenario in ("wrong-database", "wrong-rest", "wrong-worker", "wrong-source", "missing-worker",
                         "another-worker", "two-processes", "process-changed"):
            with self.subTest(scenario=scenario):
                self.assert_preserved(*self.run_remote(scenario))

    def test_rollback_does_not_start_a_previously_stopped_worker(self):
        self.assert_preserved(*self.run_remote("compose-start", previous_running=False), running=False)


if __name__ == "__main__":
    unittest.main()
