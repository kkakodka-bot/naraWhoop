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


def snapshot(poll="p0", score="s0", healthy="t", eligible=0, lease=0, exhausted=0, delayed=0, publication=10):
    return "|".join(map(str, [1, PROCESS, int(poll[1:])*10, int(score[1:])*10, healthy,
                             eligible, lease, exhausted, delayed, publication, 1000]))


class ScoringRuntimeTest(unittest.TestCase):
    def run_check(self, rows, query_fails=False, duplicate=False, other_project=False, database_url=None,
                  real_psql=None, expected_password="fixture-secret", query_seconds=0, expected_ssl=None, peer_url=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "snapshots.json").write_text(json.dumps(rows))
            (root / "clock").write_text("0")
            docker = root / "docker"
            docker.write_text("""#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['MOCK_ROOT'])
with (root / 'commands.jsonl').open('a') as log: log.write(json.dumps(args) + '\\n')
if args[0] == 'inspect':
    if 'org.opencontainers.image.revision' in args[2]: print('a' * 40)
    elif '.State.Running' in args[2]: print('true')
    elif '.RestartCount' in args[2]: print('0')
    elif '.Config.Cmd' in args[2]: print('[]')
    elif '.Id' in args[2]: print('current-id')
    elif '.Config.Env' in args[2]:
        print('SCORING_ALGORITHM_VERSION=frwhoop-physiology-2')
        print('DATABASE_URL=' + os.environ['MOCK_DATABASE_URL'])
        print('SCORING_WORKER_INSTANCE_ID=11111111-1111-4111-8111-111111111111')
        print('SCORING_WORKER_SOURCE_REVISION=' + 'a'*40)
        project = 'b' if args[-1] == 'second-id' and os.environ['OTHER_PROJECT'] == '1' else 'a'
        endpoint = os.environ.get('PEER_URL') if args[-1] == 'second-id' else None
        print('SUPABASE_URL=' + (endpoint or 'https://' + project * 20 + '.supabase.co/rest/v1'))
elif args[0] == 'ps': print('current-id' + ('\\nsecond-id' if os.environ['DUPLICATE'] == '1' else ''))
elif args[0] == 'port': pass
elif args[0] == 'run':
    assert 'postgres:17-alpine' in args and 'psql' in args
    assert 'PGDATABASE' in args and 'default_transaction_read_only=on' in os.environ['PGOPTIONS']
    assert not any('fixture-secret' in arg for arg in args)
    assert os.environ['PGDATABASE'] == 'postgres'
    assert os.environ['PGPASSWORD'] == os.environ['EXPECTED_PASSWORD']
    if os.environ.get('EXPECTED_SSL'): assert os.environ['PGSSLMODE'] == os.environ['EXPECTED_SSL']
    (root / 'clock').write_text(str(int((root / 'clock').read_text()) + int(os.environ['QUERY_SECONDS'])))
    query = sys.stdin.read()
    assert 'physiology_archive_outbox' in query
    if os.environ.get('REAL_PSQL'):
        result = subprocess.run([os.environ['REAL_PSQL']] + args[args.index('psql') + 1:],
                                input=query, text=True, capture_output=True)
        (root / 'local-psql-error').write_text(result.stderr)
        print(result.stdout, end='')
        sys.exit(result.returncode)
    if os.environ['QUERY_FAILS'] == '1':
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
                       MOCK_DATABASE_URL=database_url or 'postgresql://postgres:fixture-secret@db.example/postgres?sslmode=require')
            if real_psql:
                env['REAL_PSQL'] = real_psql
            shutil.copy(HELPER, root / 'scoring-progress.sh')
            secrets = root / 'secrets.env'
            secrets.write_text("SCORING_DATABASE_URL='" + env['MOCK_DATABASE_URL'] + "'\n"
                               "SCORING_SUPABASE_URL='https://" + 'a'*20 + ".supabase.co/rest/v1'\n")
            wrapper = root / 'verify.sh'
            wrapper.write_text(SCRIPT.read_text().replace('source /opt/frwhoop/secrets.env', 'source "' + str(secrets) + '"'))
            result = subprocess.run(["bash", str(wrapper), SHA], text=True, capture_output=True, env=env, timeout=20)
            commands = [json.loads(line) for line in (root / "commands.jsonl").read_text().splitlines()]
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
            database_url='postgresql://postgres:fixture-secret+%2B%40%252F@db.example/postgres',
            expected_password='fixture-secret++@%2F')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_jdbc_options_and_explicit_sslmode_precedence_are_supported(self):
        result = self.run_check([snapshot(), snapshot(poll="p1"), snapshot(poll="p2")], expected_ssl='require',
            database_url='postgresql://postgres:fixture-secret@db.example/postgres?ssl=true&sslmode=require&connectTimeout=10&socketTimeout=20&prepareThreshold=0&ApplicationName=test%2Bname&channelBinding=prefer&targetServerType=primary')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_duplicate_sslmode_uses_last_value_like_the_worker(self):
        result = self.run_check([snapshot(), snapshot(poll="p1"), snapshot(poll="p2")], expected_ssl='verify-full',
            database_url='postgresql://postgres:fixture-secret@db.example/postgres?sslmode=require&sslmode=verify-full')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bare_jdbc_ssl_flag_preserves_full_certificate_verification(self):
        result = self.run_check([snapshot(), snapshot(poll="p1"), snapshot(poll="p2")], expected_ssl='verify-full',
            database_url='postgresql://postgres:fixture-secret@db.example/postgres?ssl&')
        self.assertEqual(result.returncode, 0, result.stderr)


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
        cls.query = cls.query.replace(":'worker_instance_id'", "'" + WORKER + "'").replace(":'source_revision'", "'" + SHA + "'")
        cls.sql("""create table physiology_service_heartbeats(id integer,version text,last_poll_at timestamptz,
          last_score_at timestamptz,last_error text);
          insert into physiology_service_heartbeats values(1,'frwhoop-physiology-2',now(),null,null);
          create table physiology_work_items(status text,done_at timestamptz,failure_revision bigint,
            input_revision bigint,consecutive_failures integer,lease_expires_at timestamptz,next_attempt_at timestamptz);
          create table physiology_archive_outbox(id bigint,algorithm_version text);
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
        result = ScoringRuntimeTest().run_check([], database_url=f"postgresql://postgres:fixture-secret@127.0.0.1:{self.port}/postgres",
                                               real_psql=shutil.which("psql"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("retry-exhausted scoring debt remains (1 items)", result.stderr.lower(),
                      result.local_psql_error + repr(result.mock_commands))


if __name__ == "__main__":
    unittest.main()
