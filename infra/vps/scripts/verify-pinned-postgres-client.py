#!/usr/bin/env python3
"""Verify a saved Docker/OCI archive for the release-pinned PostgreSQL client."""

import argparse
import hashlib
import json
import os
from pathlib import PurePosixPath
import re
import tarfile


APPROVED_REFERENCE = 'docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3'
APPROVED_MANIFEST_DIGEST = 'sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3'
APPROVED_CONFIG_DIGEST = 'sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537'
APPROVED_PLATFORM = 'linux/amd64'
APPROVED_VERSION = '17.11-alpine3.24'
MAX_JSON_BYTES = 16 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def safe_members(archive):
    members = {}
    for member in archive.getmembers():
        name = member.name.removeprefix('./')
        path = PurePosixPath(name)
        require(name and not path.is_absolute() and '..' not in path.parts and '.' not in path.parts,
                'unsafe archive member path')
        require(name not in members, 'duplicate archive member')
        require(member.isfile() or member.isdir(), 'archive links and special files are forbidden')
        members[name] = member
    return members


def read_member(archive, members, name):
    member = members.get(name)
    require(member is not None and member.isfile() and 0 <= member.size <= MAX_JSON_BYTES,
            f'missing or excessive archive member: {name}')
    stream = archive.extractfile(member)
    require(stream is not None, f'unreadable archive member: {name}')
    data = stream.read(MAX_JSON_BYTES + 1)
    require(len(data) == member.size and len(data) <= MAX_JSON_BYTES, f'invalid archive member: {name}')
    return data


def json_member(archive, members, name):
    try:
        return json.loads(read_member(archive, members, name))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f'invalid JSON archive member: {name}') from error


def verify_config(config_bytes, expected_config, platform):
    require(digest(config_bytes) == expected_config, 'PostgreSQL client config digest differs')
    try:
        config = json.loads(config_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError('PostgreSQL client config is invalid JSON') from error
    os_name, architecture = platform.split('/', 1)
    require(config.get('os') == os_name and config.get('architecture') == architecture,
            'PostgreSQL client platform differs')


def verify_docker_archive(archive, members, expected_config, platform):
    manifest = json_member(archive, members, 'manifest.json')
    require(isinstance(manifest, list) and len(manifest) == 1 and isinstance(manifest[0], dict),
            'Docker archive must contain exactly one image')
    config_name = manifest[0].get('Config')
    require(isinstance(config_name, str) and re.fullmatch(r'(?:blobs/sha256/)?[0-9a-f]{64}(?:\.json)?', config_name),
            'Docker archive config descriptor is invalid')
    config_bytes = read_member(archive, members, config_name)
    verify_config(config_bytes, expected_config, platform)


def descriptor_blob(archive, members, descriptor, label):
    require(isinstance(descriptor, dict) and re.fullmatch(r'sha256:[0-9a-f]{64}', descriptor.get('digest', '')),
            f'{label} descriptor is invalid')
    data = read_member(archive, members, 'blobs/sha256/' + descriptor['digest'].removeprefix('sha256:'))
    require(digest(data) == descriptor['digest'], f'{label} descriptor digest differs')
    require(descriptor.get('size') == len(data), f'{label} descriptor size differs')
    return data


def verify_oci_archive(archive, members, manifest_digest, expected_config, platform):
    index = json_member(archive, members, 'index.json')
    descriptors = index.get('manifests') if isinstance(index, dict) else None
    require(isinstance(descriptors, list), 'OCI index manifests are invalid')
    matches = [item for item in descriptors if isinstance(item, dict) and item.get('digest') == manifest_digest]
    require(len(matches) == 1, 'OCI index does not bind the reviewed manifest digest exactly once')
    descriptor = matches[0]
    os_name, architecture = platform.split('/', 1)
    descriptor_platform = descriptor.get('platform')
    require(descriptor_platform is None or descriptor_platform == {'architecture': architecture, 'os': os_name},
            'OCI manifest platform descriptor differs')
    manifest_bytes = descriptor_blob(archive, members, descriptor, 'OCI manifest')
    try:
        manifest = json.loads(manifest_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError('OCI manifest is invalid JSON') from error
    config_descriptor = manifest.get('config') if isinstance(manifest, dict) else None
    require(isinstance(config_descriptor, dict) and config_descriptor.get('digest') == expected_config,
            'OCI config descriptor differs')
    config_bytes = descriptor_blob(archive, members, config_descriptor, 'OCI config')
    verify_config(config_bytes, expected_config, platform)


def verify_saved_archive(filename, manifest_digest, expected_config, platform):
    require(os.path.isfile(filename) and not os.path.islink(filename), 'saved image archive must be a regular file')
    with tarfile.open(filename, mode='r:*') as archive:
        members = safe_members(archive)
        if 'oci-layout' in members or 'index.json' in members:
            require('oci-layout' in members and 'index.json' in members, 'incomplete OCI archive')
            verify_oci_archive(archive, members, manifest_digest, expected_config, platform)
        else:
            verify_docker_archive(archive, members, expected_config, platform)


def verify_archive(filename, reference, expected_config, platform, version):
    require(reference == APPROVED_REFERENCE, 'PostgreSQL client reference is not the reviewed release identity')
    require(expected_config == APPROVED_CONFIG_DIGEST, 'PostgreSQL client expected config is not reviewed')
    require(platform == APPROVED_PLATFORM, 'PostgreSQL client expected platform is not reviewed')
    require(version == APPROVED_VERSION, 'PostgreSQL client version label is not reviewed')
    verify_saved_archive(filename, APPROVED_MANIFEST_DIGEST, expected_config, platform)
    return {
        'status': 'POSTGRES_CLIENT_ARCHIVE_VERIFIED',
        'reference': reference,
        'configDigest': expected_config,
        'platform': platform,
        'version': version,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', required=True)
    parser.add_argument('--reference', required=True)
    parser.add_argument('--config-digest', required=True)
    parser.add_argument('--platform', required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    result = verify_archive(args.archive, args.reference, args.config_digest, args.platform, args.version)
    print(json.dumps(result, sort_keys=True, separators=(',', ':')))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'NOT_READY: {error}', file=os.sys.stderr)
        raise SystemExit(3)
