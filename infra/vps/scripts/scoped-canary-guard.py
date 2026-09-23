#!/usr/bin/env python3
"""Fail-closed supervisor for two explicitly bound canary containers.

This is an approved-deployment operation, never a capacity benchmark. A private
binding pins exact container IDs, image config hashes, source, worker instance,
admission and policy bytes. It never stops a container by a reusable name.
Run under a host supervisor with ExecStopPost invoking this script's stop action
so a killed guard also stops its bound canary. No restart, database mutation,
queue deletion, registry operation or phone action is performed.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time

SHA = re.compile(r'[0-9a-f]{64}')
SOURCE = re.compile(r'[0-9a-f]{40}')
LANES = {'verification', 'projection', 'legacy'}


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


class admission:
    """Minimal stdlib-only stop binding reader; cleanup imports no deployed helper."""
    UUID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}')

    @staticmethod
    def canonical(value):
        return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()

    @staticmethod
    def fingerprint(value):
        return hashlib.sha256(admission.canonical(value)).hexdigest()

    @staticmethod
    def private_json(filename):
        fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            metadata = os.fstat(fd)
            require(stat.S_ISREG(metadata.st_mode) and not metadata.st_mode & 0o077
                    and metadata.st_uid == os.getuid() and 0 < metadata.st_size <= 1024 * 1024, 'invalid_private_binding')
            with os.fdopen(fd, 'rb', closefd=False) as stream:
                return json.load(stream)
        finally:
            os.close(fd)

    @staticmethod
    def admission(value, scope, expected):
        require(scope == 'initial-selected-v1' and isinstance(value, dict)
                and set(value) == {'mode', 'ownerId', 'deviceId'} and value['mode'] == 'canary', 'invalid_admission')
        require(all(isinstance(value[k], str) and admission.UUID.fullmatch(value[k]) for k in ('ownerId', 'deviceId')), 'invalid_admission')
        require(isinstance(expected, str) and SHA.fullmatch(expected)
                and admission.fingerprint(value) == expected, 'admission_changed')


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def age(value, now):
    require(isinstance(value, str), 'observation_missing_time')
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(parsed.tzinfo is not None, 'observation_missing_timezone')
    result = now - parsed.timestamp()
    require(result >= -5, 'observation_future_time')
    return result


def command(arguments, timeout=15):
    # Capture all diagnostics; subprocess errors may contain private environment.
    result = subprocess.run(arguments, capture_output=True, timeout=timeout, check=True)
    require(len(result.stdout) <= 1024 * 1024, 'observation_too_large')
    return result.stdout


def inspect(container, timeout=15):
    result = json.loads(command(['docker', 'inspect', container], timeout))
    require(isinstance(result, list) and len(result) == 1, 'container_missing')
    return result[0]


def verify_container(observed, bound, binding, running=True, stopping=False):
    require(observed.get('Id') == bound['id'] and observed.get('Image') == bound['image'], 'container_identity_changed')
    # An exact-ID container with altered scope or limits is precisely what must stop.
    if stopping:
        return
    require(observed.get('Config', {}).get('Labels', {}).get('org.opencontainers.image.revision') == binding['sourceRevision'], 'container_source_changed')
    for field in ('Entrypoint', 'Cmd', 'User', 'WorkingDir'):
        actual = observed.get('Config', {}).get(field)
        if field == 'Cmd':
            actual = actual or []
        require(actual == bound['command'][field], 'container_command_changed')
    env = {}
    prefix = 'INTAKE_' if bound['role'] == 'intake' else 'SCORING_'
    expected = {prefix + 'ADMISSION_MODE': 'canary',
                prefix + 'CANARY_OWNER_ID': binding['admission']['ownerId'],
                prefix + 'CANARY_DEVICE_ID': binding['admission']['deviceId'],
                prefix + 'WORKER_SOURCE_REVISION': binding['sourceRevision'],
                prefix + 'WORKER_INSTANCE_ID': bound['instanceId']}
    for entry in observed.get('Config', {}).get('Env', []):
        key, separator, value = entry.partition('=')
        if key in expected:
            require(separator and key not in env, 'container_environment_ambiguous')
            env[key] = value
    require(env == expected, 'container_scope_changed')
    config = observed.get('HostConfig', {})
    require(config.get('RestartPolicy', {}).get('Name') == 'no', 'container_restart_policy_changed')
    expected_memory = 2 * 1024 ** 3 if bound['role'] == 'intake' else 1024 ** 3
    if not stopping:
        require(config.get('Memory') == expected_memory and config.get('NanoCpus') == 1_000_000_000, 'container_limits_changed')
    if running:
        state = observed.get('State', {})
        require(state.get('Running') is True and state.get('OOMKilled') is False
                and state.get('Restarting') is False, 'container_not_running')
        require(observed.get('RestartCount') == bound['restartCount'], 'container_restarted')


def load_plan(filename):
    plan = admission.private_json(filename)
    require(plan.get('kind') == 'frwhoop-worker-deployment' and plan.get('scope') == 'initial-selected-v1', 'invalid_deployment_plan')
    require(admission.fingerprint({k: v for k, v in plan.items() if k != 'deploymentFingerprintSha256'}) == plan.get('deploymentFingerprintSha256'), 'deployment_plan_changed')
    admission.admission(plan.get('admission'), 'initial-selected-v1', plan.get('admissionSha256'))
    require(SOURCE.fullmatch(plan.get('source', {}).get('commit', '')), 'invalid_deployment_source')
    return plan


def verify_installed(plan, policy_path):
    contract = plan.get('canaryGuard')
    require(isinstance(contract, dict), 'guard_source_contract_missing')
    paths = [('policy', Path(policy_path)), ('helper', Path(__file__)),
             ('service', Path(__file__).with_name('frwhoop-scoped-canary.service'))]
    for key, path in paths:
        identity = contract.get(key, {})
        content = path.read_bytes()
        require(hashlib.sha256(content).hexdigest() == identity.get('sha256')
                and len(content) == identity.get('sizeBytes'), 'installed_guard_changed')
    dependencies = contract.get('dependencies')
    expected = {'scoring-admission.py', 'verify-worker-image.py', 'verify-pinned-postgres-client.py'}
    require(isinstance(dependencies, list) and len(dependencies) == len(expected)
            and {Path(x.get('path', '')).name for x in dependencies} == expected, 'guard_dependencies_missing')
    for identity in dependencies:
        content = Path(__file__).with_name(Path(identity['path']).name).read_bytes()
        require(hashlib.sha256(content).hexdigest() == identity.get('sha256')
                and len(content) == identity.get('sizeBytes'), 'guard_dependency_changed')


def bind_containers(args):
    plan = load_plan(args.plan)
    verify_installed(plan, args.policy)
    binding = {'schemaVersion': 1, 'sourceRevision': plan['source']['commit'],
               'deploymentFingerprintSha256': plan['deploymentFingerprintSha256'],
               'admission': plan['admission'], 'admissionSha256': plan['admissionSha256'],
               'policySha256': hashlib.sha256(Path(args.policy).read_bytes()).hexdigest(), 'containers': []}
    for role, identifier in [('intake', args.intake_container), ('baseline', args.baseline_container)]:
        require(isinstance(identifier, str) and SHA.fullmatch(identifier), 'invalid_container_id')
        image = plan['images']['intake' if role == 'intake' else 'selectedV1']
        verified = json.loads(command([sys.executable, str(Path(__file__).with_name('verify-worker-image.py')),
            '--reference', image['reference'], '--config-digest', image['configDigest'],
            '--source-revision', binding['sourceRevision'], '--role', role], timeout=360))
        require(verified.get('status') == 'WORKER_IMAGE_ARCHIVE_VERIFIED' and verified.get('configDigest') == image['configDigest'], 'worker_archive_not_verified')
        image_inspect = json.loads(command(['docker', 'image', 'inspect', verified['engineImageId']]))[0]
        expected_command = {key: image_inspect['Config'].get(key) for key in ('Entrypoint', 'Cmd', 'User', 'WorkingDir')}
        # Empty [] and null both mean no arguments; Compose intentionally emits [].
        expected_command['Cmd'] = expected_command['Cmd'] or []
        observed = inspect(identifier)
        prefix = 'INTAKE_' if role == 'intake' else 'SCORING_'
        instances = [entry.split('=', 1)[1] for entry in observed.get('Config', {}).get('Env', [])
                     if entry.startswith(prefix + 'WORKER_INSTANCE_ID=')]
        require(len(instances) == 1 and admission.UUID.fullmatch(instances[0]), 'worker_instance_missing')
        bound = {'role': role, 'id': identifier, 'image': verified['engineImageId'], 'configDigest': image['configDigest'],
                 'command': expected_command, 'instanceId': instances[0], 'restartCount': observed.get('RestartCount')}
        verify_container(observed, bound, binding, running=False)
        require(observed.get('State', {}).get('Running') is False, 'guard_requires_stopped_containers')
        if role == 'intake':
            require(instances[0] == plan['intake']['instanceId'], 'intake_instance_changed')
        binding['containers'].append(bound)
    require(len({v['id'] for v in binding['containers']}) == 2, 'duplicate_container_binding')
    fd = os.open(args.binding, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(admission.canonical(binding) + b'\n'); stream.flush(); os.fsync(stream.fileno())


def load_binding(filename, policy_path, plan_path, stopping=False):
    binding = admission.private_json(filename)
    plan = load_plan(plan_path)
    if not stopping:
        verify_installed(plan, policy_path)
    require(binding.get('deploymentFingerprintSha256') == plan['deploymentFingerprintSha256']
            and binding.get('sourceRevision') == plan['source']['commit']
            and binding.get('admission') == plan['admission'] and binding.get('admissionSha256') == plan['admissionSha256'], 'binding_plan_changed')
    require(binding.get('schemaVersion') == 1 and SOURCE.fullmatch(binding.get('sourceRevision', '')), 'invalid_binding')
    admission.admission(binding.get('admission'), 'initial-selected-v1', binding.get('admissionSha256'))
    require(binding['policySha256'] == plan.get('canaryGuard', {}).get('policy', {}).get('sha256'), 'plan_policy_changed')
    # Emergency cleanup is limited to the private, plan-bound immutable IDs.
    # A changed policy or dependency file must not disable that stop operation.
    policy = {'stopTimeoutSeconds': 10}
    if not stopping:
        policy_bytes = Path(policy_path).read_bytes()
        require(hashlib.sha256(policy_bytes).hexdigest() == binding.get('policySha256'), 'policy_changed')
        policy = json.loads(policy_bytes)
        require(policy.get('schemaVersion') == 1 and policy.get('scope') == 'one-owner-one-device', 'invalid_policy')
        for key in ('pollSeconds', 'startupGraceSeconds', 'maximumObservationAgeSeconds', 'maximumLaneAgeSeconds',
                    'maximumPendingPerQueue', 'maximumDebtStallSeconds', 'maximumContainerMemoryPercent',
                    'maximumDatabaseConnectionPercent', 'minimumHostAvailableMemoryBytes',
                    'minimumHostFreeDiskBytes', 'stopTimeoutSeconds'):
            require(number(policy.get(key)) and policy[key] > 0, 'invalid_policy_threshold')
    containers = binding.get('containers')
    require(isinstance(containers, list) and len(containers) == 2
            and {v.get('role') for v in containers} == {'intake', 'baseline'}, 'invalid_container_binding')
    require(len({v.get('id') for v in containers}) == 2, 'duplicate_container_binding')
    for bound in containers:
        require(SHA.fullmatch(bound.get('id', '')) and re.fullmatch(r'sha256:[0-9a-f]{64}', bound.get('image', ''))
                and admission.UUID.fullmatch(bound.get('instanceId', ''))
                and type(bound.get('restartCount')) is int and bound['restartCount'] >= 0, 'invalid_container_binding')
        expected = plan['images']['intake' if bound['role'] == 'intake' else 'selectedV1']
        require(bound.get('configDigest') == expected['configDigest']
                and bound['image'] in (expected['configDigest'], expected['manifestDigest']), 'binding_image_changed')
        require(isinstance(bound.get('command'), dict) and set(bound['command']) == {'Entrypoint', 'Cmd', 'User', 'WorkingDir'}, 'binding_command_missing')
        if bound['role'] == 'intake':
            require(bound['instanceId'] == plan['intake']['instanceId'], 'binding_instance_changed')
    return binding, policy


class Evaluator:
    def __init__(self, policy, started):
        self.policy = policy
        self.started = started
        self.progress = {}

    def evaluate(self, status, resources, binding, now, monotonic):
        p = self.policy
        require(age(status.get('captured_at'), now) <= p['maximumObservationAgeSeconds'], 'status_stale')
        intake = next(v for v in binding['containers'] if v['role'] == 'intake')
        require(status.get('source_revision') == binding['sourceRevision']
                and status.get('instance_id') == intake['instanceId']
                and status.get('contract_version') == 2 and status.get('admission_mode') == 'canary'
                and status.get('owner_cap') == 1 and status.get('device_cap') == 1, 'status_scope_changed')
        startup = monotonic - self.started < p['startupGraceSeconds']
        lanes = status.get('lanes')
        require(isinstance(lanes, list) and len(lanes) <= 3, 'lanes_invalid')
        require(len({v.get('lane') for v in lanes}) == len(lanes), 'lanes_duplicated')
        if not startup:
            require({v.get('lane') for v in lanes} == LANES, 'lane_evidence_missing')
        for lane in lanes:
            require(lane.get('lane') in LANES and lane.get('last_poll_failed') is False, 'lane_failed')
            require(age(lane.get('last_successful_poll_at'), now) <= p['maximumLaneAgeSeconds'], 'lane_stale')
            require(all(type(lane.get(k)) is int and lane[k] >= 0 for k in ('polls', 'claimed', 'completed', 'failures')), 'lane_counters_missing')
        for name in ('verification', 'projection', 'legacy', 'scoring'):
            queue = status.get(name, {})
            count = queue.get('pending_at_least')
            require(type(count) is int and 0 <= count <= p['maximumPendingPerQueue']
                    and queue.get('truncated') is False, 'queue_limit_exceeded')
            # Old historical timestamps are not a measured publication latency.
            # Observe actual completions/decreasing debt, without resetting on growth.
            completed = next((v['completed'] for v in lanes if v['lane'] == name), None)
            marker = completed if name != 'scoring' else status.get('latest_publication_marker')
            previous = self.progress.get(name)
            progressed = previous is None or count == 0 or count < previous[0] or (marker is not None and marker != previous[1])
            changed = monotonic if progressed else previous[2]
            self.progress[name] = (count, marker, changed)
            require(count == 0 or monotonic - changed <= p['maximumDebtStallSeconds'], 'queue_stalled')
        database = status.get('database', {})
        connections, maximum, reserved = (database.get(k) for k in ('connections', 'max_connections', 'reserved_connections'))
        require(all(number(x) for x in (connections, maximum, reserved)) and maximum > reserved, 'database_observation_missing')
        require(100 * connections / (maximum - reserved) <= p['maximumDatabaseConnectionPercent'], 'database_connection_limit')
        require(number(resources.get('memoryAvailable')) and resources['memoryAvailable'] >= p['minimumHostAvailableMemoryBytes'], 'host_memory_limit')
        require(number(resources.get('diskFree')) and resources['diskFree'] >= p['minimumHostFreeDiskBytes'], 'host_disk_limit')
        memory = resources.get('containerMemoryPercent')
        require(isinstance(memory, dict) and set(memory) == {c['id'] for c in binding['containers']}, 'container_stats_missing')
        require(all(number(v) and v <= p['maximumContainerMemoryPercent'] for v in memory.values()), 'container_memory_limit')


def observe(binding):
    deadline = time.monotonic() + 15
    def remaining():
        seconds = deadline - time.monotonic()
        require(seconds > 0, 'observation_deadline')
        return seconds
    memory = {}
    for bound in binding['containers']:
        verify_container(inspect(bound['id'], remaining()), bound, binding)
        raw = command(['docker', 'stats', '--no-stream', '--format', '{{.MemPerc}}', bound['id']], remaining()).decode().strip()
        require(bool(re.fullmatch(r'\d+(?:\.\d+)?%', raw)), 'container_stats_missing')
        memory[bound['id']] = float(raw[:-1])
    intake = next(v for v in binding['containers'] if v['role'] == 'intake')
    status = json.loads(command(['docker', 'exec', intake['id'], 'deno', 'run', '--no-prompt', '--cached-only',
        '--frozen', '--lock=/app/deno.lock', '--allow-env', '--allow-net',
        '--allow-read=/app/workers/intake/source-revision', '/app/workers/intake/main.ts', '--status'], remaining()))
    host = dict(line.split(':', 1) for line in Path('/proc/meminfo').read_text().splitlines())
    available = host.get('MemAvailable', '').strip().split()
    require(len(available) == 2 and available[1] == 'kB', 'host_memory_observation_missing')
    disk = os.statvfs('/opt/frwhoop')
    remaining()
    return status, {'containerMemoryPercent': memory, 'memoryAvailable': int(available[0]) * 1024,
                    'diskFree': disk.f_bavail * disk.f_frsize}


def stop_bound(binding, policy):
    failed = False
    for bound in binding['containers']:
        try:
            # Docker IDs are immutable. Drift in mutable settings must not prevent a stop.
            verify_container(inspect(bound['id']), bound, binding, running=False, stopping=True)
            command(['docker', 'stop', '--time', str(int(policy['stopTimeoutSeconds'])), bound['id']], timeout=30)
        except Exception:
            failed = True
    return not failed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('bind', 'validate', 'run', 'stop'))
    parser.add_argument('--binding', required=True)
    parser.add_argument('--policy', required=True)
    parser.add_argument('--plan', required=True)
    parser.add_argument('--intake-container')
    parser.add_argument('--baseline-container')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if args.action == 'bind':
        bind_containers(args)
        print('{"status":"STOPPED_CANARY_BOUND","capacity":"NOT_MEASURED"}')
        return 0
    binding, policy = load_binding(args.binding, args.policy, args.plan, stopping=args.action == 'stop')
    if args.action == 'validate':
        for bound in binding['containers']:
            verify_container(inspect(bound['id']), bound, binding, running=False)
        print('{"status":"BINDING_VERIFIED","capacity":"NOT_MEASURED"}')
        return 0
    require(args.execute, 'explicit_execution_required')
    if args.action == 'stop':
        return 0 if stop_bound(binding, policy) else 3
    for bound in binding['containers']:
        observed = inspect(bound['id'])
        verify_container(observed, bound, binding, running=False)
        require(observed.get('State', {}).get('Running') is False, 'guard_requires_stopped_containers')
    def interrupted(_signal, _frame):
        # InterruptedError is treated as a retryable EINTR by Python selectors.
        # A distinct exception must unwind an in-flight Docker subprocess now.
        raise RuntimeError('guard_interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    evaluator = Evaluator(policy, time.monotonic())
    try:
        # Signal handlers and fail-closed cleanup are armed before the first claim.
        for bound in binding['containers']:
            command(['docker', 'start', bound['id']])
        while True:
            status, resources = observe(binding)
            evaluator.evaluate(status, resources, binding, time.time(), time.monotonic())
            print(json.dumps({'status': 'OBSERVED_WITHIN_STOP_THRESHOLDS', 'observedAt': datetime.now(timezone.utc).isoformat(),
                              'capacity': 'NOT_MEASURED'}), flush=True)
            time.sleep(policy['pollSeconds'])
    except Exception:
        # Fixed diagnostics only: SQL/Docker exceptions may include private scope.
        print('{"status":"CANARY_STOP_REQUIRED","reason":"observer_or_threshold_failed"}', flush=True)
    finally:
        stopped = stop_bound(binding, policy)
        print(json.dumps({'status': 'BOUND_CANARY_STOPPED' if stopped else 'STOP_FAILED_OPERATOR_REQUIRED'}), flush=True)
    return 3


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception:
        print('NOT_READY: canary guard binding or observation failed', file=sys.stderr)
        raise SystemExit(3)
