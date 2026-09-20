import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { verifyEvidence } from './verify-sync-evidence.mjs';
import { readJSON, requireThat, reportError } from './sync-evidence-contract.mjs';
import { canonicalMigrationLedger } from './sync-migration-ledger.mjs';
import { packetRelease, verifyImage, IMAGE_FORMAT } from './scorer-image-release.mjs';

// Independently reviewed selector: values, never executable shell configuration.
export function candidateSelector(e) {
  return {
    schemaVersion: 1, environment: e.environment, endpoint: e.endpoint, sshHost: e.target.sshHost,
    appCommit: e.build.commit, serverCommit: e.server.commit, edgeRevision: e.server.edgeRevision,
    imageDigest: e.server.imageDigest, dockerImageId: e.server.dockerImageId, containerId: e.server.containerId,
    ownerUserId: e.canary.ownerUserId, deviceId: e.canary.deviceId, objectId: e.canary.objectId,
    ownerNamespace: e.canary.ownerNamespace, recordDigest: e.canary.recordDigest,
    inputRevision: e.canary.inputRevision, resultRevision: e.canary.resultRevision,
    day: e.canary.day, algorithmVersion: e.canary.algorithmVersion,
  };
}
function sameFields(actual, expected, label) {
  requireThat(actual && typeof actual === 'object' && !Array.isArray(actual) &&
    Object.keys(actual).length === Object.keys(expected).length &&
    Object.entries(expected).every(([key, value]) => actual[key] === value), `${label} differs from validated candidate`);
}
const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
function command(program, args, label) {
  const result = spawnSync(program, args, { encoding: 'utf8', timeout: 30_000, maxBuffer: 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  requireThat(!result.error && !result.signal && result.status === 0, `${label} command failed`);
  return result.stdout.trim();
}

export function checkLive(e, directory, selector, ssh, pause = () => command('sleep', ['15'], 'heartbeat wait'), now = () => Date.now()) {
  verifyEvidence(e, directory, now());
  sameFields(selector, candidateSelector(e), 'operator target');
  const release = packetRelease(e, directory);
  const json = (remote, label) => {
    let value;
    try { value = JSON.parse(ssh(remote, label)); } catch (error) {
      if (error?.message?.startsWith('NOT_READY:')) throw error;
      requireThat(false, `${label} returned invalid or empty JSON`);
    }
    return value;
  };
  const sql = (query, label) => json(`docker exec -e 'PGOPTIONS=-c default_transaction_read_only=on -c statement_timeout=10000' supabase-db psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -tAc ${quote(query)}`, label);
  const objects = sql(`select json_build_object(
    'workItems',to_regclass('public.scoring_work_items') is not null,
    'heartbeats',to_regclass('public.scoring_service_heartbeats') is not null,
    'ingest',exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='engine_ingest_scored'))`, 'schema objects');
  sameFields(objects, { workItems: true, heartbeats: true, ingest: true }, 'schema objects');
  const ledger = sql('select coalesce(json_agg(version order by version),\'[]\'::json) from supabase_migrations.schema_migrations', 'migration ledger');
  const canonicalLedger = canonicalMigrationLedger(ledger);
  requireThat(JSON.stringify(canonicalLedger) === JSON.stringify([...e.server.migrations].sort()), 'live migration ledger differs from evidence');
  const format = '{"containerId":{{json .Id}},"running":{{json .State.Running}},"imageId":{{json .Image}},"imageReference":{{json .Config.Image}},"revision":{{json (index .Config.Labels "org.opencontainers.image.revision")}},"ports":{{json .NetworkSettings.Ports}},"networkMode":{{json .HostConfig.NetworkMode}}}';
  const container = json(`docker inspect --type container --format ${quote(format)} ${quote(e.server.containerId)}`, 'scorer inspection');
  requireThat(container?.containerId === e.server.containerId, 'inspected scorer container ID differs from candidate');
  requireThat(container?.running === true && container.imageId === e.server.dockerImageId && container.revision === e.server.commit,
    'running scorer image ID or revision differs from candidate');
  requireThat(container.imageReference === release.image.reference, 'running scorer was not configured with reviewed image pin');
  requireThat(container.ports && typeof container.ports === 'object' && !Array.isArray(container.ports) &&
    Object.values(container.ports).every(bindings => bindings === null || (Array.isArray(bindings) && bindings.length === 0)), 'scorer published ports or unverifiable port inspection');
  requireThat(typeof container.networkMode === 'string' && container.networkMode.length > 0 && container.networkMode !== 'host' &&
    !container.networkMode.startsWith('container:'), 'host/shared-container networking cannot establish scorer port isolation');
  const digests = json(`docker image inspect --format '{{json .RepoDigests}}' ${quote(e.server.dockerImageId)}`, 'image registry digest');
  requireThat(Array.isArray(digests) && digests.length > 0 && digests.every(digest => typeof digest === 'string' && /^\S+@sha256:[0-9a-f]{64}$/.test(digest)) &&
    digests.some(digest => digest.endsWith(`@${e.server.imageDigest}`)), 'running image registry digest differs from candidate');
  const heartbeat = () => {
    const value = sql('select json_build_object(\'lastPollAtMs\',floor(extract(epoch from last_poll_at)*1000)::bigint,\'serverNowMs\',floor(extract(epoch from clock_timestamp())*1000)::bigint) from public.scoring_service_heartbeats where id=1', 'heartbeat');
    requireThat(Number.isSafeInteger(value?.lastPollAtMs) && Number.isSafeInteger(value?.serverNowMs) &&
      Math.abs(value.serverNowMs - now()) <= 60_000 && value.lastPollAtMs <= value.serverNowMs + 60_000 &&
      value.serverNowMs - value.lastPollAtMs <= 15 * 60_000, 'live heartbeat stale, future dated or malformed');
    return value.lastPollAtMs;
  };
  const first = heartbeat(); pause(); const second = heartbeat();
  requireThat(second > first, 'live heartbeat did not advance');
  const c = e.canary;
  // No per-snapshot contributor list exists. Check both exact rows, not an invented causal hash.
  const canary = sql(`select json_build_object(
    'ownerUserId',s.user_id,'deviceId',s.device_id,'inputRevision',s.input_revision,'resultRevision',s.result_revision,
    'day',s.day,'algorithmVersion',s.algorithm_version,'objectId',o.id,
    'recordDigest',o.durability_receipt->>'contentSha256','receiptState',o.durability_receipt->>'state',
    'receiptOwner',o.durability_receipt->>'ownerUserId','receiptDevice',o.durability_receipt->>'deviceId',
    'receiptObject',o.durability_receipt->>'objectId','indexedBeforeComputed',o.indexed_at<=s.computed_at)
    from public.scoring_snapshots_v2 s join public.object_manifests o on o.user_id=s.user_id and o.device_id=s.device_id
    where s.user_id='${c.ownerUserId}'::uuid and s.device_id='${c.deviceId}'::uuid
    and s.input_revision=${c.inputRevision} and s.result_revision=${c.resultRevision}
    and s.day='${c.day}'::date and s.algorithm_version='${c.algorithmVersion}'
    and o.id='${c.objectId}'::uuid and o.object_class='raw' and o.status='ready'
    and o.sha256_source='server_verified' and o.verified_at is not null and o.indexed_at is not null`, 'canary receipt/snapshot');
  sameFields(canary, {
    ownerUserId: c.ownerUserId, deviceId: c.deviceId, inputRevision: c.inputRevision, resultRevision: c.resultRevision,
    day: c.day, algorithmVersion: c.algorithmVersion, objectId: c.objectId, recordDigest: c.recordDigest,
    receiptState: 'verified_indexed', receiptOwner: c.ownerUserId, receiptDevice: c.deviceId, receiptObject: c.objectId, indexedBeforeComputed: true,
  }, 'live canary receipt/snapshot');
  const image = json(`docker image inspect --format ${quote(IMAGE_FORMAT)} ${quote(e.server.dockerImageId)}`, 'immutable image metadata');
  verifyImage(image, release.image);
  verifyEvidence(e, directory, now()); // Reject packets that expired during a build/inspection.
  return { status: 'READ_ONLY_CHECKS_PASSED', containerId: container.containerId,
    imageProvenance: { imageReference: container.imageReference, image, registryDigest: release.image.registryDigest,
      platformManifestDigest: release.image.platformManifestDigest, sourceCommit: release.source.commit,
      contextSha256: release.source.contextSha256, nativeInputSha256: release.source.nativeInputSha256 },
    migrationLedger: { observedRaw: [...ledger], canonicalIDs: canonicalLedger, recordedRaw: [...e.server.migrationLedgerRaw] },
    productionReadiness: 'NOT_READY: independent review, whole-day parity and physical/deployment acceptance remain separate' };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const e = readJSON(process.env.SYNC_ACCEPTANCE_EVIDENCE);
    const directory = path.dirname(path.resolve(process.env.SYNC_ACCEPTANCE_EVIDENCE));
    const selector = readJSON(process.env.SYNC_ACCEPTANCE_TARGET);
    verifyEvidence(e, directory);
    sameFields(selector, candidateSelector(e), 'operator target');
    // Only explicit operator paths. Never load deployment shell files or read key contents here.
    for (const name of ['SYNC_ACCEPTANCE_SSH_KEY', 'SYNC_ACCEPTANCE_KNOWN_HOSTS']) {
      const filename = process.env[name];
      requireThat(typeof filename === 'string' && path.isAbsolute(filename) && !/[\r\n\0]/.test(filename), `${name} must be an absolute path`);
      requireThat(fs.statSync(filename).isFile(), `${name} must be a file`);
    }
    const args = ['-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10',
      '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none', '-o', 'GlobalKnownHostsFile=/dev/null',
      '-o', `UserKnownHostsFile="${process.env.SYNC_ACCEPTANCE_KNOWN_HOSTS.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`,
      '-i', process.env.SYNC_ACCEPTANCE_SSH_KEY, `deploy@${e.target.sshHost}`];
    console.log(JSON.stringify(checkLive(e, directory, selector, (remote, label) => command('ssh', [...args, remote], label))));
  } catch (error) { reportError(error); }
}
