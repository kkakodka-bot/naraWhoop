#!/usr/bin/env python3
"""Bind a pulled immutable worker reference and config bytes to Docker's local ID.

Classic Docker uses the config digest as .Id; containerd-backed stores may use the
manifest digest. Neither is accepted as proof of the other. Always hash a saved
archive's actual config bytes before returning the ID used by container .Image.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


spec = importlib.util.spec_from_file_location(
    'saved_image', Path(__file__).with_name('verify-pinned-postgres-client.py'))
saved_image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(saved_image)
require = saved_image.require
DIGEST = re.compile(r'sha256:[0-9a-f]{64}')
REFERENCE = re.compile(r'[a-z0-9][a-z0-9._:-]*(?:/[a-z0-9][a-z0-9._-]*)+@sha256:[0-9a-f]{64}')


def verify_worker_archive(archive, inspection, reference, config_digest, source_revision, role):
    require(REFERENCE.fullmatch(reference), 'worker reference must be immutable')
    require(DIGEST.fullmatch(config_digest), 'worker config digest is invalid')
    require(re.fullmatch(r'[0-9a-f]{40}', source_revision), 'worker source revision is invalid')
    require(role in ('baseline', 'physiology', 'intake'), 'worker role is invalid')
    require(isinstance(inspection, list) and len(inspection) == 1 and isinstance(inspection[0], dict),
            'worker image inspection is ambiguous')
    image = inspection[0]
    manifest_digest = reference.rsplit('@', 1)[1]
    require(reference in (image.get('RepoDigests') or []), 'worker repository digest differs')
    require(image.get('Os') == 'linux' and image.get('Architecture') == 'amd64', 'worker platform differs')
    local_id = image.get('Id')
    require(local_id in (config_digest, manifest_digest), 'worker engine image ID differs')
    descriptor = image.get('Descriptor')
    if descriptor is not None:
        require(isinstance(descriptor, dict) and descriptor.get('digest') == manifest_digest,
                'worker engine manifest descriptor differs')
    config = saved_image.verify_saved_archive(archive, manifest_digest, config_digest, 'linux/amd64')
    labels = (config.get('config') or {}).get('Labels') or {}
    require(labels.get('org.opencontainers.image.revision') == source_revision, 'worker source revision differs')
    require(labels.get('io.frwhoop.image.platform') == 'linux/amd64', 'worker platform label differs')
    if role == 'intake':
        require(labels.get('org.frwhoop.worker.role') == 'intake' and
                labels.get('org.frwhoop.intake.contract-version') == '2', 'intake role or contract differs')
    else:
        require(labels.get('io.frwhoop.database.ca.sha256') ==
                '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7',
                'worker database trust label differs')
        require(labels.get('io.frwhoop.heartbeat.contract') == 'physiology_worker_heartbeats-v1',
                'worker heartbeat contract differs')
        if role == 'baseline':
            require(labels.get('io.frwhoop.algorithm.version') == 'frwhoop-server-1', 'baseline algorithm differs')
        else:
            require(labels.get('io.frwhoop.algorithm.roles') == 'frwhoop-physiology-2,frwhoop-server-2-history',
                    'physiology algorithm roles differ')
    return {'status': 'WORKER_IMAGE_ARCHIVE_VERIFIED', 'reference': reference,
            'manifestDigest': manifest_digest, 'configDigest': config_digest, 'engineImageId': local_id,
            'sourceRevision': source_revision, 'platform': 'linux/amd64', 'role': role}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reference', required=True)
    parser.add_argument('--config-digest', required=True)
    parser.add_argument('--source-revision', required=True)
    parser.add_argument('--role', choices=('baseline', 'physiology', 'intake'), required=True)
    parser.add_argument('--output', choices=('json', 'image-id'), default='json')
    args = parser.parse_args()
    # Check external arguments before invoking Docker. No pull or container mutation occurs here.
    require(REFERENCE.fullmatch(args.reference), 'worker reference must be immutable')
    require(DIGEST.fullmatch(args.config_digest), 'worker config digest is invalid')
    require(re.fullmatch(r'[0-9a-f]{40}', args.source_revision), 'worker source revision is invalid')
    try:
        inspection = json.loads(subprocess.run(['docker', 'image', 'inspect', args.reference],
            check=True, capture_output=True, timeout=30).stdout)
        with tempfile.TemporaryDirectory(prefix='frwhoop-worker-image-') as directory:
            archive = str(Path(directory) / 'image.tar')
            subprocess.run(['docker', 'image', 'save', '-o', archive, args.reference],
                           check=True, capture_output=True, timeout=300)
            result = verify_worker_archive(archive, inspection, args.reference, args.config_digest,
                                           args.source_revision, args.role)
    except (subprocess.SubprocessError, json.JSONDecodeError) as error:
        raise ValueError('worker image inspection or archive export failed') from error
    print(result['engineImageId'] if args.output == 'image-id' else json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'NOT_READY: {error}', file=sys.stderr)
        raise SystemExit(3)
