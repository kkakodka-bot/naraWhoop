"""Runtime acceptance behavior with fake Docker and real disposable PostgreSQL query checks."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/remote/verify-scoring-runtime.sh"
HELPER = SCRIPT.parent.parent / 'scoring-progress.sh'
SHA = "a" * 40
WORKER = '11111111-1111-4111-8111-111111111111'
PROCESS = '33333333-3333-4333-8333-333333333333'
POSTGRES_CLIENT_IMAGE = 'docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3'
POSTGRES_CLIENT_CONFIG = 'sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537'


def snapshot(poll="p0", score="s0", healthy="t", eligible=0, lease=0, exhausted=0, delayed=0, publication=10, projection_pending=0, projection_age=0):
    return "|".join(map(str, [1, PROCESS, int(poll[1:])*10, int(score[1:])*10, healthy,
                             eligible, lease, exhausted, delayed, publication, 1000, projection_pending, projection_age]))


class ScoringRuntimeTest(unittest.TestCase):
    def run_check(self, rows, query_fails=False, duplicate=False, other_project=False, database_url=None,
                  real_psql=None, expected_password="fixture-secret", query_seconds=0, expected_ssl=None, peer_url=None,
                  algorithm_version='frwhoop-physiology-2', client_identity=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "snapshots.json").write_text(json.dumps(rows))
            (root / "clock").write_text("0")
            docker = root / "docker"
            docker.write_text("""#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['DOCKER_CONFIG'])
settings = json.loads((root / 'mock-settings.json').read_text())
with (root / 'commands.jsonl').open('a') as log: log.write(json.dumps(args) + '\\n')
if args[0] == 'inspect':
    if 'org.opencontainers.image.revision' in args[2]: print('a' * 40)
    elif '.State.Running' in args[2]: print('true')
    elif '.RestartCount' in args[2]: print('0')
    elif '.Config.Cmd' in args[2]: print('["--history"]' if settings['MOCK_VERSION']=='frwhoop-server-2-history' else '[]')
    elif '.Id' in args[2]: print('current-id')
    elif '.Image' in args[2]: print('sha256:' + 'a'*64)
    elif '.Config.Env' in args[2]:
        print('SCORING_ALGORITHM_VERSION=' + settings['MOCK_VERSION'])
        print('DATABASE_URL=' + settings['MOCK_DATABASE_URL'])
        print('SCORING_WORKER_INSTANCE_ID=11111111-1111-4111-8111-111111111111')
        print('SCORING_WORKER_SOURCE_REVISION=' + 'a'*40)
        project = 'b' if args[-1] == 'second-id' and settings['OTHER_PROJECT'] == '1' else 'a'
        endpoint = settings.get('PEER_URL') if args[-1] == 'second-id' else None
        print('SUPABASE_URL=' + (endpoint or 'https://' + project * 20 + '.supabase.co/rest/v1'))
elif args[0] == 'ps': print('current-id' + ('\\nsecond-id' if settings['DUPLICATE'] == '1' else ''))
elif args[0] == 'port': pass
elif args[0] == 'run':
    assert settings['POSTGRES_CLIENT_IMAGE'] in args and 'psql' in args
    assert settings['POSTGRES_CLIENT_IMAGE'].startswith('docker.io/library/postgres@sha256:')
    assert 'PGDATABASE' in args and 'default_transaction_read_only=on' in os.environ['PGOPTIONS']
    assert not any('fixture-secret' in arg for arg in args)
    assert os.environ['PGDATABASE'] == 'postgres'
    assert os.environ['PGPASSWORD'] == settings['EXPECTED_PASSWORD']
    if settings.get('EXPECTED_SSL'): assert os.environ['PGSSLMODE'] == settings['EXPECTED_SSL']
    (root / 'clock').write_text(str(int((root / 'clock').read_text()) + int(settings['QUERY_SECONDS'])))
    query = sys.stdin.read()
    assert ('scoring_snapshots_v2' if settings['MOCK_VERSION']=='frwhoop-server-2-history' else 'physiology_archive_outbox') in query
    if settings.get('REAL_PSQL'):
        local_env = os.environ.copy()
        local_env.pop('PGSSLMODE', None); local_env.pop('PGSSLROOTCERT', None)
        result = subprocess.run([settings['REAL_PSQL']] + args[args.index('psql') + 1:],
                                input=query, text=True, capture_output=True, env=local_env)
        (root / 'local-psql-error').write_text(result.stderr)
        print(result.stdout, end='')
        sys.exit(result.returncode)
    if settings['QUERY_FAILS'] == '1':
        print(os.environ['PGPASSWORD'], file=sys.stderr)
        sys.exit(1)
    count = int((root / 'count').read_text()) if (root / 'count').exists() else 0
    rows = json.loads((root / 'snapshots.json').read_text())
    print(rows[min(count, len(rows) - 1)])
    (root / 'count').write_text(str(count + 1))
