"""Run the remote deployment payload against stateful disposable Docker/DB doubles."""
import json
import hashlib
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

VPS = Path(__file__).resolve().parents[1]
SCRIPT = VPS / "scripts/deploy-scoring-service.sh"
SHA = "a" * 40
V1_IMAGE = "fixture.invalid/reviewed-v1@sha256:" + "1" * 64
V2_IMAGE = "fixture.invalid/reviewed-v2@sha256:" + "2" * 64
V1_CONFIG = "sha256:" + "3" * 64
V2_CONFIG = "sha256:" + "a" * 64
POSTGRES_IMAGE = "docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3"
POSTGRES_CONFIG = "sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537"
POSTGRES_PLATFORM = "linux/amd64"
POSTGRES_VERSION = "17.11-alpine3.24"

CANARY_ADMISSION = {'mode':'canary','ownerId':'11111111-1111-4111-8111-111111111112',
                    'deviceId':'11111111-1111-4111-8111-111111111113'}
def admission_fixture(build, scope='full-fleet'):
    value = CANARY_ADMISSION if scope == 'initial-selected-v1' else {'mode':'all-eligible'}
    encoded = json.dumps(value,sort_keys=True,separators=(',',':'))
    (build/'infra/vps/scripts').mkdir(parents=True,exist_ok=True)
    shutil.copy(VPS/'scripts/scoring-admission.py',build/'infra/vps/scripts')
    (build/'worker-admission.json').write_text(encoded)
    (build/'worker-admission.json').chmod(0o600)
    return hashlib.sha256(encoded.encode()).hexdigest()

# Transaction tests stub this boundary; test_worker_image hashes real archive bytes.
WORKER_VERIFIER = '''import os, sys, json, pathlib
args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
assert args['--source-revision'] == 'a'*40
assert args['--output'] == 'image-id'
role = args['--role']
assert role in ('baseline', 'physiology')
expected = 'sha256:' + ('3'*64 if role == 'baseline' else 'a'*64)
assert args['--config-digest'] == expected
assert args['--reference'] == 'fixture.invalid/reviewed-' + ('v1@sha256:'+'1'*64 if role == 'baseline' else 'v2@sha256:'+'2'*64)
if os.environ.get('FIXTURE_ROOT'):
 with (pathlib.Path(os.environ['FIXTURE_ROOT'])/'docker.jsonl').open('a') as output:
  output.write(json.dumps(['worker-image-archive-verifier', args['--reference'], expected]) + '\\n')
if os.environ.get('SCENARIO') in ('wrong-config', 'wrong-repo-digest', 'wrong-image'): sys.exit(3)
print('sha256:'+'2'*64 if os.environ.get('SCENARIO') == 'containerd-id' and role == 'physiology' else expected)
'''

DOCKER = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
base = pathlib.Path('__FIXTURE_ROOT__')
state_file = base / 'docker-state.json'
state = json.loads(state_file.read_text())
scenario = '__SCENARIO__'
v1_image = '__V1_IMAGE__'
v2_image = '__V2_IMAGE__'
postgres_image = '__POSTGRES_IMAGE__'
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
    if field.startswith('{"containerId":'):
        assert '.Config.Env' not in field
        if scenario == 'forensic-failure': sys.exit(1)
        print(json.dumps({'containerId': key, 'imageId': 'sha256:'+'a'*64,
            'state': {'status': 'running' if row['running'] else 'exited', 'running': row['running'],
                      'exitCode': 0, 'oomKilled': False}, 'restartCount': 0, 'sourceRevision': 'a'*40}))
    elif field == '{{json .Config.Env}}':
        print(json.dumps([key+'='+value for key,value in state['candidate_env'].items()]))
    elif '.Config.Env' in field:
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
    elif '.Image' in field: print('sha256:' + ('2'*64 if scenario == 'containerd-id' else 'a'*64))
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
    if 'release_role_violations' in body:
        assert "algorithm_version <> 'frwhoop-server-1'" in body
        assert "physiology_feature_is_canonical('frwhoop-physiology-2',feature)" in body
        assert "physiology_feature_is_canonical('frwhoop-server-2-history',feature)" in body
        state['role_checks'] += 1; save()
        print(1 if scenario == 'bad-release-roles' else 0)
        sys.exit(0)
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
    if scenario in ('idle', 'restart-policy', 'containerd-id') and n > 2: score = 10
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
elif args[0] == 'pull': pass
elif args[0] == 'image' and args[1] == 'inspect':
    field = args[args.index('-f')+1]
    image = args[-1]
    if field == '{{.Id}}':
        expected = 'sha256:' + ('3'*64 if image == v1_image else 'a'*64)
        print('sha256:' + 'b'*64 if scenario == 'wrong-config' and image == v2_image else expected)
    elif '.RepoDigests' in field:
        if not (scenario == 'wrong-repo-digest' and image == os.environ['V2_IMAGE']): print(image)
    elif 'org.opencontainers.image.revision' in field: print('b'*40 if scenario == 'wrong-image' else 'a'*40)
    elif 'io.frwhoop.heartbeat.contract' in field: print('physiology_worker_heartbeats-v1')
    elif 'io.frwhoop.image.platform' in field: print('linux/amd64')
    elif '.Os' in field and '.Architecture' in field: print('linux/amd64')
    elif 'io.frwhoop.algorithm.roles' in field: print('frwhoop-physiology-2,frwhoop-server-2-history')
    else: raise AssertionError(field)
