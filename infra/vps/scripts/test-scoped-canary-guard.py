#!/usr/bin/env python3
"""Guard contracts and actual CLI ordering; Docker fixtures never touch a daemon."""
import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('guard', ROOT / 'scripts/scoped-canary-guard.py')
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)
POLICY = json.loads((ROOT / 'scoped-canary-stop-policy.json').read_text())
OWNER = '11111111-1111-4111-8111-111111111111'
DEVICE = '22222222-2222-4222-8222-222222222222'
INSTANCE = '33333333-3333-4333-8333-333333333333'
SOURCE = 'a' * 40
NOW = 1800000000


def timestamp(seconds=NOW):
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat()


def binding():
    return {'sourceRevision': SOURCE, 'admission': {'mode': 'canary', 'ownerId': OWNER, 'deviceId': DEVICE},
            'containers': [{'id': str(i) * 64, 'image': 'sha256:' + str(i + 2) * 64,
                            'configDigest': 'sha256:' + str(i + 4) * 64,
                            'role': role, 'instanceId': INSTANCE, 'restartCount': 0,
                            'command': {'Entrypoint': ['/app/run'], 'Cmd': [], 'User': 'worker', 'WorkingDir': '/app'}}
                           for i, role in [(1, 'intake'), (2, 'baseline')]]}


def inspection(bound, configured, running=True):
    prefix = 'INTAKE_' if bound['role'] == 'intake' else 'SCORING_'
    env = {'ADMISSION_MODE': 'canary', 'CANARY_OWNER_ID': OWNER, 'CANARY_DEVICE_ID': DEVICE,
           'WORKER_SOURCE_REVISION': SOURCE, 'WORKER_INSTANCE_ID': INSTANCE}
    return {'Id': bound['id'], 'Image': bound['image'], 'RestartCount': 0,
            'Config': {**bound['command'], 'Labels': {'org.opencontainers.image.revision': SOURCE},
                       'Env': [prefix + key + '=' + val for key, val in env.items()]},
            'HostConfig': {'Memory': (2 if bound['role'] == 'intake' else 1) * 1024 ** 3,
                           'NanoCpus': 1_000_000_000, 'RestartPolicy': {'Name': 'no'}},
            'State': {'Running': running, 'OOMKilled': False, 'Restarting': False}}


def status():
    result = {'captured_at': timestamp(), 'source_revision': SOURCE, 'instance_id': INSTANCE,
              'contract_version': 2, 'admission_mode': 'canary', 'owner_cap': 1, 'device_cap': 1,
              'database': {'connections': 10, 'max_connections': 60, 'reserved_connections': 3},
              'lanes': [{'lane': lane, 'last_successful_poll_at': timestamp(), 'last_poll_failed': False,
                         'polls': 1, 'claimed': 0, 'completed': 0, 'failures': 0}
                        for lane in ('verification', 'projection', 'legacy')], 'latest_publication_marker': None}
    for name in ('verification', 'projection', 'legacy', 'scoring'):
        result[name] = {'pending_at_least': 0, 'truncated': False, 'oldest_age_seconds': None}
    return result


def resources():
    return {'memoryAvailable': 2 * 1024 ** 3, 'diskFree': 20 * 1024 ** 3,
            'containerMemoryPercent': {str(i) * 64: 20 for i in (1, 2)}}


