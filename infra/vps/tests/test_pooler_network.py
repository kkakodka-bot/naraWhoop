"""Real Docker Compose configuration tests; never starts a container or reads production env."""
import importlib.util
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/remote/14-pooler-network.py"
SECRET = "fixture-secret-must-not-be-printed"


class PoolerNetworkTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("docker"):
            raise unittest.SkipTest("Docker Compose CLI unavailable")
        check = subprocess.run(["docker", "compose", "version"], capture_output=True)
        if check.returncode:
            raise unittest.SkipTest("Docker Compose CLI unavailable")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pooler-network-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = ("POSTGRES_PORT=5432\nPOOLER_PROXY_PORT_TRANSACTION=6543\n"
                    "UNCHANGED_SECRET=" + SECRET + "\n").encode()
        (self.root / ".env").write_bytes(self.env)
        self.base = self.root / "docker-compose.yml"

    def base_with_ports(self, ports):
        self.base.write_text("# untouched header\nservices:\n  supavisor:\n"
                             "    image: supabase/supavisor:2.9.12\n"
                             "    container_name: supabase-pooler\n"
                             "    ports:\n" + ports + "\n"
                             "    environment:\n      UNCHANGED_SECRET: ${UNCHANGED_SECRET}\n"
                             "    restart: unless-stopped\n# untouched footer\n")

    def helper(self, *args, success=True):
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.root), *args],
                                capture_output=True, text=True, timeout=60)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        self.assertEqual((self.root / ".env").read_bytes(), self.env)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def config(self, files=None):
        args = ["docker", "compose"]
        for path in files or []:
            args += ["-f", str(path)]
        result = subprocess.run([*args, "config", "--format", "json"], cwd=self.root,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def assert_private(self, files=None):
        service = self.config(files)["services"]["supavisor"]
        ports = service["ports"]
        self.assertEqual({port["target"] for port in ports}, {5432, 6543})
        self.assertTrue(all(port["host_ip"] == "127.0.0.1" for port in ports))
        self.assertEqual(service["environment"]["UNCHANGED_SECRET"], SECRET)

    def test_short_syntax_quoted_variables_and_defaults(self):
        variants = [
            '      - ${POSTGRES_PORT}:5432\n      - ${POOLER_PROXY_PORT_TRANSACTION}:6543',
            '      - "${POSTGRES_PORT}:5432/tcp"\n      - \'${POOLER_PROXY_PORT_TRANSACTION}:6543\'',
            '      - "0.0.0.0:${MISSING_PORT:-5432}:5432"\n      - "[::]:${POOLER_PROXY_PORT_TRANSACTION}:6543"',
        ]
        for ports in variants:
            with self.subTest(ports=ports):
                self.base_with_ports(ports)
                before = self.base.read_bytes()
                self.helper("--check", success=False)
                self.helper()  # Planning must not change the original configuration.
                self.assertEqual(before, self.base.read_bytes())
                self.helper("--write")
                self.assert_private([self.base])
                self.assert_private()
                text = self.base.read_text()
                self.assertTrue(text.startswith("# untouched header\n"))
                self.assertIn("    environment:\n      UNCHANGED_SECRET: ${UNCHANGED_SECRET}\n", text)
                self.assertTrue(text.endswith("# untouched footer\n"))
                self.helper("--check")

    def test_long_syntax_and_flow_sequence_are_supported(self):
        self.base_with_ports('      - target: 5432\n        published: "${POSTGRES_PORT}"\n'
                             '        host_ip: "::"\n        protocol: tcp\n'
                             '      - {target: 6543, published: "${POOLER_PROXY_PORT_TRANSACTION}", host_ip: "0.0.0.0"}')
        self.helper("--write")
        self.assert_private([self.base])
        self.base.write_text('services: {supavisor: {image: fixture, ports: ["5432:5432", "6543:6543"], '
                             'environment: {UNCHANGED_SECRET: "${UNCHANGED_SECRET}"}}}\n')
        self.helper("--write")
        self.assert_private([self.base])

    def test_base_is_private_even_when_explicit_file_selection_omits_default_override(self):
        self.base_with_ports('      - "5432:5432"\n      - "6543:6543"')
        override = self.root / "docker-compose.override.yml"
        override.write_text('services:\n  supavisor:\n    ports:\n'
                            '      - "127.0.0.1:5432:5432"\n      - "0.0.0.0:6543:6543"\n'
                            '  studio:\n    image: fixture\n    ports: ["127.0.0.1:3000:3000"]\n')
        self.helper("--write")
        self.assert_private([self.base])
        self.assert_private([self.base, override])
        self.assert_private()
        self.assertEqual(self.config()["services"]["studio"]["ports"][0]["host_ip"], "127.0.0.1")

    def test_explicit_additional_overlay_is_repaired_without_editing_unrelated_settings(self):
        self.base_with_ports('      - "127.0.0.1:5432:5432"\n      - "127.0.0.1:6543:6543"')
        overlay = self.root / "worker.yml"
        overlay.write_text('services:\n  supavisor:\n    ports: ["[::]:5432:5432"]\n'
                          '  scoring:\n    image: fixture-worker\n    environment: {UNCHANGED_SECRET: "${UNCHANGED_SECRET}"}\n')
        self.helper("--write", "--additional-file", str(overlay))
        self.assert_private([self.base, overlay])
        self.assertIn('    image: fixture-worker\n', overlay.read_text())

    def test_existing_private_configuration_is_idempotent_and_backups_are_private(self):
        self.base_with_ports('      - "5432:5432"\n      - "6543:6543"')
        first = json.loads(self.helper("--write").stdout)
        current = self.base.read_bytes()
        self.assertEqual(len(first["backups"]), 1)
        self.assertEqual(os.stat(first["backups"][0]).st_mode & 0o777, 0o600)
        second = json.loads(self.helper("--write").stdout)
        self.assertEqual(second["changed_files"], [])
        self.assertEqual(current, self.base.read_bytes())

    def test_shared_aliases_and_anchors_fail_closed_without_altering_other_services(self):
        self.base.write_text('x-ports: &shared ["5432:5432", "6543:6543"]\n'
                             'services:\n  supavisor:\n    image: fixture\n    ports: *shared\n')
        original = self.base.read_bytes()
        self.helper("--write", success=False)
        self.assertEqual(original, self.base.read_bytes())
        for source in [
            'x-service: &shared {image: fixture, ports: ["5432:5432", "6543:6543"]}\nservices:\n  supavisor: *shared\n',
            'services:\n  supavisor: &shared {image: fixture, ports: ["5432:5432", "6543:6543"]}\n  other: *shared\n',
            'services:\n  supavisor: !!map &shared {image: fixture, ports: ["5432:5432", "6543:6543"]}\n  other: *shared\n',
        ]:
            self.base.write_text(source)
            original = self.base.read_bytes()
            self.helper("--write", success=False)
            self.assertEqual(original, self.base.read_bytes())
        self.base.write_text('services:\n  supavisor:\n    image: fixture\n'
                             '    ports: &shared ["5432:5432", "6543:6543"]\n'
                             '  other:\n    image: fixture\n    ports: *shared\n')
        original = self.base.read_bytes()
        self.helper("--write", success=False)
        self.assertEqual(original, self.base.read_bytes())

    def test_missing_port_or_invalid_overlay_cannot_leave_a_partial_repair(self):
        self.base_with_ports('      - "5432:5432"')
        original = self.base.read_bytes()
        self.helper("--write", success=False)
        self.assertEqual(original, self.base.read_bytes())
        self.base_with_ports('      - "5432:5432"\n      - "6543:6543"')
        original = self.base.read_bytes()
        override = self.root / "docker-compose.override.yml"
        override.write_text('services:\n  supavisor:\n    network_mode: host\n')
        original_override = override.read_bytes()
        self.helper("--write", success=False)
        self.assertEqual(original, self.base.read_bytes())
        self.assertEqual(original_override, override.read_bytes())

    def test_unsafe_yaml_constructor_is_never_executed(self):
        sentinel = self.root / "must-not-exist"
        self.base.write_text('!!python/object/apply:os.system ["touch ' + str(sentinel) + '"]\n')
        self.helper("--write", success=False)
        self.assertFalse(sentinel.exists())

    def test_custom_compose_merge_tags_fail_closed_without_rewriting_semantics(self):
        for tag in ("!override", "!reset"):
            self.base.write_text('services:\n  supavisor:\n    image: fixture\n'
                                 '    ports: ' + tag + ' ["5432:5432", "6543:6543"]\n')
            original = self.base.read_bytes()
            self.helper("--write", success=False)
            self.assertEqual(original, self.base.read_bytes())

    def test_public_studio_fails_before_any_pooler_configuration_is_written(self):
        self.base_with_ports('      - "5432:5432"\n      - "6543:6543"')
        self.base.write_text(self.base.read_text() + '  studio:\n    image: fixture\n    ports: ["3000:3000"]\n')
        original = self.base.read_bytes()
        result = self.helper("--write", success=False)
        self.assertIn("studio_requires_separate_loopback_repair", result.stderr)
        self.assertEqual(original, self.base.read_bytes())

    def test_running_bindings_allow_unpublished_image_ports_but_reject_public_or_missing_bindings(self):
        spec = importlib.util.spec_from_file_location("pooler_network", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        private = {"5432/tcp": [{"HostIp": "127.0.0.1", "HostPort": "5432"}],
                   "6543/tcp": [{"HostIp": "::1", "HostPort": "6543"}], "4000/tcp": None}
        with patch.object(module, "run_docker", return_value=private):
            module.validate_running("supavisor")
        for changed in (
            {**private, "4000/tcp": [{"HostIp": "0.0.0.0", "HostPort": "4000"}]},
            {**private, "6543/tcp": [{"HostIp": "::", "HostPort": "6543"}]},
            {**private, "5432/tcp": None},
        ):
            with patch.object(module, "run_docker", return_value=changed), self.assertRaises(module.RepairError):
                module.validate_running("supavisor")

    def test_disk_full_after_first_write_restores_existing_backups_without_allocating_again(self):
        self.base_with_ports('      - "5432:5432"\n      - "6543:6543"')
        overlay = self.root / "docker-compose.override.yml"
        overlay.write_text('services:\n  supavisor:\n    ports: ["5432:5432", "6543:6543"]\n')
        self.base.chmod(0o640)
        overlay.chmod(0o644)
        originals = {path: path.read_bytes() for path in (self.base, overlay)}
        metadata = {path: (path.stat().st_mode, path.stat().st_uid, path.stat().st_gid) for path in originals}
        spec = importlib.util.spec_from_file_location("pooler_network_fault", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        atomic_write = module.atomic_write
        writes = []

        def disk_full(path, content, mode):
            writes.append(path)
            if len(writes) > 1:
                raise OSError(errno.ENOSPC, "No space left on device")
            return atomic_write(path, content, mode)

        with patch.object(module, "atomic_write", side_effect=disk_full):
            with self.assertRaisesRegex(module.RepairError, "configuration_write_failed_originals_restored"):
                module.repair(self.root, write=True)
        self.assertEqual(len(writes), 2, "Rollback must rename backups rather than retry allocating a file")
        for path, original in originals.items():
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual((path.stat().st_mode, path.stat().st_uid, path.stat().st_gid), metadata[path])
        self.assertEqual((self.root / ".env").read_bytes(), self.env)

    def test_failed_rollback_is_reported_and_retained_backups_stay_private(self):
        self.base_with_ports('      - "5432:5432"\n      - "6543:6543"')
        overlay = self.root / "docker-compose.override.yml"
        overlay.write_text('services:\n  supavisor:\n    ports: ["5432:5432", "6543:6543"]\n')
        spec = importlib.util.spec_from_file_location("pooler_network_rollback_fault", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        atomic_write, replace = module.atomic_write, os.replace
        writes = []

        def fail_second_write(path, content, mode):
            writes.append(path)
            if len(writes) > 1:
                raise OSError(errno.ENOSPC, "No space left on device")
            return atomic_write(path, content, mode)

        def fail_rollback(source, destination):
            if ".network-backup-" in str(source):
                raise OSError(errno.EACCES, "Cannot rename backup")
            return replace(source, destination)

        with patch.object(module, "atomic_write", side_effect=fail_second_write), patch.object(module.os, "replace", side_effect=fail_rollback):
            with self.assertRaisesRegex(module.RepairError, "configuration_write_failed_rollback_incomplete_backups_retained"):
                module.repair(self.root, write=True)
        backups = list(self.root.glob("*.network-backup-*"))
        self.assertEqual(len(backups), 2)
        self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in backups))
        self.assertEqual((self.root / ".env").read_bytes(), self.env)


if __name__ == "__main__":
    unittest.main()