elif args[0] == 'image' and args[1] == 'save':
    assert args[2] == '-o' and args[-1] == postgres_image
    pathlib.Path(args[3]).write_bytes(b'reviewed-postgres-client-fixture')
elif args[0] == 'update':
    key,row = lookup(args[-1]); assert key == 'new-v2' and args[-1] == key
    if scenario == 'restart-policy': sys.exit(1)
elif args[0] != 'build': raise AssertionError(args)
'''


class ScoringDeployTest(unittest.TestCase):
    def test_reviewed_scope_executes_only_its_selected_scoring_services(self):
        body = SCRIPT.read_text().split('scoring_lanes=(scoring-baseline-v1)', 1)[1].split('\ndone\n', 1)[0] + '\ndone\n'
        body = 'scoring_lanes=(scoring-baseline-v1)' + body
        for scope, expected in (
            ('initial-selected-v1', ['scoring-baseline-v1']),
            ('full-fleet', ['scoring-baseline-v1', 'scoring-physiology-v2', 'scoring-history']),
        ):
            with self.subTest(scope=scope):
                result = subprocess.run(['bash', '-c', 'deploy_lane() { echo "$1"; };\n' + body],
                    env=dict(os.environ, DEPLOYMENT_SCOPE=scope), text=True, capture_output=True, check=True)
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_initial_scope_final_check_does_not_require_unlaunched_shadow_workers(self):
        result = self.run_final_verifier(scope='initial-selected-v1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

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
            shutil.copy(VPS / "scripts/scoring-tls.py", build / "infra/vps/scripts")
            (build / 'Tools/release/certificates').mkdir(parents=True)
            shutil.copy(VPS.parents[1] / 'Tools/release/certificates/supabase-prod-ca-2021.crt',
                        build / 'Tools/release/certificates')
            shutil.copy(VPS / "scripts/remote/verify-scoring-runtime.sh", build / "infra/vps/scripts/remote")
            shutil.copy(VPS / "scripts/scoring-hosted-query.py", build / "infra/vps/scripts")
            shutil.copy(VPS / "scripts/remote/read-scoring-query.sh", build / "infra/vps/scripts/remote")
            shutil.copy(VPS / "templates/docker-compose.scoring-override.yml", build / "infra/vps/templates")
            verifier = build / "infra/vps/scripts/verify-pinned-postgres-client.py"
            verifier.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
assert pathlib.Path(args['--archive']).read_bytes() == b'reviewed-postgres-client-fixture'
assert args['--reference'] == os.environ['POSTGRES_IMAGE']
assert args['--config-digest'] == os.environ['POSTGRES_CONFIG']
assert args['--platform'] == os.environ['POSTGRES_PLATFORM']
assert args['--version'] == os.environ['POSTGRES_VERSION']
""")
            verifier.chmod(0o755)
            (build / "infra/vps/scripts/verify-worker-image.py").write_text(WORKER_VERIFIER)
            compose = base / "scoring/docker-compose.yml"
            compose.parent.mkdir(parents=True)
            compose.write_text("previous-compose\n")
            secrets = (
                "SCORING_DATABASE_URL='postgresql://postgres.project:password@pooler.supabase.com/postgres?sslmode=verify-full&sslrootcert=system'\n"
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
            state = dict(snapshots=0, role_checks=0, containers={
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
                "docker": DOCKER.replace('__FIXTURE_ROOT__', str(root)).replace('__SCENARIO__', scenario)
                    .replace('__V1_IMAGE__', V1_IMAGE).replace('__V2_IMAGE__', V2_IMAGE)
                    .replace('__POSTGRES_IMAGE__', POSTGRES_IMAGE),
                "flock": "#!/bin/sh\nexit 0\n",
                "sleep": "#!/bin/sh\nexit 0\n",
                "timeout": '#!/bin/sh\nshift\nexec "$@"\n',
            }.items():
                path = binary_dir / name
                path.write_text(body)
                path.chmod(0o755)
            admission_sha = admission_fixture(build)
            remote = SCRIPT.read_text().split("<<'REMOTE'\n", 1)[1].split("\nREMOTE\n", 1)[0]
            remote = remote.replace('BASE="/opt/frwhoop"', 'BASE="' + str(base) + '"')
            env = os.environ.copy()
            env.update(PATH=str(binary_dir) + os.pathsep + env["PATH"], FIXTURE_ROOT=str(root), SCENARIO=scenario,
                       V1_IMAGE=V1_IMAGE, V2_IMAGE=V2_IMAGE, POSTGRES_IMAGE=POSTGRES_IMAGE,
                       POSTGRES_CONFIG=POSTGRES_CONFIG, POSTGRES_PLATFORM=POSTGRES_PLATFORM,
                       POSTGRES_VERSION=POSTGRES_VERSION)
            bash = "/opt/homebrew/bin/bash" if Path("/opt/homebrew/bin/bash").exists() else "bash"
            result = subprocess.run([bash, "-s", "--", SHA, str(build), "scoring-physiology-v2",
                                     V1_IMAGE, V2_IMAGE, V1_CONFIG, V2_CONFIG, POSTGRES_IMAGE,
                                     POSTGRES_CONFIG, POSTGRES_PLATFORM, POSTGRES_VERSION, 'full-fleet', admission_sha], input=remote, text=True,
                                    capture_output=True, env=env, timeout=20)
            log = root / "docker.jsonl"
            commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            result.forensic_receipts = [json.loads(p.read_text()) for p in base.glob('scoring-rollback.*/rejected-candidate.json')]
            result.forensic_modes = [p.stat().st_mode & 0o777 for p in base.glob('scoring-rollback.*/rejected-candidate.json')]
            return (result, commands, (base / "scoring.env").read_text(), compose.read_text(),
                    json.loads((root / "docker-state.json").read_text()),
                    [p.name for p in base.glob("scoring-rollback.*/candidate.env")])

    def run_final_verifier(self, *, defaults=None, source_selections=None,
                           v2_canonical=None, history_canonical=None, scope='full-fleet', observed_admission=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary_dir = root / "bin"
            binary_dir.mkdir()
            state = {
                "defaults": defaults or {"hrv": "frwhoop-server-1", "sleep": "frwhoop-server-1",
                                          "respiration": "frwhoop-server-1"},
                "sourceSelections": source_selections or [],
                "v2Canonical": v2_canonical or [],
                "historyCanonical": history_canonical or [],
            }
            state_file = root / "release-state.json"
            state_file.write_text(json.dumps(state))
            docker = binary_dir / "docker"
            docker.write_text(r'''#!/usr/bin/env python3
