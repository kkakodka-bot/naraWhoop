"""Real archive-byte checks for classic Docker and containerd image identities."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

from test_pinned_postgres_client import encoded, digest, write_tar

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/verify-worker-image.py'
SPEC = importlib.util.spec_from_file_location('verify_worker_image', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SHA = 'a' * 40


def fixture(directory, *, oci=True, manifest_id=True, role='physiology'):
    labels = {'org.opencontainers.image.revision': SHA, 'io.frwhoop.image.platform': 'linux/amd64',
              'io.frwhoop.database.ca.sha256': '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7',
              'io.frwhoop.heartbeat.contract': 'physiology_worker_heartbeats-v1',
              'io.frwhoop.algorithm.roles': 'frwhoop-physiology-2,frwhoop-server-2-history',
              'io.frwhoop.algorithm.version': 'frwhoop-server-1',
              'org.frwhoop.worker.role': 'intake', 'org.frwhoop.intake.contract-version': '1'}
    config_bytes = encoded({'architecture': 'amd64', 'os': 'linux', 'config': {'Labels': labels}})
    config_digest = digest(config_bytes)
    manifest_bytes = encoded({'schemaVersion': 2, 'config': {'digest': config_digest,
                              'size': len(config_bytes)}, 'layers': []})
    manifest_digest = digest(manifest_bytes)
    reference = 'fixture.invalid/worker@' + manifest_digest
    descriptor = {'digest': manifest_digest, 'size': len(manifest_bytes)}
    if oci:
        entries = {'oci-layout': encoded({'imageLayoutVersion': '1.0.0'}),
                   'index.json': encoded({'manifests': [descriptor]}),
                   'blobs/sha256/' + manifest_digest[7:]: manifest_bytes,
                   'blobs/sha256/' + config_digest[7:]: config_bytes}
    else:
        entries = {'manifest.json': encoded([{'Config': config_digest[7:] + '.json', 'Layers': []}]),
                   config_digest[7:] + '.json': config_bytes}
    archive = Path(directory) / 'image.tar'
    write_tar(archive, entries)
    inspection = [{'Id': manifest_digest if manifest_id else config_digest, 'RepoDigests': [reference],
                   'Os': 'linux', 'Architecture': 'amd64'}]
    if manifest_id:
        inspection[0]['Descriptor'] = descriptor
    return archive, inspection, reference, config_digest, SHA, role


class WorkerImageTest(unittest.TestCase):
    def test_exact_config_bytes_bind_classic_and_containerd_ids_for_all_roles(self):
        with tempfile.TemporaryDirectory() as directory:
            for oci, manifest_id in ((False, False), (True, False), (True, True)):
                for role in ('baseline', 'physiology', 'intake'):
                    with self.subTest(oci=oci, manifest_id=manifest_id, role=role):
                        args = fixture(directory, oci=oci, manifest_id=manifest_id, role=role)
                        receipt = MODULE.verify_worker_archive(*args)
                        self.assertEqual(receipt['engineImageId'], args[1][0]['Id'])
                        self.assertEqual(receipt['configDigest'], args[3])

    def test_manifest_id_is_not_a_substitute_for_reviewed_config_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            args = list(fixture(directory))
            args[3] = 'sha256:' + 'b' * 64
            with self.assertRaisesRegex(ValueError, 'config descriptor'):
                MODULE.verify_worker_archive(*args)

    def test_wrong_scope_role_platform_reference_and_descriptor_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            original = fixture(directory)
            mutations = [
                (lambda a: a[1][0].update(Id='sha256:' + 'b' * 64), 'image ID'),
                (lambda a: a[1][0].update(RepoDigests=[]), 'repository digest'),
                (lambda a: a[1][0].update(Architecture='arm64'), 'platform'),
                (lambda a: a[1][0].update(Descriptor={'digest': 'sha256:' + 'b' * 64}), 'descriptor'),
                (lambda a: a.__setitem__(4, 'b' * 40), 'source revision'),
                (lambda a: a.__setitem__(5, 'unknown'), 'role'),
                (lambda a: a.__setitem__(2, 'fixture.invalid/worker:latest'), 'immutable'),
            ]
            for mutate, reason in mutations:
                with self.subTest(reason=reason):
                    args = copy.deepcopy(list(original))
                    mutate(args)
                    with self.assertRaisesRegex(ValueError, reason):
                        MODULE.verify_worker_archive(*args)

    def test_rewritten_archive_config_with_unchanged_descriptor_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            args = fixture(directory)
            import tarfile
            with tarfile.open(args[0]) as archive:
                entries = {member.name: archive.extractfile(member).read() for member in archive.getmembers()}
            config_path = 'blobs/sha256/' + args[3][7:]
            modified = json.loads(entries[config_path])
            modified['config']['Labels']['org.opencontainers.image.revision'] = 'b' * 40
            entries[config_path] = encoded(modified)
            write_tar(args[0], entries)
            with self.assertRaisesRegex(ValueError, 'descriptor digest'):
                MODULE.verify_worker_archive(*args)
