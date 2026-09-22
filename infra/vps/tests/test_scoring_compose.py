"""Validate standalone scoring limits with Compose; never start a container."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

VPS = Path(__file__).resolve().parents[1]


class ScoringComposeTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('docker'), 'Docker Compose CLI unavailable')
    def test_standalone_project_has_resource_limits_and_no_stack_or_public_port_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'compose.yml'
            env_file = root / 'scoring.env'
            env_file.write_text('DATABASE_URL=fixture\nSUPABASE_URL=fixture\n')
            b2_file = root / 'b2.env'
            b2_file.write_text('B2_BUCKET_NAME=fixture\n')
            config.write_text((VPS / 'templates/docker-compose.scoring-override.yml').read_text()
                              .replace('/opt/frwhoop/b2.env', str(b2_file)))
            env = dict(os.environ, SCORING_V2_IMAGE='fixture.invalid/v2@sha256:' + 'b'*64,
                       SCORING_ENV_FILE=str(env_file),
                       SCORING_BASELINE_IMAGE='fixture.invalid/baseline@sha256:' + 'a'*64,
                       SCORING_BASELINE_ENV_FILE=str(env_file), SCORING_HISTORY_ENV_FILE=str(env_file),
                       SCORING_CPUS='2.0', SCORING_MEMORY_LIMIT='2g')
            result = subprocess.run(['docker','compose','-p','scoring-fixture','-f',str(config),
                                     'config','--format','json'], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            resolved = json.loads(result.stdout)
            self.assertEqual(set(resolved['services']), {'scoring-baseline-v1','scoring-physiology-v2','scoring-history'})
            self.assertEqual(resolved['services']['scoring-baseline-v1']['environment']['SCORING_ALGORITHM_VERSION'], 'frwhoop-server-1')
            self.assertEqual(resolved['services']['scoring-baseline-v1']['image'], env['SCORING_BASELINE_IMAGE'])
            self.assertEqual(resolved['services']['scoring-physiology-v2']['image'], env['SCORING_V2_IMAGE'])
            self.assertEqual(resolved['services']['scoring-history']['image'], env['SCORING_V2_IMAGE'])
            self.assertEqual(resolved['services']['scoring-history']['command'], ['--history'])
            worker = resolved['services']['scoring-physiology-v2']
            self.assertEqual(float(worker['cpus']), 2)
            self.assertEqual(int(worker['mem_limit']), 2*1024**3)
            self.assertEqual(worker['pids_limit'], 256)
            self.assertTrue(worker['init'])
            self.assertEqual(worker['command'], [])
            self.assertEqual(worker['network_mode'], 'bridge')
            self.assertFalse(worker.get('ports'))
            self.assertFalse(worker.get('depends_on'))
            self.assertEqual(worker['logging']['options'], {'max-file':'3','max-size':'10m'})