import os, sys, json
args=sys.argv[1:]
assert args[0]=='inspect' and '-f' in args
field=args[args.index('-f')+1]; name=args[-1]
if os.environ.get('TEST_SCOPE') == 'initial-selected-v1': assert name == 'scoring-baseline-v1'
lanes={
 'scoring-baseline-v1':('frwhoop-server-1','sha256:'+('3'*64),'11111111-1111-4111-8111-111111111111','null'),
 'scoring-physiology-v2':('frwhoop-physiology-2','sha256:'+('a'*64),'22222222-2222-4222-8222-222222222222','[]'),
 'scoring-history':('frwhoop-server-2-history','sha256:'+('a'*64),'33333333-3333-4333-8333-333333333333','["--history"]')}
algorithm,config,worker,command=lanes[name]
if field == '{{json .Config.Env}}':
 mode='canary' if os.environ.get('TEST_SCOPE')=='initial-selected-v1' else 'all-eligible'
 values=['SCORING_ADMISSION_MODE='+mode]
 if mode=='canary': values += ['SCORING_CANARY_OWNER_ID=11111111-1111-4111-8111-111111111112','SCORING_CANARY_DEVICE_ID=11111111-1111-4111-8111-111111111113']
 if os.environ.get('TEST_ADMISSION_OVERRIDE'): values=json.loads(os.environ['TEST_ADMISSION_OVERRIDE'])
 print(json.dumps(values))
