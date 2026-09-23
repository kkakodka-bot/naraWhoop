#!/usr/bin/env python3
"""Transfer and verify a private, plan-bound worker scope without emitting identities."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

UUID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}')
SHA = re.compile(r'[0-9a-f]{64}')


def require(condition):
    if not condition:
        raise ValueError('private worker admission binding differs')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def fingerprint(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def private_json(filename):
    fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(fd)
        require(stat.S_ISREG(metadata.st_mode) and not metadata.st_mode & 0o077
                and metadata.st_uid == os.getuid() and 0 < metadata.st_size <= 1024 * 1024)
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            return json.load(stream)
    finally:
        os.close(fd)


def admission(value, scope, expected):
    require(isinstance(value, dict) and isinstance(expected, str) and SHA.fullmatch(expected))
    if scope == 'initial-selected-v1':
        require(set(value) == {'mode', 'ownerId', 'deviceId'} and value['mode'] == 'canary')
        require(all(isinstance(value[k], str) and UUID.fullmatch(value[k]) for k in ('ownerId', 'deviceId')))
    else:
        require(scope == 'full-fleet' and value == {'mode': 'all-eligible'})
    require(fingerprint(value) == expected)
    return value


def environment(value):
    result = {'SCORING_ADMISSION_MODE': value['mode']}
    if value['mode'] == 'canary':
        result.update(SCORING_CANARY_OWNER_ID=value['ownerId'], SCORING_CANARY_DEVICE_ID=value['deviceId'])
    return result


def validate_plan(plan, expected_plan, expected_admission):
    require(plan.get('deploymentFingerprintSha256') == expected_plan)
    require(fingerprint({k: v for k, v in plan.items() if k != 'deploymentFingerprintSha256'}) == expected_plan)
    value = admission(plan.get('admission'), plan.get('scope'), expected_admission)
    require(plan.get('admissionSha256') == expected_admission and plan.get('baselineEnvironment') == environment(value))
    return value


def write_private(output, value):
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(canonical(value) + b'\n'); stream.flush(); os.fsync(stream.fileno())


def extract_plan(plan, expected_plan, expected_admission, output, plan_output=None):
    value = validate_plan(plan, expected_plan, expected_admission)
    write_private(output, value)
    if plan_output is not None: write_private(plan_output, plan)


def export_intake(plan, expected_plan, expected_admission, output):
    value = validate_plan(plan, expected_plan, expected_admission)
    require(value['mode'] == 'canary' and plan['intake']['contractVersion'] == 2)
    compiled = plan['intake']['compiledCompose']
    require(fingerprint(compiled) == plan['intake']['compiledComposeSha256'])
    service = compiled['services']['intake-consumer']
    require(service['restart'] == 'no' and service['image'] == plan['images']['intake']['reference'])
    write_private(output, compiled)


def verify_intake(plan, expected_plan, expected_admission):
    validate_plan(plan, expected_plan, expected_admission)
    expected = plan['intake']['compiledCompose']['services']['intake-consumer']['environment']
    observed = container_environment('intake-consumer', set(expected))
    require(observed == expected)


def append_environment(value, filename):
    fd = os.open(filename, os.O_RDWR | os.O_NOFOLLOW)
    with os.fdopen(fd, 'r+') as stream:
        metadata = os.fstat(stream.fileno())
        require(stat.S_ISREG(metadata.st_mode) and not metadata.st_mode & 0o077
                and metadata.st_uid == os.getuid() and metadata.st_size <= 1024 * 1024)
        existing = stream.read()
        require(not any(line.startswith(('SCORING_ADMISSION_MODE=', 'SCORING_CANARY_OWNER_ID=',
                                          'SCORING_CANARY_DEVICE_ID=')) for line in existing.splitlines()))
        require(not existing or existing.endswith('\n'))
        stream.write(''.join(key + '=' + val + '\n' for key, val in environment(value).items()))
        stream.flush(); os.fsync(stream.fileno())


def container_environment(container, keys):
    require(bool(re.fullmatch(r'scoring-(baseline-v1|physiology-v2|history)|intake-consumer', container)))
    raw = subprocess.run(['docker', 'inspect', '-f', '{{json .Config.Env}}', container],
                         check=True, capture_output=True, timeout=12).stdout
    require(len(raw) <= 1024 * 1024)
    entries = json.loads(raw)
    require(isinstance(entries, list) and all(isinstance(entry, str) for entry in entries))
    observed = {}
    for entry in entries:
        key, separator, val = entry.partition('=')
        if key in keys:
            require(separator and key not in observed)
            observed[key] = val
    return observed


def verify_container(value, container):
    keys = {'SCORING_ADMISSION_MODE', 'SCORING_CANARY_OWNER_ID', 'SCORING_CANARY_DEVICE_ID'}
    require(container_environment(container, keys) == environment(value))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('extract-plan', 'export-intake', 'verify-intake', 'append-env', 'verify-container', 'validate'))
    parser.add_argument('--input', required=True)
    parser.add_argument('--admission-sha256', required=True)
    parser.add_argument('--scope')
    parser.add_argument('--plan-fingerprint')
    parser.add_argument('--output')
    parser.add_argument('--plan-output')
    parser.add_argument('--container')
    args = parser.parse_args()
    value = private_json(args.input)
    if args.action == 'extract-plan':
        extract_plan(value, args.plan_fingerprint, args.admission_sha256, args.output, args.plan_output)
    elif args.action == 'export-intake':
        export_intake(value, args.plan_fingerprint, args.admission_sha256, args.output)
    elif args.action == 'verify-intake':
        verify_intake(value, args.plan_fingerprint, args.admission_sha256)
    else:
        value = admission(value, args.scope, args.admission_sha256)
        if args.action == 'append-env': append_environment(value, args.output)
        elif args.action == 'verify-container': verify_container(value, args.container)
    # No owner/device, plan contents, environment or docker diagnostics reach stdout/stderr.
    print(json.dumps({'status': 'WORKER_ADMISSION_VERIFIED', 'admissionSha256': args.admission_sha256}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('NOT_READY: private worker admission validation failed', file=sys.stderr)
        raise SystemExit(3)