else: raise AssertionError(args)
""")
            docker.chmod(0o755)
            (root / "sleep").write_text("#!" + sys.executable + "\nimport os,pathlib,sys\np=pathlib.Path(os.environ['MOCK_ROOT'])/'clock'\np.write_text(str(int(p.read_text())+int(sys.argv[1])))\n")
            (root / "sleep").chmod(0o755)
            (root / "python3").write_text("#!" + sys.executable + "\nimport os,pathlib,sys\nif sys.argv[1:]==['-c','import time; print(int(time.monotonic()))']:\n print((pathlib.Path(os.environ['MOCK_ROOT'])/'clock').read_text())\nelse:\n os.execv(sys.executable,[sys.executable]+sys.argv[1:])\n")
            (root / "python3").chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], MOCK_ROOT=str(root),
                       QUERY_FAILS=str(int(query_fails)), DUPLICATE=str(int(duplicate)),
                       OTHER_PROJECT=str(int(other_project)), SCORING_VERIFY_TIMEOUT_SECONDS="15",
                       EXPECTED_PASSWORD=expected_password, QUERY_SECONDS=str(query_seconds), EXPECTED_SSL=expected_ssl or "",
                       PEER_URL=peer_url or "",
                       MOCK_VERSION=algorithm_version,
                       MOCK_DATABASE_URL=database_url or 'postgresql://postgres:fixture-secret@db.example/postgres?sslmode=verify-full&sslrootcert=system')
            if real_psql:
                env['REAL_PSQL'] = real_psql
            env['DOCKER_CONFIG'] = str(root)
            client = {
                'SCORING_POSTGRES_CLIENT_IMAGE': POSTGRES_CLIENT_IMAGE,
                'SCORING_POSTGRES_CLIENT_CONFIG_DIGEST': POSTGRES_CLIENT_CONFIG,
                'SCORING_POSTGRES_CLIENT_PLATFORM': 'linux/amd64',
                'SCORING_POSTGRES_CLIENT_VERSION': '17.11-alpine3.24',
            }
            if client_identity:
                client.update(client_identity)
            (root / 'mock-settings.json').write_text(json.dumps({
                'QUERY_FAILS': env['QUERY_FAILS'], 'DUPLICATE': env['DUPLICATE'],
                'OTHER_PROJECT': env['OTHER_PROJECT'], 'EXPECTED_PASSWORD': env['EXPECTED_PASSWORD'],
                'QUERY_SECONDS': env['QUERY_SECONDS'], 'EXPECTED_SSL': env['EXPECTED_SSL'],
                'PEER_URL': env['PEER_URL'], 'MOCK_VERSION': env['MOCK_VERSION'],
                'MOCK_DATABASE_URL': env['MOCK_DATABASE_URL'],
                'POSTGRES_CLIENT_IMAGE': client['SCORING_POSTGRES_CLIENT_IMAGE'],
                'REAL_PSQL': env.get('REAL_PSQL', ''),
            }))
            shutil.copy(HELPER, root / 'scoring-progress.sh')
            secrets = root / 'secrets.env'
            secrets.write_text("SCORING_DATABASE_URL='" + env['MOCK_DATABASE_URL'] + "'\n"
                               "SCORING_SUPABASE_URL='https://" + 'a'*20 + ".supabase.co/rest/v1'\n")
            client_env = root / 'scoring-client.env'
            client_env.write_text(''.join(name + '=' + value + '\n' for name, value in client.items()))
            wrapper = root / 'verify.sh'
            wrapper.write_text(SCRIPT.read_text()
                               .replace('source /opt/frwhoop/secrets.env', 'source "' + str(secrets) + '"')
                               .replace('source /opt/frwhoop/scoring-client.env', 'source "' + str(client_env) + '"'))
            result = subprocess.run(["bash", str(wrapper), SHA, 'sha256:' + 'a'*64, algorithm_version], text=True, capture_output=True, env=env, timeout=20)
            command_log = root / 'commands.jsonl'
            commands = [json.loads(line) for line in command_log.read_text().splitlines()] if command_log.exists() else []
            result.local_psql_error = (root / "local-psql-error").read_text() if (root / "local-psql-error").exists() else "client was not reached"
            result.mock_commands = commands
            result.elapsed_mock_seconds = int((root / "clock").read_text())
            self.assertNotIn("fixture-secret", result.stdout + result.stderr)
            self.assertFalse(any(args[0] == "exec" for args in commands), "Must not rely on a local Supabase container")
            return result

    def test_empty_queue_requires_advancing_poll_and_reports_publication_not_exercised(self):
        result = self.run_check([snapshot(), snapshot(poll="p1"), snapshot(poll="p2")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Publication was not exercised", result.stdout)

    def test_installed_verifier_sources_plan_bound_client_without_inherited_client_variables(self):
        result = self.run_check([snapshot(), snapshot(poll="p1"), snapshot(poll="p2")])
        self.assertEqual(result.returncode, 0, result.stderr)
        runs = [command for command in result.mock_commands if command[0] == 'run']
        self.assertTrue(runs)
        self.assertTrue(all(POSTGRES_CLIENT_IMAGE in command for command in runs))

    def test_stalled_poll_fails_even_when_queue_is_empty(self):
        result = self.run_check([snapshot()])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no healthy advancing physiology poll", result.stderr.lower())

    def test_eligible_work_requires_a_new_score_and_immutable_publication(self):
        result = self.run_check([snapshot(eligible=2), snapshot(poll="p1", score="s1", eligible=1, publication=11),
                                 snapshot(poll="p2", score="s1", publication=11)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("new immutable physiology publication", result.stdout)

    def test_advancing_polls_and_score_heartbeat_do_not_replace_publication_evidence(self):
        result = self.run_check([snapshot(eligible=1), snapshot(poll="p1", score="s1", eligible=1),
                                 snapshot(poll="p2", score="s1", eligible=1)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no healthy immutable publication", result.stderr.lower())

    def test_new_publication_without_worker_completion_does_not_pass(self):
        result = self.run_check([snapshot(eligible=1), snapshot(poll="p1", publication=11),
                                 snapshot(poll="p2", publication=12)])
        self.assertNotEqual(result.returncode, 0)

    def test_retry_exhaustion_fails_even_with_healthy_polls(self):
        result = self.run_check([snapshot(exhausted=1), snapshot(poll="p1", exhausted=1)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("retry-exhausted scoring debt", result.stderr.lower())

    def test_future_retry_debt_is_reported_and_cannot_pass_as_empty(self):
        result = self.run_check([snapshot(delayed=2), snapshot(poll="p1", delayed=2), snapshot(poll="p2", delayed=2)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("delayed=2", result.stdout)
        self.assertIn("delayed scoring debt remains", result.stderr.lower())

    def test_delayed_work_can_become_due_and_publish_during_observation(self):
        result = self.run_check([snapshot(delayed=1), snapshot(poll="p1", eligible=1),
                                 snapshot(poll="p2", score="s1", publication=11)])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_new_work_arriving_after_initial_empty_snapshot_requires_publication(self):
        result = self.run_check([snapshot(), snapshot(poll="p1", eligible=1), snapshot(poll="p2", eligible=1)])
        self.assertNotEqual(result.returncode, 0)

    def test_worker_error_prevents_acceptance_even_if_publication_advances(self):
        result = self.run_check([snapshot(eligible=1), snapshot(poll="p1", score="s1", healthy="f", publication=11),
                                 snapshot(poll="p2", score="s2", healthy="f", publication=12)])
        self.assertNotEqual(result.returncode, 0)

    def test_healthy_polls_cannot_hide_projection_stall(self):
        result = self.run_check([snapshot(projection_pending=1, projection_age=300)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Projection stalled', result.stderr)

    def test_baseline_and_history_have_separate_version_bound_progress(self):
        for version in ('frwhoop-server-1','frwhoop-server-2-history'):
            result = self.run_check([snapshot(eligible=1),snapshot(poll='p1',eligible=1),
                                     snapshot(poll='p2',score='s1',publication=11)], algorithm_version=version)
            self.assertEqual(result.returncode, 0, result.stderr)
            queries = [command for command in result.mock_commands if command[0]=='run']
            self.assertTrue(all('algorithm_version=' + version in command for command in queries))

    def test_query_failure_does_not_leak_uri_or_pass(self):
        result = self.run_check([snapshot()], query_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hosted runtime query failed", result.stderr.lower())

    def test_multiple_running_v2_workers_fail(self):
        result = self.run_check([snapshot()], duplicate=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("same-project worker isolation", result.stderr)

    def test_same_version_worker_for_another_project_is_ignored(self):
        result = self.run_check([snapshot(), snapshot(poll="p1"), snapshot(poll="p2")], duplicate=True, other_project=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Accepted: exact process", result.stdout)

    def test_same_project_with_uppercase_host_and_explicit_https_port_is_not_ignored(self):
        result = self.run_check([snapshot()], duplicate=True,
                               peer_url='https://' + 'A' * 20 + '.SUPABASE.CO:443/rest/v1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("same-project worker isolation", result.stderr)

    def test_query_time_counts_toward_the_absolute_runtime_deadline(self):
        result = self.run_check([snapshot(eligible=1)], query_seconds=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertLessEqual(result.elapsed_mock_seconds, 15)
        self.assertEqual(sum(command[0] == 'run' for command in result.mock_commands), 2)

    def test_encoded_credentials_decode_once_and_keep_literal_plus(self):
        result = self.run_check([snapshot(), snapshot(poll="p1"), snapshot(poll="p2")],
            database_url='postgresql://postgres:fixture-secret+%2B%40%252F@db.example/postgres?sslmode=verify-full&sslrootcert=system',
            expected_password='fixture-secret++@%2F')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_jdbc_options_with_verified_tls_are_supported(self):
        result = self.run_check([snapshot(), snapshot(poll="p1"), snapshot(poll="p2")], expected_ssl='verify-full',
            database_url='postgresql://postgres:fixture-secret@db.example/postgres?sslmode=verify-full&sslrootcert=system&connectTimeout=10&socketTimeout=20&prepareThreshold=0&ApplicationName=test%2Bname&channelBinding=prefer&targetServerType=primary')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_duplicate_sslmode_is_rejected(self):
        result = self.run_check([snapshot(), snapshot(poll="p1"), snapshot(poll="p2")], expected_ssl='verify-full',
            database_url='postgresql://postgres:fixture-secret@db.example/postgres?sslmode=require&sslmode=verify-full&sslrootcert=system')
        self.assertNotEqual(result.returncode, 0)

    def test_bare_jdbc_ssl_flag_is_rejected(self):
        result = self.run_check([snapshot(), snapshot(poll="p1"), snapshot(poll="p2")], expected_ssl='verify-full',
            database_url='postgresql://postgres:fixture-secret@db.example/postgres?ssl&')
        self.assertNotEqual(result.returncode, 0)

    def test_wrong_postgres_client_reference_fails_before_secret_bearing_docker_run(self):
        result = self.run_check([snapshot()], client_identity={
            'SCORING_POSTGRES_CLIENT_IMAGE': 'docker.io/library/postgres:17-alpine',
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command[0] == 'run' for command in result.mock_commands))


@unittest.skipUnless(shutil.which("initdb") and shutil.which("pg_ctl") and shutil.which("psql"),
                     "disposable PostgreSQL server tools unavailable")
class RuntimeQueryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="scoring-runtime-")
        cls.root = Path(cls.temporary.name)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            cls.port = listener.getsockname()[1]
        subprocess.run(["initdb", "-D", str(cls.root / "data"), "-A", "trust", "-U", "postgres", "--no-locale"],
                       check=True, capture_output=True)
        subprocess.run(["pg_ctl", "-D", str(cls.root / "data"), "-l", str(cls.root / "server.log"),
                        "-o", f"-h 127.0.0.1 -p {cls.port} -k /tmp", "-w", "start"], check=True, capture_output=True)
        cls.addClassCleanup(cls.cleanup_database)
        cls.query = HELPER.read_text().split("<<'SQL'\n", 1)[1].split("\nSQL\n", 1)[0]
        cls.query = cls.query.replace(":'worker_instance_id'", "'" + WORKER + "'").replace(":'source_revision'", "'" + SHA + "'").replace(":'algorithm_version'", "'frwhoop-physiology-2'")
        cls.sql("""create table physiology_service_heartbeats(id integer,version text,last_poll_at timestamptz,
          last_score_at timestamptz,last_error text);
          insert into physiology_service_heartbeats values(1,'frwhoop-physiology-2',now(),null,null);
          create table physiology_work_items(status text,done_at timestamptz,failure_revision bigint,
            input_revision bigint,consecutive_failures integer,lease_expires_at timestamptz,next_attempt_at timestamptz);
          create table physiology_archive_outbox(id bigint,algorithm_version text);
          create table noop_projection_debt(state text,created_at timestamptz);
          create table scoring_work_items(like physiology_work_items);
          create table scoring_jobs_v2(algorithm_version text,dead_letter boolean,lease_until timestamptz,
            input_revision bigint,completed_revision bigint,consecutive_failures integer,not_before timestamptz);
          create table scoring_snapshots_v2(result_revision bigint,algorithm_version text);
          create table physiology_worker_heartbeats(worker_instance_id uuid,process_instance_id uuid,
            source_revision text,algorithm_version text,last_poll_at timestamptz,last_score_at timestamptz,last_error text);""")
        cls.sql(f"insert into physiology_worker_heartbeats values('{WORKER}','{PROCESS}','{SHA}','frwhoop-physiology-2',now(),null,null);")

    @classmethod
    def cleanup_database(cls):
        subprocess.run(["pg_ctl", "-D", str(cls.root / "data"), "-m", "fast", "-w", "stop"], capture_output=True)
        cls.temporary.cleanup()

    @classmethod
    def sql(cls, text, readonly=False):
        env = dict(os.environ, PGHOST="127.0.0.1", PGPORT=str(cls.port), PGUSER="postgres", PGDATABASE="postgres")
        env.pop("PGOPTIONS", None)
        if readonly:
            env["PGOPTIONS"] = "-c default_transaction_read_only=on -c statement_timeout=10000"
        result = subprocess.run(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t", "-F", "|", "-f", "-"],
                                input=text, text=True, capture_output=True, env=env, check=True)
        return result.stdout.strip()

    def test_real_postgres_query_distinguishes_due_running_delayed_exhausted_and_old_revision_failure(self):
        self.sql("""insert into physiology_work_items values
          ('pending',null,1,1,0,null,now()-interval '1 second'),
          ('running',null,1,1,0,now()+interval '30 seconds',now()+interval '1 hour'),
          ('retry',null,1,1,2,null,now()+interval '1 hour'),
          ('running',null,1,1,0,null,now()+interval '1 hour'),
          ('exhausted',null,1,1,8,null,now()-interval '1 second'),
          ('pending',null,1,2,8,null,now()-interval '1 second'),
          ('waiting',null,1,1,0,null,now()-interval '1 second'),
          ('done',now(),1,1,0,null,now());
          insert into physiology_archive_outbox values(10,'frwhoop-physiology-2'),(20,'frwhoop-server-1');""")
        values = self.sql(self.query, readonly=True).split("|")
        self.assertEqual(values[5:10], ["3", "0", "1", "2", "10"])
        result = ScoringRuntimeTest().run_check([], database_url=f"postgresql://postgres:fixture-secret@127.0.0.1:{self.port}/postgres?sslmode=verify-full&sslrootcert=system",
                                               real_psql=shutil.which("psql"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("retry-exhausted scoring debt remains (1 items)", result.stderr.lower(),
                      result.local_psql_error + repr(result.mock_commands))

    def test_real_postgres_baseline_and_history_queries_read_their_own_debt(self):
        self.sql("""insert into scoring_work_items values
          ('exhausted',null,1,1,8,null,now()-interval '1 second');
          insert into scoring_jobs_v2 values('frwhoop-server-2-history',true,null,1,0,8,now());""")
        for version in ('frwhoop-server-1','frwhoop-server-2-history'):
            self.sql(f"insert into physiology_worker_heartbeats values('{WORKER}','{PROCESS}','{SHA}','{version}',now(),null,null);")
            result = ScoringRuntimeTest().run_check([], database_url=f"postgresql://postgres:fixture-secret@127.0.0.1:{self.port}/postgres?sslmode=verify-full&sslrootcert=system",
                                                   real_psql=shutil.which('psql'),algorithm_version=version)
            self.assertIn('retry-exhausted scoring debt remains (1 items)', result.stderr.lower(),result.local_psql_error)


if __name__ == "__main__":
    unittest.main()
