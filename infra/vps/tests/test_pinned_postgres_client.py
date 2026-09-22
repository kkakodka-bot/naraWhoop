import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/verify-pinned-postgres-client.py'
SPEC = importlib.util.spec_from_file_location('verify_pinned_postgres_client', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def digest(value):
    return 'sha256:' + hashlib.sha256(value).hexdigest()


def write_tar(filename, entries):
    with tarfile.open(filename, 'w') as archive:
        for name, data in entries.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))


def fixture(directory, oci, containerd_shape=False):
    config = encoded({'architecture': 'amd64', 'os': 'linux', 'config': {'Env': ['PG_MAJOR=17']}})
    config_digest = digest(config)
    if oci:
        manifest = encoded({'schemaVersion': 2, 'config': {
            'mediaType': 'application/vnd.oci.image.config.v1+json',
            'digest': config_digest,
            'size': len(config),
        }, 'layers': []})
        manifest_digest = digest(manifest)
        image_descriptor = {
            'mediaType': 'application/vnd.oci.image.manifest.v1+json',
            'digest': manifest_digest,
            'size': len(manifest),
        }
        if not containerd_shape:
            image_descriptor['platform'] = {'architecture': 'amd64', 'os': 'linux'}
        descriptors = [image_descriptor]
        entries = {
            'oci-layout': encoded({'imageLayoutVersion': '1.0.0'}),
            'blobs/sha256/' + manifest_digest.removeprefix('sha256:'): manifest,
            'blobs/sha256/' + config_digest.removeprefix('sha256:'): config,
        }
        if containerd_shape:
            attestation = encoded({'schemaVersion': 2, 'config': {'digest': config_digest, 'size': len(config)}})
            attestation_digest = digest(attestation)
            entries['blobs/sha256/' + attestation_digest.removeprefix('sha256:')] = attestation
            descriptors.append({'mediaType': 'application/vnd.oci.image.manifest.v1+json',
                                'digest': attestation_digest, 'size': len(attestation),
                                'platform': {'architecture': 'unknown', 'os': 'unknown'}})
        entries['index.json'] = encoded({'schemaVersion': 2, 'manifests': descriptors})
    else:
        config_name = config_digest.removeprefix('sha256:') + '.json'
        entries = {
            'manifest.json': encoded([{'Config': config_name, 'RepoTags': None, 'Layers': []}]),
            config_name: config,
        }
        manifest_digest = 'sha256:' + '1' * 64
    filename = Path(directory) / ('oci.tar' if oci else 'docker.tar')
    write_tar(filename, entries)
    return filename, manifest_digest, config_digest


class PinnedPostgresClientArchiveTest(unittest.TestCase):
    def test_classic_and_containerd_style_archives_bind_config_and_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            for oci, containerd_shape in ((False, False), (True, False), (True, True)):
                archive, manifest, config = fixture(directory, oci, containerd_shape)
                MODULE.verify_saved_archive(archive, manifest, config, 'linux/amd64')

    def test_wrong_reference_config_and_platform_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, manifest, config = fixture(directory, True)
            with self.assertRaisesRegex(ValueError, 'manifest digest'):
                MODULE.verify_saved_archive(archive, 'sha256:' + '2' * 64, config, 'linux/amd64')
            with self.assertRaisesRegex(ValueError, 'config descriptor'):
                MODULE.verify_saved_archive(archive, manifest, 'sha256:' + '3' * 64, 'linux/amd64')
            with self.assertRaisesRegex(ValueError, 'platform'):
                MODULE.verify_saved_archive(archive, manifest, config, 'linux/arm64')
            with self.assertRaisesRegex(ValueError, 'reference is not'):
                MODULE.verify_archive(archive, 'docker.io/library/postgres:17-alpine',
                                      MODULE.APPROVED_CONFIG_DIGEST, MODULE.APPROVED_PLATFORM,
                                      MODULE.APPROVED_VERSION)

    def test_links_and_duplicate_members_are_rejected_before_descriptor_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'unsafe.tar'
            with tarfile.open(archive, 'w') as value:
                link = tarfile.TarInfo('manifest.json')
                link.type = tarfile.SYMTYPE
                link.linkname = '../outside'
                value.addfile(link)
            with self.assertRaisesRegex(ValueError, 'links and special files'):
                MODULE.verify_saved_archive(archive, 'sha256:' + '1' * 64,
                                            'sha256:' + '2' * 64, 'linux/amd64')


if __name__ == '__main__':
    unittest.main()