elif '.Config.Env' in field:
 print('SCORING_ALGORITHM_VERSION='+algorithm)
 print('SCORING_WORKER_SOURCE_REVISION='+('a'*40))
 print('SCORING_WORKER_INSTANCE_ID='+worker)
elif '.Config.Cmd' in field: print(command)
elif '.State.Running' in field: print('true')
elif '.RestartCount' in field: print('0')
elif '.HostConfig.RestartPolicy.Name' in field: print('unless-stopped')
elif field=='{{.Image}}': print(config)
elif 'org.opencontainers.image.revision' in field: print('a'*40)
else: raise AssertionError(field)
''')
            docker.chmod(0o755)
            query = root / "read-scoring-query.sh"
            query.write_text(r'''#!/usr/bin/env python3
import json, os, sys
body=sys.stdin.read(); state=json.load(open(os.environ['RELEASE_STATE']))
if 'release_role_violations' in body:
 required={"hrv","sleep","respiration"}
 assert "algorithm_version <> 'frwhoop-server-1'" in body
 assert "physiology_feature_is_canonical('frwhoop-physiology-2',feature)" in body
 assert "physiology_feature_is_canonical('frwhoop-server-2-history',feature)" in body
 violations=(set(state['defaults'])!=required or any(v!='frwhoop-server-1' for v in state['defaults'].values())
   or any(v!='frwhoop-server-1' for v in state['sourceSelections'])
   or bool(state['v2Canonical']) or bool(state['historyCanonical']))
 print(1 if violations else 0)
elif 'with required(algorithm_version,worker_instance_id)' in body:
 if os.environ.get('TEST_SCOPE') == 'initial-selected-v1':
  assert 'frwhoop-physiology-2' not in body and 'frwhoop-server-2-history' not in body
 assert body.count('last_score_at') >= 2; print(0)
elif 'physiology_feature_defaults' in body and 'physiology_source_selection' in body:
 print(0)