class StopPolicyTest(unittest.TestCase):
    def test_complete_idle_observations_are_within_thresholds(self):
        guard.Evaluator(POLICY, 0).evaluate(status(), resources(), binding(), NOW, 61)

    def test_missing_stale_wrong_scope_and_failed_observations_stop(self):
        changes = [lambda s: s.pop('database'), lambda s: s.update(source_revision='b' * 40),
                   lambda s: s.update(instance_id=OWNER), lambda s: s.update(captured_at=timestamp(NOW - 31)),
                   lambda s: s.update(captured_at=timestamp(NOW + 6)), lambda s: s.update(lanes=[]),
                   lambda s: s['lanes'].append(s['lanes'][0]),
                   lambda s: s['lanes'][0].update(last_poll_failed=True),
                   lambda s: s['lanes'][1].update(last_successful_poll_at=timestamp(NOW - 31)),
                   lambda s: s['database'].update(connections=46),
                   lambda s: s['legacy'].update(truncated=True),
                   lambda s: s['verification'].update(pending_at_least=1001),
                   lambda s: s['projection'].update(pending_at_least=True)]
        for change in changes:
            with self.subTest(change=change):
                observed = status(); change(observed)
                with self.assertRaises(ValueError):
                    guard.Evaluator(POLICY, 0).evaluate(observed, resources(), binding(), NOW, 61)

    def test_missing_or_excessive_resources_stop(self):
        changes = [lambda r: r.update(memoryAvailable=0), lambda r: r.update(diskFree=0),
                   lambda r: r.update(containerMemoryPercent={}),
                   lambda r: r['containerMemoryPercent'].update({'1' * 64: 91}),
                   lambda r: r['containerMemoryPercent'].update({'1' * 64: float('nan')})]
        for change in changes:
            observed = resources(); change(observed)
            with self.assertRaises(ValueError):
                guard.Evaluator(POLICY, 0).evaluate(status(), observed, binding(), NOW, 61)

    def test_debt_growth_is_not_progress_and_legacy_is_covered(self):
        for queue in ('verification', 'projection', 'legacy', 'scoring'):
            observed = status(); observed[queue]['pending_at_least'] = 1
            evaluator = guard.Evaluator(POLICY, 0)
            evaluator.evaluate(observed, resources(), binding(), NOW, 61)
            observed[queue]['pending_at_least'] = 2
            with self.assertRaisesRegex(ValueError, 'queue_stalled'):
                evaluator.evaluate(observed, resources(), binding(), NOW, 182)

    def test_completion_and_real_outbox_marker_advance_without_faking_latency(self):
        observed = status(); observed['scoring']['pending_at_least'] = 1
        evaluator = guard.Evaluator(POLICY, 0)
        evaluator.evaluate(observed, resources(), binding(), NOW, 61)
        observed['latest_publication_marker'] = '42'
        evaluator.evaluate(observed, resources(), binding(), NOW, 182)
        observed['latest_publication_marker'] = None
        with self.assertRaisesRegex(ValueError, 'queue_stalled'):
            evaluator.evaluate(observed, resources(), binding(), NOW, 303)

    def test_container_drift_stops_even_when_it_invalidates_start_checks(self):
        configured = binding(); bound = configured['containers'][0]
        observed = inspection(bound, configured)
        observed['HostConfig']['Memory'] = 0
        observed['Config']['Env'] = []
        observed['Config']['Labels'] = {}
        with self.assertRaises(ValueError):
            guard.verify_container(observed, bound, configured)
        guard.verify_container(observed, bound, configured, stopping=True)
        observed['Id'] = 'f' * 64
        with self.assertRaises(ValueError):
            guard.verify_container(observed, bound, configured, stopping=True)

    def test_command_and_restart_overrides_rejected_before_start(self):
        configured = binding(); bound = configured['containers'][0]
        for change in (lambda o: o['Config'].update(Cmd=['--once']),
                       lambda o: o['HostConfig'].update(RestartPolicy={'Name': 'unless-stopped'}),
                       lambda o: o.update(RestartCount=1)):
            observed = inspection(bound, configured); change(observed)
            with self.assertRaises(ValueError):
                guard.verify_container(observed, bound, configured)

    def test_whole_observation_budget_is_shared_across_commands(self):
        configured = binding()
        with patch.object(guard.time, 'monotonic', side_effect=[0, 1, 9, 16]), \
             patch.object(guard, 'inspect', return_value=inspection(configured['containers'][0], configured)) as inspect, \
             patch.object(guard, 'command', return_value=b'20%') as command:
            with self.assertRaisesRegex(ValueError, 'observation_deadline'):
                guard.observe(configured)
            self.assertEqual(inspect.call_count, 1)
            self.assertEqual(command.call_args.args[1], 6)


