import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { CANARY_STAGES, SCENARIOS, requireThat, instant, nonempty, sha, uuid, readJSON, reportError } from './sync-evidence-contract.mjs';
import { validateMigrationEvidence } from './sync-migration-ledger.mjs';
import { packetRelease } from './scorer-image-release.mjs';

// Validates collected evidence; it neither generates a canary nor certifies artifact authenticity.
export function verifyEvidence(e, directory, now = Date.now()) {
  requireThat(e?.schemaVersion === 2, 'evidence schemaVersion must be 2 (explicit target/canary binding)');
  requireThat(e?.environment === 'staging' || e?.environment === 'production', 'record effective environment');
  let endpoint;
  try { endpoint = new URL(e.endpoint); } catch { /* Rejected below, without echoing input. */ }
  requireThat(endpoint?.protocol === 'https:' && !endpoint.username && !endpoint.password && !endpoint.search && !endpoint.hash &&
    endpoint.origin === e.endpoint, 'record canonical HTTPS project origin without credentials/path/query');
  requireThat(typeof e.target?.sshHost === 'string' && /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(e.target.sshHost) &&
    e.target.sshHost.length <= 253, 'record explicit SSH host (DNS or IPv4, no user/port/options)');
  requireThat(nonempty(e.target?.bindingArtifact), 'endpoint/environment to SSH target mapping artifact required');
  const started = instant(e.collection?.startedAt), completed = instant(e.collection?.completedAt);
  requireThat(Number.isFinite(now) && Number.isFinite(started) && Number.isFinite(completed) && completed > started &&
    completed - started <= 7 * 86400_000 && completed <= now + 60_000 && now - completed <= 15 * 60_000,
  'collection window must be at most seven days and complete within 15 minutes');
  const inWindow = (value, label) => {
    const at = instant(value);
    requireThat(Number.isFinite(at) && at >= started && at <= completed, `${label} outside collection window`);
    return at;
  };
  requireThat(/^[0-9a-f]{40}$/.test(e.build?.commit ?? ''), 'record exact app commit');
  requireThat(nonempty(e.build?.version) && nonempty(e.build?.number), 'record installed version/build');
  requireThat(e.build?.configuration === 'Release', 'device measurements require Release');
  requireThat(nonempty(e.build?.xcode) && nonempty(e.build?.sdk), 'record toolchain/SDK');
  requireThat(/^[0-9a-f]{40}$/.test(e.server?.commit ?? ''), 'record server commit');
  requireThat(/^sha256:[0-9a-f]{64}$/.test(e.server?.imageDigest ?? ''), 'record immutable scorer image digest');
  requireThat(/^sha256:[0-9a-f]{64}$/.test(e.server?.dockerImageId ?? ''), 'record Docker image config ID separately from registry digest');
  requireThat(sha(e.server?.containerId), 'record exact 64-character lowercase Docker container ID');
  requireThat(nonempty(e.server?.edgeRevision), 'record effective Edge revision');
  validateMigrationEvidence(e.server);
  const beats = e.server?.heartbeats;
  requireThat(Array.isArray(beats) && beats.length >= 2, 'two heartbeat samples required');
  let previousBeat = -Infinity;
  for (const beat of beats) {
    const at = inWindow(beat, 'heartbeat');
    requireThat(at > previousBeat, 'heartbeat must advance at every sample');
    previousBeat = at;
  }
  const last = previousBeat;
  requireThat(last <= now + 60_000 && now - last <= 15 * 60_000, 'heartbeat evidence is stale or future dated');
  requireThat(e.canary?.credentialKind === 'userJWT', 'canary must use normal authenticated user credentials');
  requireThat(sha(e.canary?.ownerNamespace) && sha(e.canary?.recordDigest), 'canary needs opaque owner and record correlation');
  requireThat(uuid(e.canary.ownerUserId) && uuid(e.canary.deviceId) && uuid(e.canary.objectId), 'canary requires explicit lowercase owner/device/object UUIDs');
  requireThat(e.canary.recordDigestScope === 'object-content-sha256', 'canary digest must be the verified uncompressed object content SHA-256');
  requireThat(/^\d{4}-\d{2}-\d{2}$/.test(e.canary.day ?? '') && Number.isFinite(instant(`${e.canary.day}T00:00:00.000Z`)), 'canary result day required');
  requireThat(typeof e.canary.algorithmVersion === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(e.canary.algorithmVersion), 'canary algorithm version required');
  requireThat(nonempty(e.canary.inputBindingArtifact), 'reviewed object-to-input/result correlation artifact required');
  const stages = CANARY_STAGES;
  let previous = -Infinity;
  for (const stage of stages) {
    const observed = e.canary?.stages?.[stage];
    const at = inWindow(observed?.at, stage);
    requireThat(Number.isFinite(at) && at >= previous && at <= now + 60_000, `invalid or missing ${stage} observation`);
    requireThat(['ownerNamespace', 'recordDigest', 'ownerUserId', 'deviceId', 'objectId', 'inputRevision', 'resultRevision']
      .every(key => observed[key] === e.canary[key]),
                `${stage} correlation does not match captured owner/record`);
    requireThat(nonempty(observed.artifact), `${stage} requires a raw evidence artifact`);
    previous = at;
  }
  requireThat(now - previous <= 15 * 60_000, 'canary completion is stale');
  requireThat(Number.isSafeInteger(e.canary.inputRevision) && e.canary.inputRevision > 0, 'missing input revision');
  requireThat(Number.isSafeInteger(e.canary.resultRevision) && e.canary.resultRevision > 0, 'missing result revision');
  requireThat(e.canary.displayedRevision === e.canary.resultRevision, 'displayed result is not the observed server revision');
  for (const name of SCENARIOS) {
    const gate = e.scenarios?.[name];
    requireThat(gate?.status === 'pass' && nonempty(gate.artifact), `${name} is unverified`);
    inWindow(gate.observedAt, name);
  }
  requireThat(Array.isArray(e.performance) && e.performance.length >= 2, '60 Hz and ProMotion traces required');
  requireThat([60, 120].every(hz => e.performance.some(p => p?.actualRefreshHz === hz)), '60 Hz and ProMotion traces required');
  for (const sample of e.performance) {
    const hz = sample?.actualRefreshHz;
    requireThat(Number.isInteger(hz) && hz > 0 && hz <= 240, 'invalid measured refresh rate');
    requireThat(sample && nonempty(sample.device) && nonempty(sample.os) && nonempty(sample.artifact), `${hz} Hz physical-device trace missing`);
    requireThat(sample.physicalDevice === true && sample.configuration === 'Release', `${hz} Hz must be physical Release evidence`);
    requireThat(sample.metric === 'aggregateHitchesMsPerSecond' && Number.isFinite(sample.value) && sample.value >= 0 && sample.value <= 10,
                `${hz} Hz aggregate Hitches outside good band`);
    requireThat(sample.unresolvedMainThreadStalls250ms === 0, `${hz} Hz unresolved main-thread stalls`);
    requireThat(nonempty(sample.toolVersion) && nonempty(sample.denominator), `${hz} Hz metric scope/tool missing`);
    requireThat(sample.buildCommit === e.build.commit, `${hz} Hz trace belongs to another app commit`);
    inWindow(sample.observedAt, `${hz} Hz trace`);
  }
  inWindow(e.latency?.observedAt, 'latency');
  const bounds = { warmNavigationP95Ms: 100, coldCachedDashboardP95Ms: 1000, activeCommitToDisplayP95Ms: 120000 };
  for (const [metric, limit] of Object.entries(bounds)) {
    requireThat(Number.isFinite(e.latency?.[metric]) && e.latency[metric] >= 0 && e.latency[metric] <= limit,
                `${metric} absent or above gate`);
  }
  requireThat(e.energy?.matchedBaseline === true && e.energy?.unexplainedRetryLoop === false &&
              e.energy?.sustainedSeriousThermal === false && nonempty(e.energy?.artifact), 'matched energy/thermal evidence missing');
  requireThat(e.security?.userLevelRls === 'pass' && e.security?.crossAccountRejected === 'pass' && nonempty(e.security?.artifact),
              'user-level RLS and cross-account evidence missing');
  inWindow(e.energy.observedAt, 'energy');
  inWindow(e.security.observedAt, 'security');
  requireThat(nonempty(e.latency.artifact), 'latency evidence artifact missing');
  requireThat(Array.isArray(e.artifacts) && e.artifacts.length > 0, 'raw artifact manifest missing');
  const names = new Set();
  const canonicalDirectory = fs.realpathSync(directory);
  for (const artifact of e.artifacts) {
    requireThat(nonempty(artifact.path) && !path.isAbsolute(artifact.path) && sha(artifact.sha256), 'invalid artifact path/digest');
    requireThat(!names.has(artifact.path), 'duplicate artifact path');
    const resolved = fs.realpathSync(path.resolve(canonicalDirectory, artifact.path));
    requireThat(resolved.startsWith(canonicalDirectory + path.sep), 'artifact escaped evidence directory');
    requireThat(fs.statSync(resolved).isFile(), 'artifact is not a regular file');
    requireThat(crypto.createHash('sha256').update(fs.readFileSync(resolved)).digest('hex') === artifact.sha256, 'artifact digest mismatch');
    names.add(artifact.path);
  }
  const references = [...stages.map(stage => e.canary.stages[stage].artifact),
    ...Object.values(e.scenarios).map(gate => gate.artifact), ...e.performance.map(p => p.artifact), e.energy.artifact, e.security.artifact,
    e.latency.artifact, e.target.bindingArtifact, e.canary.inputBindingArtifact, e.server.imageProvenanceArtifact];
  requireThat(references.every(reference => names.has(reference)), 'an evidence reference has no verified artifact');
  packetRelease(e, directory);
  return { status: 'EVIDENCE_VALIDATED', artifacts: names.size, productionReadiness: 'requires exact candidate review' };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const filename = process.argv[2];
    const result = verifyEvidence(readJSON(filename), path.dirname(path.resolve(filename)));
    console.log(JSON.stringify(result));
  } catch (error) {
    reportError(error);
  }
}