else: raise AssertionError(body)
''')
            query.chmod(0o755)
            admission_sha = admission_fixture(root,scope)
            remote = SCRIPT.read_text().split("<<'VERIFY'\n", 1)[1].split("\nVERIFY\n", 1)[0]
            remote = remote.replace('/opt/frwhoop/scoring/read-scoring-query.sh', str(query))
            worker_verifier = root / 'verify-worker-image.py'
            worker_verifier.write_text(WORKER_VERIFIER)
            remote = remote.replace('/opt/frwhoop/scoring/verify-worker-image.py', str(worker_verifier))
            env = os.environ.copy()
            env.update(PATH=str(binary_dir) + os.pathsep + env["PATH"], RELEASE_STATE=str(state_file), TEST_SCOPE=scope)
            if observed_admission is not None: env['TEST_ADMISSION_OVERRIDE']=json.dumps(observed_admission)
            bash = "/opt/homebrew/bin/bash" if Path("/opt/homebrew/bin/bash").exists() else "bash"
            return subprocess.run([bash, "-s", "--", SHA, V1_CONFIG, V2_CONFIG, V1_IMAGE, V2_IMAGE, scope, str(root), admission_sha], input=remote,
                                  text=True, capture_output=True, env=env, timeout=10)

    def test_initial_scope_rejects_wrong_live_container_admission_without_private_output(self):
        valid = ['SCORING_ADMISSION_MODE=canary',
                 'SCORING_CANARY_OWNER_ID='+CANARY_ADMISSION['ownerId'],
                 'SCORING_CANARY_DEVICE_ID='+CANARY_ADMISSION['deviceId']]
        for values in ([], ['SCORING_ADMISSION_MODE=all-eligible'], valid+valid[:1],
                       [v.replace(CANARY_ADMISSION['deviceId'],CANARY_ADMISSION['ownerId']) for v in valid]):
            with self.subTest(values=values):
                result=self.run_final_verifier(scope='initial-selected-v1', observed_admission=values)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('private worker admission validation failed',result.stderr)
                self.assertNotIn(CANARY_ADMISSION['ownerId'],result.stdout+result.stderr)
                self.assertNotIn(CANARY_ADMISSION['deviceId'],result.stdout+result.stderr)

    def assert_preserved(self, result, commands, config, compose, state, pending, running=False,
                         rollback_blocked=True):
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
        self.assertEqual('ROLLBACK_BLOCKED:' in result.stderr, rollback_blocked)
        self.assertFalse(any(args[0] == "start" for args in commands))
        for args in commands:
            if args[0] in ("stop", "start", "rename", "rm"):
                self.assertNotIn("old-v1", args)
                self.assertNotIn("model", args)
                self.assertNotIn("foreign", args)
        for secret in ("password", "hosted-key", "hosted-ingest", "private unparseable", "private-token", "different-project"):
            self.assertNotIn(secret, result.stdout + result.stderr)

    def test_preflight_failures_do_not_touch_workers_or_configuration(self):
        for kwargs in ({"scenario": "preflight"}, {"missing_hosted_key": True}, {"missing_database": True},
                       {"missing_b2": True}, {"scenario": "compose-config"}, {"scenario": "wrong-image"},
                       {"scenario": "wrong-config"}, {"scenario": "wrong-repo-digest"},
                       {"scenario": "bad-release-roles"}):
            with self.subTest(kwargs=kwargs):
                outcome = self.run_remote(**kwargs)
                self.assert_preserved(*outcome, running=True, rollback_blocked=False)
                self.assertFalse(any(c[0] in ("stop", "start", "rename", "rm") for c in outcome[1]))

    def test_bad_hosted_role_state_is_checked_with_pinned_client_before_any_worker_mutation(self):
        result, commands, config, compose, state, pending = self.run_remote("bad-release-roles")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("release roles differ before cutover", result.stderr)
        self.assertEqual(state["role_checks"], 1)
        self.assertEqual(state["snapshots"], 0)
        self.assertEqual(config, "existing-worker-config\n")
        self.assertEqual(compose, "previous-compose\n")
        self.assertFalse(pending)
        self.assertTrue(state["containers"]["old-v2"]["running"])
        self.assertEqual(state["containers"]["old-v2"]["name"], "scoring-physiology-v2")
        self.assertFalse(any(command[0] in ("stop", "start", "rename", "rm", "update") for command in commands))

    def test_preflight_and_final_verifier_use_the_same_release_role_sql(self):
        queries = re.findall(r"select count\(\*\) from \(\n.*?\n\) release_role_violations;", SCRIPT.read_text(), re.S)
        self.assertEqual(len(queries), 2)
        self.assertEqual(queries[0], queries[1])

    def test_success_requires_two_actual_polls_and_a_publication_then_retains_prior_worker(self):
        for scenario in ("idle", "debt", "live-lease", "containerd-id"):
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
                self.assertFalse(any(c[0] == "build" for c in commands))
                self.assertEqual([c[-1] for c in commands if c[0] == "pull"],
                                 [POSTGRES_IMAGE, V1_IMAGE, V2_IMAGE])
                verified_images = [(c[1], c[2]) for c in commands if c[0] == 'worker-image-archive-verifier']
                inspected_refs = [c[-1] for c in commands if c[:4] == ['image', 'inspect', '-f',
                                  '{{range .RepoDigests}}{{println .}}{{end}}']]
                self.assertEqual(verified_images, [(V1_IMAGE, V1_CONFIG), (V2_IMAGE, V2_CONFIG)])
                self.assertEqual(inspected_refs, [POSTGRES_IMAGE])
                self.assertIn("SUPABASE_SERVICE_ROLE_KEY=hosted-key\n", config)
                self.assertNotIn("wrong-local", config)
                self.assertIn("scoring-physiology-v2:", compose)
                self.assertFalse(pending)
                self.assertEqual(state["role_checks"], 1)
                kinds = [c[0] for c in commands]
                self.assertLess(kinds.index("run"), kinds.index("stop"))
                snapshot_index = next(i for i, args in enumerate(commands)
                    if args[0] == 'run' and 'psql' in args and
                    any(value.startswith('worker_instance_id=') for value in args))
                self.assertLess(kinds.index("stop"), snapshot_index)
                update_index = next(i for i, args in enumerate(commands) if args[0] == 'update')
                last_snapshot = max(i for i, args in enumerate(commands)
                    if args[0] == 'run' and 'psql' in args and
                    any(value.startswith('worker_instance_id=') for value in args))
                self.assertLess(last_snapshot, update_index)

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
        self.assertIn('ROLLBACK_BLOCKED:', result.stderr)
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
        self.assertFalse(any(command[0] == 'start' for command in commands))
        for command in commands:
            if command[0] in ('rm','stop','start','rename'):
                self.assertNotIn('racing-foreign', command)

    def test_foreign_container_created_during_failed_cutover_is_never_removed_or_stopped(self):
        self.assert_foreign_cutover_preserved('foreign-create-race')

    def test_foreign_container_after_successful_create_is_not_given_restart_policy(self):
        self.assert_foreign_cutover_preserved('foreign-create-success-race')

    def test_startup_and_progress_failures_restore_config_but_leave_prior_worker_stopped(self):
        for scenario in ("compose-start", "crash", "restarts", "ports",
                         "stale-poll", "score-only", "no-publication", "late-debt",
                         "bad-snapshot", "database", "future-poll", "rename-failed", "stop-failed",
                         "rename-applied-then-failed", "restart-policy"):
            with self.subTest(scenario=scenario):
                self.assert_preserved(*self.run_remote(scenario))

    def test_rejected_candidate_has_allowlisted_private_forensic_receipt_before_removal(self):
        result, commands, *_ = self.run_remote('crash')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.forensic_modes, [0o600])
        self.assertEqual(len(result.forensic_receipts), 1)
        receipt = result.forensic_receipts[0]
        self.assertEqual(set(receipt), {'schemaVersion', 'containerId', 'imageId', 'state',
                                       'restartCount', 'sourceRevision'})
        self.assertEqual(receipt['containerId'], 'new-v2')
        self.assertEqual(receipt['sourceRevision'], SHA)
        self.assertEqual(set(receipt['state']), {'status', 'running', 'exitCode', 'oomKilled'})
        serialized = json.dumps(receipt)
        for forbidden in ('Config', 'Env', 'password', 'hosted-key', 'hosted-ingest', 'SUPABASE', 'DATABASE_URL'):
            self.assertNotIn(forbidden, serialized)
        capture = next(i for i, command in enumerate(commands) if command[0] == 'inspect' and
                       '-f' in command and command[command.index('-f')+1].startswith('{"containerId":'))
        removal = next(i for i, command in enumerate(commands) if command[0] == 'rm')
        self.assertLess(capture, removal)

    def test_failed_forensic_capture_retains_stopped_candidate(self):
        result, commands, _, _, state, _ = self.run_remote('forensic-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('retaining stopped candidate', result.stderr)
        self.assertEqual(result.forensic_receipts, [])
        self.assertIn('new-v2', state['containers'])
        self.assertFalse(state['containers']['new-v2']['running'])
        self.assertFalse(any(command[0] == 'rm' for command in commands))

    def test_other_destination_or_worker_cannot_supply_acceptance_evidence(self):
        for scenario in ("wrong-database", "wrong-rest", "wrong-worker", "wrong-source", "missing-worker",
                         "another-worker", "two-processes", "process-changed"):
            with self.subTest(scenario=scenario):
                self.assert_preserved(*self.run_remote(scenario))

    def test_rollback_does_not_start_a_previously_stopped_worker(self):
        self.assert_preserved(*self.run_remote("compose-start", previous_running=False), running=False,
                              rollback_blocked=True)

    def test_final_verifier_enforces_selected_v1_and_shadow_v2_history_roles(self):
        accepted = self.run_final_verifier()
        self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
        rejected_states = [
            {"defaults": {"hrv": "frwhoop-physiology-2", "sleep": "frwhoop-server-1",
                          "respiration": "frwhoop-server-1"}},
            {"defaults": {"hrv": "frwhoop-server-1", "sleep": "frwhoop-server-1"}},
            {"source_selections": ["frwhoop-server-1", "frwhoop-physiology-2"]},
            {"v2_canonical": ["hrv"]},
            {"history_canonical": ["sleep"]},
        ]
        for state in rejected_states:
            with self.subTest(state=state):
                result = self.run_final_verifier(**state)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn('release roles differ from the deployment plan', result.stderr)

    def test_final_verifier_executes_role_query_against_postgres_state(self):
        pg_bin = Path(os.environ.get("PG_BIN", "/opt/homebrew/opt/postgresql@18/bin"))
        if not all((pg_bin / name).is_file() for name in ("initdb", "pg_ctl", "psql")):
            self.skipTest("PostgreSQL integration binaries are unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data, socket = root / "data", root / "socket"
            socket.mkdir()
            subprocess.run([str(pg_bin / "initdb"), "-D", str(data), "-A", "trust", "--no-locale", "-E", "UTF8"],
                           check=True, capture_output=True, text=True)
            port = "55491"
            subprocess.run([str(pg_bin / "pg_ctl"), "-D", str(data), "-l", str(root / "postgres.log"), "-o",
                            f"-k {socket} -h '' -p {port}", "-w", "start"], check=True,
                           capture_output=True, text=True)
            def sql(statement):
                return subprocess.run([str(pg_bin / "psql"), "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
                                       "-h", str(socket), "-p", port, "-d", "postgres"], input=statement,
                                      text=True, capture_output=True, check=True).stdout.strip()
            try:
                sql(f'''
                  create table public.physiology_feature_defaults(feature text primary key,algorithm_version text not null);
                  create table public.physiology_source_selection(algorithm_version text not null);
                  create table public.release_test_canonical(algorithm_version text not null,feature text not null,
                    primary key(algorithm_version,feature));
                  create function public.physiology_feature_is_canonical(p_version text,p_feature text)
                    returns boolean language sql stable as $$select exists(select 1 from public.release_test_canonical
                      where algorithm_version=p_version and feature=p_feature)$$;
                  create table public.physiology_worker_heartbeats(
                    algorithm_version text not null,worker_instance_id uuid not null,source_revision text not null,
                    started_at timestamptz not null,last_poll_at timestamptz,last_score_at timestamptz,last_error text);
                  insert into public.physiology_worker_heartbeats values
                    ('frwhoop-server-1','11111111-1111-4111-8111-111111111111','{SHA}',now()-interval '1 minute',now(),now(),null),
                    ('frwhoop-physiology-2','22222222-2222-4222-8222-222222222222','{SHA}',now()-interval '1 minute',now(),now(),null),
                    ('frwhoop-server-2-history','33333333-3333-4333-8333-333333333333','{SHA}',now()-interval '1 minute',now(),now(),null);
                ''')
                binary_dir = root / "bin"
                binary_dir.mkdir()
                docker = binary_dir / "docker"
                docker.write_text(r'''#!/usr/bin/env python3
