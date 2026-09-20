from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

VPS = Path(__file__).resolve().parents[1]


class ScoringAcceptanceTest(unittest.TestCase):
    def run_checks(self, *arguments):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'infra/vps/scripts'
            scripts.mkdir(parents=True)
            for name in ('phase3-acceptance-checks.sh', 'check-scoring-imports.py', 'read-deploy-target.py'):
                shutil.copy(VPS / 'scripts' / name, scripts / name)
            service = root / 'scoring-service'
            (service / 'service/src/main/kotlin').mkdir(parents=True)
            runner = service / 'gradlew'
            runner.write_text('#!/bin/sh\nexit 0\n')
            runner.chmod(0o755)
            migrations = root / 'supabase/migrations'
            migrations.mkdir(parents=True)
            (migrations / '20260918100000_physiology_independent_work.sql').write_text(
                'physiology_service_heartbeats\nphysiology_work_items\nengine_publish_physiology\n')
            # This must never be sourced in either a missing-key failure or local-only mode.
            sentinel = root / 'password-was-sourced'
            (root / 'infra/vps/droplet.env').write_text(f'DROPLET_IP=192.0.2.1\nPASSWORD=$(touch {sentinel})\n')
            environment = dict(os.environ, JAVA_HOME='/synthetic-no-jvm-needed')
            result = subprocess.run(['bash', str(scripts / 'phase3-acceptance-checks.sh'), *arguments],
                                    text=True, capture_output=True, env=environment, timeout=5)
            return result, sentinel.exists()

    def test_default_missing_vps_key_is_not_ready_not_pass(self):
        result, sourced = self.run_checks()
        self.assertEqual(result.returncode, 3)
        self.assertIn('NOT_READY', result.stderr)
        self.assertNotIn('PASS:', result.stdout)
        self.assertFalse(sourced)

    def test_explicit_local_only_does_not_claim_deployment_acceptance(self):
        result, sourced = self.run_checks('--local-only')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('LOCAL_ONLY_PASS', result.stdout)
        self.assertIn('deployment acceptance NOT_VERIFIED', result.stdout)
        self.assertNotIn('exact VPS deployment progress verified', result.stdout)
        self.assertFalse(sourced)
