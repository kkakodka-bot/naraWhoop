"""Actual private-file and container-scope enforcement; no hosted services are used."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/scoring-admission.py'
SPEC = importlib.util.spec_from_file_location('scoring_admission', SCRIPT)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
CANARY = {'mode':'canary', 'ownerId':'11111111-1111-4111-8111-111111111112',
          'deviceId':'11111111-1111-4111-8111-111111111113'}


def save(filename, value):
    filename.write_text(json.dumps(value)); filename.chmod(0o600)


class ScoringAdmissionTest(unittest.TestCase):
    def test_missing_partial_malformed_and_global_expansion_rejected(self):
        for value in (None, {}, {'mode':'canary'}, {**CANARY,'deviceId':'1-1-1-1-1'},
                      {**CANARY,'ownerId':'00000000-0000-0000-0000-000000000000'},
                      {'mode':'all-eligible'}, {**CANARY,'extra':1}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                M.admission(value, 'initial-selected-v1', M.fingerprint(value))
        with self.assertRaises(ValueError):
            M.admission(CANARY, 'full-fleet', M.fingerprint(CANARY))
        self.assertEqual(M.admission({'mode':'all-eligible'}, 'full-fleet',
                                    M.fingerprint({'mode':'all-eligible'})), {'mode':'all-eligible'})

    def test_private_regular_descriptor_rejects_symlink_public_and_corrupt_json(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory)/'private.json'; save(file,CANARY)
            self.assertEqual(M.private_json(file), CANARY)
            link = Path(directory)/'link.json'; link.symlink_to(file)
            with self.assertRaises(OSError): M.private_json(link)
            file.chmod(0o644)
            with self.assertRaises(ValueError): M.private_json(file)
            file.chmod(0o600); file.write_text('{private invalid')
            with self.assertRaises(ValueError): M.private_json(file)

    def test_plan_hash_and_both_producer_scope_binding_before_export(self):
        plan = {'scope':'initial-selected-v1','admission':CANARY,
                'admissionSha256':M.fingerprint(CANARY),'baselineEnvironment':M.environment(CANARY)}
        plan['deploymentFingerprintSha256'] = M.fingerprint(plan)
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory)/'private.json'
            M.extract_plan(plan,plan['deploymentFingerprintSha256'],M.fingerprint(CANARY),file)
            self.assertEqual(M.private_json(file), CANARY)
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
            for key in ('admission','baselineEnvironment'):
                changed = copy.deepcopy(plan); changed[key] = {}
                with self.assertRaises(ValueError):
                    M.extract_plan(changed,plan['deploymentFingerprintSha256'],M.fingerprint(CANARY),file)
            with self.assertRaises(FileExistsError):
                M.extract_plan(plan,plan['deploymentFingerprintSha256'],M.fingerprint(CANARY),file)

    def test_append_preserves_private_credentials_and_rejects_duplicate_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory)/'worker.env'; file.write_text('DATABASE_URL=private-value\n'); file.chmod(0o600)
            M.append_environment(CANARY,file)
            env = dict(line.split('=',1) for line in file.read_text().splitlines())
            self.assertEqual(env['DATABASE_URL'],'private-value')
            self.assertEqual({k:v for k,v in env.items() if k.startswith('SCORING_')},M.environment(CANARY))
            before = file.read_bytes()
            with self.assertRaises(ValueError): M.append_environment(CANARY,file)
            self.assertEqual(file.read_bytes(),before)

    def test_actual_container_scope_must_match_without_duplicate_or_stale_identity(self):
        expected = [key+'='+val for key,val in M.environment(CANARY).items()]
        def response(values): return subprocess.CompletedProcess([],0,stdout=json.dumps(values).encode())
        with patch.object(M.subprocess,'run',return_value=response(expected+['DATABASE_URL=private'])):
            M.verify_container(CANARY,'scoring-baseline-v1')
        for values in ([],expected[:-1],expected+expected[:1],
                       [v.replace(CANARY['deviceId'],CANARY['ownerId']) for v in expected]):
            with patch.object(M.subprocess,'run',return_value=response(values)), self.assertRaises(ValueError):
                M.verify_container(CANARY,'scoring-baseline-v1')
        with patch.object(M.subprocess,'run',return_value=response(['SCORING_ADMISSION_MODE=all-eligible',
                        'SCORING_CANARY_OWNER_ID='])), self.assertRaises(ValueError):
            M.verify_container({'mode':'all-eligible'},'scoring-baseline-v1')

    def test_cli_success_and_failure_never_emit_private_identifiers(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'private.json';save(file,CANARY)
            for scope,code in (('initial-selected-v1',0),('full-fleet',3)):
                result=subprocess.run(['python3',str(SCRIPT),'validate','--input',str(file),'--scope',scope,
                    '--admission-sha256',M.fingerprint(CANARY)],capture_output=True,text=True)
                self.assertEqual(result.returncode,code,result.stderr)
                for private in (CANARY['ownerId'],CANARY['deviceId']):
                    self.assertNotIn(private,result.stdout+result.stderr)