import os, sys, json
args=sys.argv[1:]; field=args[args.index('-f')+1]; name=args[-1]
lanes={
 'scoring-baseline-v1':('frwhoop-server-1','sha256:'+('3'*64),'11111111-1111-4111-8111-111111111111','null'),
 'scoring-physiology-v2':('frwhoop-physiology-2','sha256:'+('a'*64),'22222222-2222-4222-8222-222222222222','[]'),
 'scoring-history':('frwhoop-server-2-history','sha256:'+('a'*64),'33333333-3333-4333-8333-333333333333','["--history"]')}
algorithm,config,worker,command=lanes[name]
if field == '{{json .Config.Env}}':
 mode='canary' if os.environ.get('TEST_SCOPE')=='initial-selected-v1' else 'all-eligible'
 values=['SCORING_ADMISSION_MODE='+mode]
 if mode=='canary': values += ['SCORING_CANARY_OWNER_ID=11111111-1111-4111-8111-111111111112','SCORING_CANARY_DEVICE_ID=11111111-1111-4111-8111-111111111113']
 if os.environ.get('TEST_ADMISSION_OVERRIDE'): values=json.loads(os.environ['TEST_ADMISSION_OVERRIDE'])
 print(json.dumps(values))
elif '.Config.Env' in field:
 print('SCORING_ALGORITHM_VERSION='+algorithm); print('SCORING_WORKER_SOURCE_REVISION='+('a'*40)); print('SCORING_WORKER_INSTANCE_ID='+worker)
