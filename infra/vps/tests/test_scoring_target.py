import importlib.util
from pathlib import Path
import tempfile
import unittest

VPS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("scoring_target", VPS / "scripts/read-deploy-target.py")
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class ScoringTargetTest(unittest.TestCase):
    def test_only_ip_and_port_are_parsed_without_shell_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "droplet.env"
            sentinel = Path(directory) / "should-not-exist"
            config.write_text(f'DROPLET_IP="192.0.2.1"\nSSH_PORT=22\nPASSWORD=$(touch {sentinel})\n')
            self.assertEqual(reader.target(config), "192.0.2.1|22")
            self.assertFalse(sentinel.exists())
            for bad in ("SSH_PORT=2222", "DROPLET_IP=$(hostname)", "DROPLET_IP=192.0.2.2"):
                config.write_text("DROPLET_IP=192.0.2.1\n" + bad + "\n")
                with self.assertRaises(ValueError):
                    reader.target(config)

    def test_every_remote_script_uses_only_the_explicit_public_key_on_port_22(self):
        for name in ("deploy-scoring-service.sh", "phase3-acceptance-checks.sh"):
            body = (VPS / "scripts" / name).read_text()
            self.assertNotIn('source "$DROPLET_ENV"', body)
            for option in ("-F /dev/null", "-o IdentitiesOnly=yes", "-o BatchMode=yes", "-o ConnectTimeout=10",
                           "-o PasswordAuthentication=no", "-o KbdInteractiveAuthentication=no", '-p "$SSH_PORT"'):
                self.assertIn(option, body)
            for line in body.splitlines():
                if "ssh " in line:
                    self.assertIn('ssh "${SSH_ARGS[@]}"', line)