class ActualGuardCLITest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='canary-guard-')
        self.root = Path(self.temp.name)
        for name in ('scoped-canary-guard.py', 'scoring-admission.py', 'verify-worker-image.py', 'verify-pinned-postgres-client.py'):
            shutil.copyfile(ROOT / 'scripts' / name, self.root / name)
        shutil.copyfile(ROOT / 'templates/frwhoop-scoped-canary.service', self.root / 'frwhoop-scoped-canary.service')
        shutil.copyfile(ROOT / 'scoped-canary-stop-policy.json', self.root / 'policy.json')
        self.configured = binding()
        self.configured.update(schemaVersion=1, admissionSha256=guard.admission.fingerprint(self.configured['admission']))
        def identity(name):
            data = (self.root / name).read_bytes()
            return {'path': name, 'sha256': hashlib.sha256(data).hexdigest(), 'sizeBytes': len(data)}
        self.plan = {'kind': 'frwhoop-worker-deployment', 'scope': 'initial-selected-v1', 'source': {'commit': SOURCE},
                     'admission': self.configured['admission'], 'admissionSha256': self.configured['admissionSha256'],
                     'intake': {'instanceId': INSTANCE}, 'images': {},
                     'canaryGuard': {'policy': identity('policy.json'), 'helper': identity('scoped-canary-guard.py'),
                                     'service': identity('frwhoop-scoped-canary.service'),
                                     'dependencies': [identity(n) for n in ('scoring-admission.py', 'verify-worker-image.py', 'verify-pinned-postgres-client.py')]}}
        for bound in self.configured['containers']:
            self.plan['images']['intake' if bound['role'] == 'intake' else 'selectedV1'] = {
                'configDigest': bound['configDigest'], 'manifestDigest': bound['image']}
        self.plan['deploymentFingerprintSha256'] = guard.admission.fingerprint(self.plan)
        self.configured.update(deploymentFingerprintSha256=self.plan['deploymentFingerprintSha256'],
                               policySha256=self.plan['canaryGuard']['policy']['sha256'])
        self.write_private('plan.json', self.plan); self.write_private('binding.json', self.configured)
        self.observed = {b['id']: inspection(b, self.configured, running=False) for b in self.configured['containers']}
        (self.root / 'inspect.json').write_text(json.dumps(self.observed))
        (self.root / 'docker').write_text('''#!/usr/bin/env python3
import json,sys
from pathlib import Path
r=Path(__file__).parent; args=sys.argv[1:]
with (r/'commands.jsonl').open('a') as f: f.write(json.dumps(args)+'\\n')
state=json.loads((r/'inspect.json').read_text())
if args[0]=='inspect': print(json.dumps([state[args[1]]]))
elif args[0]=='start':
 state[args[1]]['State']['Running']=True; (r/'inspect.json').write_text(json.dumps(state))
elif args[0]=='stats': print('missing')
elif args[0]=='stop': pass
else: sys.exit(4)
''')
        (self.root / 'docker').chmod(0o700)

    def write_private(self, name, value):
        path = self.root / name; path.write_text(json.dumps(value)); path.chmod(0o600)

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, action, execute=False):
        args = [sys.executable, str(self.root / 'scoped-canary-guard.py'), action,
                '--binding', str(self.root / 'binding.json'), '--plan', str(self.root / 'plan.json'),
                '--policy', str(self.root / 'policy.json')]
        if execute: args.append('--execute')
        env = {**os.environ, 'PATH': str(self.root) + os.pathsep + os.environ['PATH']}
        result = subprocess.run(args, capture_output=True, text=True, timeout=10, env=env)
        for private in (OWNER, DEVICE, 'CANARY_OWNER_ID', 'CANARY_DEVICE_ID'):
            self.assertNotIn(private, result.stdout + result.stderr)
        commands = self.root / 'commands.jsonl'
        return result, [json.loads(line) for line in commands.read_text().splitlines()] if commands.exists() else []

    def test_manifest_engine_id_is_distinct_from_config_and_validates(self):
        result, commands = self.run_cli('validate')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(command[0] == 'inspect' for command in commands))

    def test_actual_run_starts_only_bound_ids_and_stops_both_on_missing_observation(self):
        result, commands = self.run_cli('run', execute=True)
        self.assertEqual(result.returncode, 3)
        ids = [b['id'] for b in self.configured['containers']]
        self.assertEqual([c[1] for c in commands if c[0] == 'start'], ids)
        self.assertEqual([c[-1] for c in commands if c[0] == 'stop'], ids)
        self.assertIn('BOUND_CANARY_STOPPED', result.stdout)

    def test_no_execute_policy_tamper_and_dependency_tamper_never_start(self):
        result, commands = self.run_cli('run')
        self.assertEqual(result.returncode, 3); self.assertFalse(commands)
        (self.root / 'policy.json').write_text(json.dumps({**POLICY, 'maximumContainerMemoryPercent': 999}))
        result, commands = self.run_cli('run', execute=True)
        self.assertEqual(result.returncode, 3); self.assertFalse(commands)
        shutil.copyfile(ROOT / 'scoped-canary-stop-policy.json', self.root / 'policy.json')
        (self.root / 'verify-worker-image.py').write_text('# changed\n')
        result, commands = self.run_cli('run', execute=True)
        self.assertEqual(result.returncode, 3); self.assertFalse(commands)

    def test_start_refuses_running_container_and_stop_ignores_drift_on_same_id(self):
        first = self.configured['containers'][0]['id']
        self.observed[first]['State']['Running'] = True
        (self.root / 'inspect.json').write_text(json.dumps(self.observed))
        result, commands = self.run_cli('run', execute=True)
        self.assertEqual(result.returncode, 3); self.assertFalse(any(c[0] == 'start' for c in commands))
        self.observed[first]['Config']['Env'] = []
        self.observed[first]['HostConfig']['Memory'] = 0
        (self.root / 'inspect.json').write_text(json.dumps(self.observed))
        result, commands = self.run_cli('stop', execute=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len([c for c in commands if c[0] == 'stop']), 2)

    def test_emergency_stop_preserves_id_plan_fence_when_policy_or_verifier_changed(self):
        (self.root / 'policy.json').unlink()
        (self.root / 'verify-worker-image.py').write_text('# corrupted\n')
        result, commands = self.run_cli('stop', execute=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len([c for c in commands if c[0] == 'stop']), 2)
        self.configured['containers'][0]['image'] = 'sha256:' + 'f' * 64
        self.write_private('binding.json', self.configured)
        (self.root / 'commands.jsonl').unlink()
        result, commands = self.run_cli('stop', execute=True)
        self.assertEqual(result.returncode, 3)
        self.assertFalse(commands)


if __name__ == '__main__':
    unittest.main()