elif '.Config.Cmd' in field: print(command)
elif '.State.Running' in field: print('true')
elif '.RestartCount' in field: print('0')
elif '.HostConfig.RestartPolicy.Name' in field: print('unless-stopped')
elif field=='{{.Image}}': print(config)
elif 'org.opencontainers.image.revision' in field: print('a'*40)
else: raise AssertionError(field)
''')
                docker.chmod(0o755)
                query = root / "read-scoring-query.sh"
                query.write_text("#!/bin/sh\nexec " + shlex.quote(str(pg_bin / "psql")) +
                                 " -X -qAt -v ON_ERROR_STOP=1 -h " + shlex.quote(str(socket)) +
                                 " -p " + port + " -d postgres\n")
                query.chmod(0o755)
                admission_sha = admission_fixture(root)
                remote = SCRIPT.read_text().split("<<'VERIFY'\n", 1)[1].split("\nVERIFY\n", 1)[0]
                remote = remote.replace('/opt/frwhoop/scoring/read-scoring-query.sh', str(query))
                worker_verifier = root / 'verify-worker-image.py'
                worker_verifier.write_text(WORKER_VERIFIER)
                remote = remote.replace('/opt/frwhoop/scoring/verify-worker-image.py', str(worker_verifier))
                env = os.environ.copy()
                env["PATH"] = str(binary_dir) + os.pathsep + env["PATH"]
                bash = "/opt/homebrew/bin/bash" if Path("/opt/homebrew/bin/bash").exists() else "bash"
                def verify():
                    return subprocess.run([bash, "-s", "--", SHA, V1_CONFIG, V2_CONFIG, V1_IMAGE, V2_IMAGE,
                                           'full-fleet', str(root), admission_sha], input=remote,
                                          text=True, capture_output=True, env=env, timeout=10)
                def reset(extra=""):
                    sql("truncate public.physiology_feature_defaults,public.physiology_source_selection,"
                        "public.release_test_canonical; insert into public.physiology_feature_defaults values "
                        "('hrv','frwhoop-server-1'),('sleep','frwhoop-server-1'),"
                        "('respiration','frwhoop-server-1');" + extra)
                reset()
                accepted = verify()
                self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
                mutations = [
                    "update public.physiology_feature_defaults set algorithm_version='frwhoop-physiology-2' where feature='hrv';",
                    "delete from public.physiology_feature_defaults where feature='respiration';",
                    "insert into public.physiology_source_selection values ('frwhoop-physiology-2');",
                    "insert into public.release_test_canonical values ('frwhoop-physiology-2','hrv');",
                    "insert into public.release_test_canonical values ('frwhoop-server-2-history','sleep');",
                ]
                for mutation in mutations:
                    with self.subTest(mutation=mutation):
                        reset(mutation)
                        rejected = verify()
                        self.assertEqual(rejected.returncode, 3, rejected.stdout + rejected.stderr)
                        self.assertIn('release roles differ from the deployment plan', rejected.stderr)
            finally:
                subprocess.run([str(pg_bin / "pg_ctl"), "-D", str(data), "-m", "immediate", "-w", "stop"],
                               check=True, capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
