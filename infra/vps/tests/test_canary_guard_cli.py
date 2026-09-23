"""Actual guard/verifier CLIs with real OCI bytes; only Docker is a fixture.

These tests do not establish real daemon, systemd, target-host or phone readiness.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import unittest

from test_pinned_postgres_client import encoded, digest, write_tar

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('guard_cli_fixtures', ROOT / 'scripts/test-scoped-canary-guard.py')
fixtures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixtures)


class GuardArchiveCLITest(unittest.TestCase):
    setUp = fixtures.ActualGuardCLITest.setUp
    tearDown = fixtures.ActualGuardCLITest.tearDown
    write_private = fixtures.ActualGuardCLITest.write_private
    run_cli = fixtures.ActualGuardCLITest.run_cli

    def prepare_archives(self, *, intake_contract='2', corrupt_intake=False):
        self.images = {}
        self.archives = {}
        for bound in self.configured['containers']:
            role = bound['role']
            labels = {'org.opencontainers.image.revision': fixtures.SOURCE,
                      'io.frwhoop.image.platform': 'linux/amd64'}
            if role == 'intake':
                labels.update({'org.frwhoop.worker.role': 'intake',
                               'org.frwhoop.intake.contract-version': intake_contract})
            else:
                labels.update({'io.frwhoop.algorithm.version': 'frwhoop-server-1',
                               'io.frwhoop.heartbeat.contract': 'physiology_worker_heartbeats-v1',
                               'io.frwhoop.database.ca.sha256':
                               '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7'})
            image_config = {**bound['command'], 'Labels': labels}
            config_bytes = encoded({'os': 'linux', 'architecture': 'amd64', 'config': image_config})
            config_digest = digest(config_bytes)
            manifest = encoded({'schemaVersion': 2, 'config': {'digest': config_digest,
                                'size': len(config_bytes)}, 'layers': []})
            manifest_digest = digest(manifest)
            descriptor = {'digest': manifest_digest, 'size': len(manifest)}
            reference = 'fixture.invalid/' + role + '@' + manifest_digest
            archive = self.root / (role + '.tar')
            entries = {'oci-layout': encoded({'imageLayoutVersion': '1.0.0'}),
                       'index.json': encoded({'manifests': [descriptor]}),
                       'blobs/sha256/' + manifest_digest[7:]: manifest,
                       'blobs/sha256/' + config_digest[7:]: config_bytes}
            if role == 'intake' and corrupt_intake:
                # Keep both supplied digests unchanged while replacing actual config bytes.
                entries['blobs/sha256/' + config_digest[7:]] = config_bytes.replace(b'linux', b'other')
            write_tar(archive, entries)
            observed_image = {'Id': manifest_digest, 'RepoDigests': [reference],
                              'Os': 'linux', 'Architecture': 'amd64',
                              'Descriptor': descriptor, 'Config': image_config}
            self.images[reference] = self.images[manifest_digest] = observed_image
            self.archives[reference] = str(archive)
            bound.update(image=manifest_digest, configDigest=config_digest)
            self.plan['images']['intake' if role == 'intake' else 'selectedV1'] = {
                'reference': reference, 'manifestDigest': manifest_digest, 'configDigest': config_digest}
        self.plan.pop('deploymentFingerprintSha256')
        self.plan['deploymentFingerprintSha256'] = hashlib.sha256(encoded(self.plan)).hexdigest()
        self.configured['deploymentFingerprintSha256'] = self.plan['deploymentFingerprintSha256']
        self.write_private('plan.json', self.plan)
        (self.root / 'binding.json').unlink()
        self.observed = {b['id']: fixtures.inspection(b, self.configured, running=False)
                         for b in self.configured['containers']}
        (self.root / 'inspect.json').write_text(json.dumps(self.observed))
        (self.root / 'images.json').write_text(json.dumps(self.images))
        (self.root / 'archives.json').write_text(json.dumps(self.archives))
        (self.root / 'docker').write_text('''#!/usr/bin/env python3
import json,shutil,sys,time
from pathlib import Path
r=Path(__file__).parent; args=sys.argv[1:]
with (r/'commands.jsonl').open('a') as f: f.write(json.dumps(args)+'\\n')
state=json.loads((r/'inspect.json').read_text())
if args[:2]==['image','inspect']:
 print(json.dumps([json.loads((r/'images.json').read_text())[args[2]]]))
elif args[:2]==['image','save']:
 shutil.copyfile(json.loads((r/'archives.json').read_text())[args[-1]],args[3])
elif args[0]=='inspect': print(json.dumps([state[args[1]]]))
elif args[0]=='start':
 state[args[1]]['State']['Running']=True; (r/'inspect.json').write_text(json.dumps(state))
 if (r/'interrupt-during-start').exists():
  (r/'signal-ready').write_text('first start issued'); time.sleep(20)
elif args[0]=='stats':
 (r/'signal-ready').write_text('observation entered'); time.sleep(20)
elif args[0]=='stop':
 state[args[-1]]['State']['Running']=False; (r/'inspect.json').write_text(json.dumps(state))
else: sys.exit(4)
''')
        (self.root / 'docker').chmod(0o700)

    def bind(self):
        args = [sys.executable, str(self.root / 'scoped-canary-guard.py'), 'bind',
                '--binding', str(self.root / 'binding.json'), '--plan', str(self.root / 'plan.json'),
                '--policy', str(self.root / 'policy.json'),
                '--intake-container', self.configured['containers'][0]['id'],
                '--baseline-container', self.configured['containers'][1]['id']]
        return subprocess.run(args, capture_output=True, text=True, timeout=10,
                              env={**os.environ, 'PATH': str(self.root) + os.pathsep + os.environ['PATH']})

    def commands(self):
        path = self.root / 'commands.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_bind_executes_real_archive_verifier_before_writing_private_binding(self):
        self.prepare_archives()
        result = self.bind()
        self.assertEqual(result.returncode, 0, result.stderr)
        bound = json.loads((self.root / 'binding.json').read_text())
        self.assertEqual((self.root / 'binding.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(bound['containers'], self.configured['containers'])
        self.assertTrue(all(item['image'] != item['configDigest'] for item in bound['containers']))
        self.assertEqual(len([c for c in self.commands() if c[:2] == ['image', 'save']]), 2)
        self.assertFalse(any(c[0] in ('start', 'run', 'stop', 'rm', 'update') for c in self.commands()))
        result, _ = self.run_cli('validate')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_archive_config_tamper_rejected_without_binding_or_container_mutation(self):
        self.prepare_archives(corrupt_intake=True)
        result = self.bind()
        self.assertEqual(result.returncode, 3)
        self.assertFalse((self.root / 'binding.json').exists())
        self.assertEqual(len([c for c in self.commands() if c[:2] == ['image', 'save']]), 1)
        self.assertFalse(any(c[0] in ('start', 'run', 'stop', 'rm', 'update') for c in self.commands()))

    def test_old_intake_contract_with_matching_archive_digests_cannot_bind(self):
        self.prepare_archives(intake_contract='1')
        result = self.bind()
        self.assertEqual(result.returncode, 3)
        self.assertFalse((self.root / 'binding.json').exists())
        self.assertFalse(any(c[0] in ('start', 'run', 'stop', 'rm', 'update') for c in self.commands()))

    def interrupted_run(self, during_first_start):
        self.prepare_archives()
        result = self.bind()
        self.assertEqual(result.returncode, 0, result.stderr)
        if during_first_start:
            (self.root / 'interrupt-during-start').touch()
        args = [sys.executable, str(self.root / 'scoped-canary-guard.py'), 'run', '--execute',
                '--binding', str(self.root / 'binding.json'), '--plan', str(self.root / 'plan.json'),
                '--policy', str(self.root / 'policy.json')]
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   env={**os.environ, 'PATH': str(self.root) + os.pathsep + os.environ['PATH']})
        try:
            deadline = time.monotonic() + 5
            while not (self.root / 'signal-ready').exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root / 'signal-ready').exists(), 'guard never reached instrumented Docker boundary')
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
        finally:
            if process.poll() is None:
                process.kill(); process.communicate(timeout=5)
        self.assertEqual(process.returncode, 3, stderr)
        self.assertIn('BOUND_CANARY_STOPPED', stdout)
        for private in (fixtures.OWNER, fixtures.DEVICE, 'CANARY_OWNER_ID', 'CANARY_DEVICE_ID'):
            self.assertNotIn(private, stdout + stderr)
        ids = [b['id'] for b in self.configured['containers']]
        self.assertEqual([c[1] for c in self.commands() if c[0] == 'start'], ids[:1] if during_first_start else ids)
        self.assertEqual([c[-1] for c in self.commands() if c[0] == 'stop'], ids)
        self.assertTrue(all(not c['State']['Running'] for c in json.loads((self.root / 'inspect.json').read_text()).values()))

    def test_sigterm_during_first_start_stops_both_exact_bound_ids(self):
        self.interrupted_run(during_first_start=True)

    def test_sigterm_during_observation_stops_both_exact_bound_ids(self):
        self.interrupted_run(during_first_start=False)

    def test_emergency_stop_does_not_import_missing_or_invalid_admission_dependency(self):
        dependency = self.root / 'scoring-admission.py'
        for present in (True, False):
            with self.subTest(dependency_present=present):
                if present:
                    dependency.write_text('this is invalid Python syntax!\n')
                else:
                    dependency.unlink()
                (self.root / 'commands.jsonl').unlink(missing_ok=True)
                result, commands = self.run_cli('stop', execute=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([c[-1] for c in commands if c[0] == 'stop'],
                                 [b['id'] for b in self.configured['containers']])


if __name__ == '__main__':
    unittest.main()
