#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { prepareDeploymentSourceBundle, verifyDeploymentSourceBundle } from './deployment-source-bundle.mjs';
import { prepareEdgeSourceBundle, verifyEdgeSourceBundle } from './edge-source-bundle.mjs';

const SHA256 = /^[0-9a-f]{64}$/;
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const REVISION = /^[0-9a-f]{40}$/;
// OpenSSH joins remote command arguments into shell text. Limit image references to the
// lowercase Docker registry/path alphabet so a reviewed reference remains one inert token
// when deployment passes it to the remote shell.
const REGISTRY_DIGEST_REFERENCE = /^[a-z0-9][a-z0-9._:-]*(?:\/[a-z0-9][a-z0-9._-]*)+@sha256:[0-9a-f]{64}$/;
export const INTAKE_RUNTIME_IMAGE = 'docker.io/denoland/deno:2.5.6@sha256:3ea71953ff50e3ff15c377ead1a8521f624e2f43d27713675a8bed7b33f166aa';
export const INTAKE_ENTRYPOINT = Object.freeze(['deno', 'run', '--no-prompt', '--cached-only', '--frozen',
  '--lock=/app/deno.lock', '--allow-env', '--allow-net',
  '--allow-read=/app/workers/intake/source-revision', '/app/workers/intake/main.ts']);
const INTAKE_COMPOSE_PATH = 'infra/vps/templates/docker-compose.intake.yml';
const INTAKE_PROJECT = 'sgoyxzcagqyxexmsidtk';
const BASELINE_COMMIT = '5caa31689da0023e111beb36850d3f81d67e1be2';
const PLATFORM = 'linux/amd64';
const BUILD_IMAGE = 'docker.io/library/eclipse-temurin@sha256:e573c097106f35634857604fdfbe70a2a2bbcaa52574bca3d2025703d0df994d';
const RUNTIME_IMAGE = 'docker.io/library/eclipse-temurin@sha256:24cd8eed18b5976441d27b45823490eb5e8efff4b3ecdc632e442717ea66f160';
export const POSTGRES_CLIENT = Object.freeze({
  reference: 'docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3',
  manifestDigest: 'sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3',
  configDigest: 'sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537',
  platform: PLATFORM,
  version: '17.11-alpine3.24',
});
export const ANDROID_INSPECTION_TOOLS = Object.freeze({
  aapt2: Object.freeze({
    sha256: '22d092d529b050c71016f3f4402f53fadcd358a65fe16df408c400f0fe9ffe62',
    version: 'Android Asset Packaging Tool (aapt) 2.19-10229193',
  }),
  apksigJar: Object.freeze({
    sha256: 'eefdd6aed9db9fb849e4c98a50d8741e19d1b674ba6547220bcb9c3ed152123a',
  }),
});
const MIGRATION_TOTAL = 128;
const MIGRATION_BASELINE = 117;
const MIGRATION_SCHEMA_FINGERPRINT = 'f5d9f630389b1236efbe8494878faecb0fe8e9e17f5d25b47723759d9c58d92d';
const MIGRATION_CATALOG_PATH = 'scoring-service/service/src/main/resources/scoring-migration-catalog.json';
const MIGRATION_DIRECTORY = 'supabase/migrations';
const MIGRATION_WORKSTREAMS = Object.freeze([
  Object.freeze({ workstream: 'persistent-sync-followup', branch: 'codex/persistent-sync-followup-2026-09-22',
    tip: 'a972493212f2eae29f01ecaddf9182260153400f', migrationCount: 2 }),
  Object.freeze({ workstream: 'server-repair', branch: 'repair/vps-server-20260922',
    tip: null, migrationCount: 2 }),
  Object.freeze({ workstream: 'server-pipeline', branch: 'fix/server-pipeline',
    tip: 'cfb94434b1b4ed4dba587e5c4e7af405e782e560', migrationCount: 117 }),
  Object.freeze({ workstream: 'multiuser-scale', branch: 'feat/multiuser-scale',
    tip: '0eac19cce495e761dc3d832dd1cfd8a07221c61d', migrationCount: 4 }),
  Object.freeze({ workstream: 'sensor-algorithms', branch: 'feat/sensor-algorithms',
    tip: '198b99924a79148ff01833115fe2f47f2025bfa4', migrationCount: 1 }),
  Object.freeze({ workstream: 'ble-sync', branch: 'fix/ble-sync',
    tip: 'af9468f7a48cc3fddeb33d7a3b983204af620ca6', migrationCount: 0 }),
  Object.freeze({ workstream: 'vps-only-compute', branch: 'feat/vps-only-compute',
    tip: '63ac35d0cab0644d197e8225d9fc97e1bd9446cf', migrationCount: 2 }),
]);
const EDGE_FUNCTIONS = ['account-deletion', 'ingest-verify', 'push', 'reconcile', 'retention-sweep', 'scores'];
const CANARY_GUARD_FILES = Object.freeze({
  policy: 'infra/vps/scoped-canary-stop-policy.json',
  helper: 'infra/vps/scripts/scoped-canary-guard.py',
  service: 'infra/vps/templates/frwhoop-scoped-canary.service',
});
const CANARY_GUARD_DEPENDENCIES = Object.freeze(['infra/vps/scripts/scoring-admission.py',
  'infra/vps/scripts/verify-worker-image.py', 'infra/vps/scripts/verify-pinned-postgres-client.py']);
const CONTRACT_FILES = [
  ...Object.values(CANARY_GUARD_FILES), ...CANARY_GUARD_DEPENDENCIES,
  'Tools/release/certificates/supabase-prod-ca-2021.crt',
  'Tools/release/VerifyApk.java',
  'Tools/release/deployment-source-bundle.mjs',
  'Tools/release/edge-source-bundle.mjs',
  'Tools/release/generate-migration-manifest.mjs',
  'Tools/release/inspect_ipa.py',
  'Tools/release/release-artifact-manifest.mjs',
  'android/app/build.gradle.kts',
  'android/app/src/main/AndroidManifest.xml',
  'android/fork-debug.keystore',
  'infra/vps/launch-capacity.json',
  'infra/vps/templates/Dockerfile.baseline',
  'infra/vps/templates/Dockerfile.intake',
  INTAKE_COMPOSE_PATH,
  'workers/intake/main.ts',
  'supabase/functions/_shared/intakeConsumer.ts',
  'supabase/functions/_shared/intakeAdmission.ts',
  'supabase/functions/deno.lock',
  'supabase/migrations/20260922120000_intake_service_contract.sql',
  'supabase/migrations/20260922130000_scoped_intake_admission.sql',
  'infra/vps/templates/docker-compose.scoring-override.yml',
  'project.yml',
  'scoring-service/Dockerfile',
  'scoring-service/legacy-baseline/build.py',
  'scoring-service/legacy-baseline/runtime-identity.patch',
  'scoring-service/legacy-baseline/transport.patch',
  'scoring-service/service/src/main/kotlin/com/frwhoop/scoring/RuntimePreflightCommand.kt',
  'scoring-service/service/src/main/kotlin/com/frwhoop/scoring/ScoringConfig.kt',
  'scoring-service/service/src/main/kotlin/com/frwhoop/scoring/db/PostgresClient.kt',
  'scoring-service/service/src/main/kotlin/com/frwhoop/scoring/health/HeartbeatReporter.kt',
  'supabase/migrations/20260919020000_physiology_worker_heartbeats.sql',
];

function invariant(value, message) {
  if (!value) throw new Error(`NOT_READY: ${message}`);
}
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function exactKeys(value, keys, label) {
  invariant(isObject(value), `${label} must be an object`);
  invariant(JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort()), `${label} fields differ`);
}
function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (!isObject(value)) return value;
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])]));
}
export const canonicalJSON = value => JSON.stringify(sorted(value));
export const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function runResult(program, args, options = {}) {
  const result = spawnSync(program, args, { ...options, maxBuffer: options.maxBuffer ?? 64 * 1024 * 1024 });
  invariant(!result.error && !result.signal && result.status === 0,
    `${path.basename(program)} failed${!options.privateOutput && result.stderr?.length ? `: ${result.stderr.toString('utf8').trim().slice(0, 500)}` : ''}`);
  return result;
}
function run(program, args, options = {}) {
  return runResult(program, args, options).stdout;
}
export function inspectAapt2Version(program) {
  const result = runResult(program, ['version']);
  const stdout = result.stdout.toString('utf8').trim();
  const stderr = result.stderr.toString('utf8').trim();
  invariant(stdout.length === 0 && stderr === ANDROID_INSPECTION_TOOLS.aapt2.version,
    'aapt2 version differs from reviewed Android SDK build-tools 34.0.0');
  return stderr;
}
function git(repo, ...args) {
  return run('git', ['--no-replace-objects', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
    '-c', 'protocol.allow=never', ...args], { cwd: repo,
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, GIT_CONFIG_NOSYSTEM: '1',
      GIT_CONFIG_GLOBAL: '/dev/null', GIT_NO_LAZY_FETCH: '1', GIT_NO_REPLACE_OBJECTS: '1' } });
}
function relative(value, label = 'artifact path') {
  invariant(typeof value === 'string' && value.length > 0 && value.length <= 1024 &&
    !path.isAbsolute(value) && !value.includes('\\') && !/[\x00-\x1f\x7f]/.test(value) &&
    value.split('/').every(part => part && part !== '.' && part !== '..'), `invalid ${label}`);
  return value;
}
function artifactFile(root, name) {
  relative(name);
  const base = fs.realpathSync(root);
  let current = base;
  for (const part of name.split('/')) {
    current = path.join(current, part);
    const stat = fs.lstatSync(current);
    invariant(!stat.isSymbolicLink(), `artifact path contains a symlink: ${name}`);
  }
  const stat = fs.statSync(current);
  invariant(stat.isFile() && stat.size >= 0, `artifact is not a regular file: ${name}`);
  invariant(fs.realpathSync(current).startsWith(base + path.sep), `artifact escapes root: ${name}`);
  return current;
}
function boundedJSON(filename, limit = 64 * 1024 * 1024) {
  const stat = fs.statSync(filename);
  invariant(stat.size <= limit, `JSON artifact exceeds ${limit} bytes`);
  try { return JSON.parse(fs.readFileSync(filename, 'utf8')); } catch { invariant(false, `malformed JSON: ${path.basename(filename)}`); }
}
function hashFile(filename) {
  const descriptor = fs.openSync(filename, 'r');
  try {
    const digest = crypto.createHash('sha256'), buffer = Buffer.allocUnsafe(1024 * 1024);
    let offset = 0;
    while (true) {
      const count = fs.readSync(descriptor, buffer, 0, buffer.length, offset);
      if (!count) break;
      digest.update(buffer.subarray(0, count)); offset += count;
    }
    return digest.digest('hex');
  } finally { fs.closeSync(descriptor); }
}
function fileIdentity(root, name) {
  const filename = artifactFile(root, name), stat = fs.statSync(filename);
  return { path: name, sizeBytes: stat.size, sha256: hashFile(filename) };
}
function tarString(buffer, start, length) {
  const end = buffer.indexOf(0, start);
  return buffer.subarray(start, end >= start && end < start + length ? end : start + length).toString('utf8');
}
function tarNumber(buffer, start, length) {
  const raw = buffer.subarray(start, start + length);
  invariant((raw[0] & 0x80) === 0, 'base-256 tar numbers are unsupported');
  const text = raw.toString('ascii').replace(/\0.*$/, '').trim();
  invariant(!text || /^[0-7]+$/.test(text), 'invalid tar numeric field');
  return text ? Number.parseInt(text, 8) : 0;
}
function parseTar(filename) {
  const stat = fs.statSync(filename);
  const descriptor = fs.openSync(filename, 'r'), entries = new Map(), header = Buffer.alloc(512);
  let offset = 0, ended = false;
  try {
    while (offset + 512 <= stat.size) {
      invariant(fs.readSync(descriptor, header, 0, 512, offset) === 512, 'truncated tar header');
      if (header.every(byte => byte === 0)) { ended = true; break; }
      const stored = tarNumber(header, 148, 8);
      let sum = 0;
      for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 32 : header[i];
      invariant(stored === sum, 'tar header checksum differs');
      const prefix = tarString(header, 345, 155), leaf = tarString(header, 0, 100);
      const name = prefix ? `${prefix}/${leaf}` : leaf;
      relative(name.replace(/\/$/, ''), 'tar member');
      invariant(!entries.has(name), `duplicate tar member: ${name}`);
      const size = tarNumber(header, 124, 12), type = String.fromCharCode(header[156] || 48);
      invariant(Number.isSafeInteger(size) && size >= 0, 'invalid tar member size');
      const dataOffset = offset + 512;
      invariant(dataOffset + size <= stat.size, `truncated tar member: ${name}`);
      invariant(type === '0' || type === '5', `non-regular OCI tar member: ${name}`);
      entries.set(name, { name, type, size, offset: dataOffset });
      offset = dataOffset + Math.ceil(size / 512) * 512;
    }
  } finally { fs.closeSync(descriptor); }
  invariant(ended, 'tar has no zero-block terminator');
  return entries;
}
function readTarEntry(filename, entry, limit = 32 * 1024 * 1024) {
  invariant(entry?.type === '0' && entry.size <= limit, `missing or excessive tar entry: ${entry?.name ?? 'unknown'}`);
  const bytes = Buffer.alloc(entry.size), descriptor = fs.openSync(filename, 'r');
  try { invariant(fs.readSync(descriptor, bytes, 0, bytes.length, entry.offset) === bytes.length, 'short tar entry read'); }
  finally { fs.closeSync(descriptor); }
  return bytes;
}
function hashTarEntry(filename, entry) {
  const descriptor = fs.openSync(filename, 'r'), digest = crypto.createHash('sha256'), buffer = Buffer.allocUnsafe(1024 * 1024);
  let remaining = entry.size, offset = entry.offset;
  try {
    while (remaining) {
      const wanted = Math.min(buffer.length, remaining);
      const count = fs.readSync(descriptor, buffer, 0, wanted, offset);
      invariant(count > 0, 'short tar blob read');
      digest.update(buffer.subarray(0, count)); remaining -= count; offset += count;
    }
  } finally { fs.closeSync(descriptor); }
  return digest.digest('hex');
}
function parseJSONBytes(bytes, label) {
  try { return JSON.parse(bytes.toString('utf8')); } catch { invariant(false, `malformed ${label}`); }
}
function descriptorEntry(archive, entries, descriptor, label) {
  invariant(isObject(descriptor) && DIGEST.test(descriptor.digest) && Number.isSafeInteger(descriptor.size), `invalid ${label} descriptor`);
  const entry = entries.get(`blobs/sha256/${descriptor.digest.slice(7)}`);
  invariant(entry?.type === '0' && entry.size === descriptor.size, `${label} blob size differs`);
  invariant(hashTarEntry(archive, entry) === descriptor.digest.slice(7), `${label} blob digest differs`);
  return entry;
}
export function inspectOCI(filename, role, sourceRevision, buildMetadata, provenance = undefined) {
  invariant(['selected-v1', 'shadow-v2', 'intake'].includes(role), 'unsupported OCI role');
  const entries = parseTar(filename);
  const layout = parseJSONBytes(readTarEntry(filename, entries.get('oci-layout')), 'OCI layout');
  invariant(layout?.imageLayoutVersion === '1.0.0', 'unsupported OCI layout');
  const indexBytes = readTarEntry(filename, entries.get('index.json'));
  const index = parseJSONBytes(indexBytes, 'OCI index');
  invariant(index?.schemaVersion === 2 && Array.isArray(index.manifests), 'invalid OCI index');
  const manifests = index.manifests.filter(item => item?.platform?.os === 'linux' &&
    item.platform.architecture === 'amd64' && !item.platform.variant &&
    ['application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json'].includes(item.mediaType));
  invariant(manifests.length === 1, 'OCI archive lacks one linux/amd64 image manifest');
  const selected = manifests[0], manifestEntry = descriptorEntry(filename, entries, selected, 'image manifest');
  const manifest = parseJSONBytes(readTarEntry(filename, manifestEntry), 'OCI image manifest');
  invariant(manifest?.schemaVersion === 2 && isObject(manifest.config) && Array.isArray(manifest.layers), 'invalid OCI image manifest');
  const configEntry = descriptorEntry(filename, entries, manifest.config, 'image config');
  for (const [index, layer] of manifest.layers.entries()) descriptorEntry(filename, entries, layer, `image layer ${index + 1}`);
  const config = parseJSONBytes(readTarEntry(filename, configEntry), 'OCI image config');
  invariant(config.os === 'linux' && config.architecture === 'amd64', 'OCI config platform differs');
  const labels = config?.config?.Labels;
  invariant(isObject(labels) && labels['org.opencontainers.image.revision'] === sourceRevision, 'OCI source revision label differs');
  const expectedDigest = selected.digest, expectedConfig = manifest.config.digest;
  invariant(buildMetadata?.['containerimage.digest'] === expectedDigest &&
    buildMetadata?.['containerimage.config.digest'] === expectedConfig, 'BuildKit metadata differs from OCI descriptors');
  invariant(buildMetadata?.['containerimage.descriptor']?.digest === expectedDigest, 'BuildKit descriptor digest differs');
  if (role === 'selected-v1') {
    invariant(Array.isArray(config.config.Env) && canonicalJSON(config.config.Env.filter(value =>
      /^(JAVA_OPTS|JAVA_TOOL_OPTIONS|JDK_JAVA_OPTIONS|_JAVA_OPTIONS)=/.test(value))) ===
      canonicalJSON(['JAVA_OPTS=-Xmx512m -XX:+UseContainerSupport']), 'v1 heap or Java override differs');
    invariant(labels['io.frwhoop.algorithm.version'] === 'frwhoop-server-1' &&
      labels['io.frwhoop.baseline.commit'] === BASELINE_COMMIT, 'v1 algorithm/baseline labels differ');
    invariant(labels['io.frwhoop.baseline.transport-sha256'] === provenance?.transport_patch_sha256 &&
      labels['io.frwhoop.baseline.identity-sha256'] === provenance?.identity_patch_sha256, 'v1 patch labels differ');
  } else if (role === 'shadow-v2') {
    invariant(labels['io.frwhoop.algorithm.roles'] === 'frwhoop-physiology-2,frwhoop-server-2-history',
      'v2 algorithm-role label differs');
  }
  if (role === 'intake') {
    invariant(labels['org.frwhoop.worker.role'] === 'intake' &&
      labels['org.frwhoop.intake.contract-version'] === '2' &&
      labels['io.frwhoop.runtime.image'] === INTAKE_RUNTIME_IMAGE &&
      labels['io.frwhoop.image.platform'] === PLATFORM, 'intake role/base/contract labels differ');
    invariant(config.config.User === 'deno' && config.config.WorkingDir === '/app' &&
      canonicalJSON(config.config.Entrypoint) === canonicalJSON(INTAKE_ENTRYPOINT) &&
      (config.config.Cmd == null || canonicalJSON(config.config.Cmd) === '[]'),
    'intake immutable runtime command/user differs');
  } else invariant(labels['io.frwhoop.heartbeat.contract'] === 'physiology_worker_heartbeats-v1' &&
    labels['io.frwhoop.database.ca.sha256'] === '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7' &&
    labels['io.frwhoop.build.image'] === BUILD_IMAGE && labels['io.frwhoop.runtime.image'] === RUNTIME_IMAGE &&
    labels['io.frwhoop.image.platform'] === PLATFORM, `${role} platform/base/heartbeat/database trust labels differ`);
  return {
    platform: PLATFORM,
    manifestDigest: expectedDigest,
    configDigest: expectedConfig,
    indexJsonSha256: sha256(indexBytes),
    sourceRevision,
    labels: Object.fromEntries(Object.entries(labels).sort()),
  };
}

export function parseAndroidBadging(text) {
  const first = text.split('\n').find(line => line.startsWith('package: '));
  const match = first?.match(/name='([^']+)' versionCode='([^']+)' versionName='([^']+)'/);
  invariant(match, 'aapt2 package identity missing');
  const min = text.match(/^sdkVersion:'([^']+)'$/m), target = text.match(/^targetSdkVersion:'([^']+)'$/m);
  invariant(min && target, 'aapt2 SDK identity missing');
  return { applicationId: match[1], versionCode: Number(match[2]), versionName: match[3],
    minSdk: Number(min[1]), targetSdk: Number(target[1]) };
}
export function parseAndroidReleaseMetadata(text, sourceRevision) {
  const blocks = [...text.matchAll(/^\s*E: meta-data[^\n]*\n((?:\s+A:[^\n]*\n?)+)/gm)].map(match => match[1]);
  const source = blocks.find(block => block.includes('"com.noop.release.source_revision"'));
  const hosted = blocks.find(block => block.includes('"com.noop.release.final_hosted_compute"'));
  invariant(source && source.includes(`"${sourceRevision}"`), 'APK embedded source revision differs');
  invariant(hosted && (/=true\b/.test(hosted) || hosted.includes('(Raw: "true")')), 'APK final-hosted marker differs');
  return { sourceRevision, finalHostedCompute: true };
}

function sourceBytes(repo, commit, filename) {
  return git(repo, 'show', `${commit}:${filename}`);
}
export function validateLaunchCapacity(value) {
  exactKeys(value, ['schemaVersion', 'decision', 'evidenceScope', 'targetVpsCapacity',
    'fleetCapacityReadiness', 'currentAdmission', 'publicationSlo', 'proposedInitialTopology',
    'databaseConnections', 'historicalScalarFixture', 'unsupportedClaims'], 'launch capacity');
  invariant(value.schemaVersion === 3 && value.decision === 'AWAITING_EXPLICIT_DEPLOYMENT_APPROVAL' &&
    value.evidenceScope === 'LOCAL_FIXTURES_AND_READ_ONLY_TARGET_SNAPSHOT' &&
    value.targetVpsCapacity === 'NOT_MEASURED' && value.fleetCapacityReadiness === 'FAIL',
  'target capacity and deployment approval remain unestablished');
  invariant(canonicalJSON(value.currentAdmission) === canonicalJSON({
    queueScope: 'EXPLICIT_ONE_OWNER_DEVICE_CANARY', ownerAllowlist: true,
    maxAdmittedOwners: 1, maxAdmittedDevices: 1, scopeIdentity: 'BOUND_PRIVATE_DEPLOYMENT_PLAN',
    safeActiveOwners: null, safeDevices: null, eligibleBacklog: 'REQUIRES_FRESH_SCOPED_PREDEPLOYMENT_COUNT',
  }), 'canary admission cap cannot claim measured owner or device capacity');
  invariant(canonicalJSON(value.publicationSlo) === canonicalJSON({
    percentile: 95, seconds: 10, origin: 'eligible input/window to selected VPS publication, including queue time',
    status: 'TARGET_NOT_MEASURED',
  }), 'publication target must retain the unmeasured shared-contract ten-second criterion');
  invariant(canonicalJSON(value.proposedInitialTopology) === canonicalJSON({
    status: 'PROPOSED_NOT_APPROVED_OR_CAPACITY_TESTED', services: [
      { service: 'intake-consumer', cpus: 1, memoryBytes: 2147483648 },
      { service: 'scoring-baseline-v1', cpus: 1, memoryBytes: 1073741824 },
    ], excludedServices: ['scoring-physiology-v2', 'scoring-history', 'optional-model-workers'],
    existingShadowQuiescence: 'REQUIRES_EXPLICIT_APPROVAL', admissionMode: 'canary',
  }), 'initial topology differs from the unapproved resource proposal');
  invariant(canonicalJSON(value.databaseConnections) === canonicalJSON({
    status: 'TARGET_BUDGET_NOT_MEASURED', selectedBaselinePoolSize: 6, intakeSerialRestLanes: 3,
    intakeTransport: 'SHARED_POSTGREST_NOT_THREE_DEDICATED_CONNECTIONS',
  }), 'intake REST demand cannot be counted as measured dedicated database connections');
  invariant(canonicalJSON(value.historicalScalarFixture) === canonicalJSON({
    evidenceScope: 'LOCAL_SCALAR_FIXTURE_ONLY', activeOwners: 10, devices: 20,
    physiologyWorkerProcesses: 4, publicationP95Seconds: 60, databaseConnectionBudget: 40,
    databaseConnectionReserve: 16, declaredProcessesIncludingReservedOptionalModel: 6,
    appliesToCurrentAdmission: false,
  }), 'historical scalar fixture must remain separate from current target admission');
  invariant(Array.isArray(value.unsupportedClaims) && value.unsupportedClaims.length === 1,
    'launch capacity unsupported-claim declaration differs');
  exactKeys(value.unsupportedClaims[0], ['activeOwners', 'status', 'reason'], 'launch capacity unsupported claim');
  invariant(value.unsupportedClaims[0].activeOwners === 1000 && value.unsupportedClaims[0].status === 'UNSUPPORTED' &&
    typeof value.unsupportedClaims[0].reason === 'string' && value.unsupportedClaims[0].reason.length > 0,
  '1,000-owner capacity must remain explicitly unsupported');
  return value;
}
function sourceContract(repo, commit) {
  const files = CONTRACT_FILES.map(filename => {
    const bytes = sourceBytes(repo, commit, filename);
    return { path: filename, sizeBytes: bytes.length, sha256: sha256(bytes) };
  });
  const text = filename => sourceBytes(repo, commit, filename).toString('utf8');
  invariant(sha256(sourceBytes(repo, commit, 'Tools/release/certificates/supabase-prod-ca-2021.crt')) ===
    '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7', 'committed database trust bytes differ');
  for (const [filename, tokens] of Object.entries({
    'android/app/build.gradle.kts': ['NOOP_SOURCE_REVISION', 'noopSourceRevision'],
    'android/app/src/main/AndroidManifest.xml': ['com.noop.release.source_revision', 'com.noop.release.final_hosted_compute'],
    'project.yml': ['NOOPSourceRevision: $(NOOP_SOURCE_REVISION)', 'NOOPFinalHostedCompute: true'],
    'scoring-service/Dockerfile': ['io.frwhoop.algorithm.roles=', 'io.frwhoop.heartbeat.contract='],
    'infra/vps/templates/Dockerfile.baseline': ['io.frwhoop.algorithm.version=', 'io.frwhoop.heartbeat.contract='],
    'infra/vps/templates/Dockerfile.intake': ['org.frwhoop.worker.role=intake',
      'org.frwhoop.intake.contract-version=2', INTAKE_RUNTIME_IMAGE],
    'supabase/functions/_shared/intakeConsumer.ts': ['INTAKE_CONTRACT_VERSION = 2', 'noop_intake_consumer_contract'],
    'scoring-service/service/src/main/kotlin/com/frwhoop/scoring/ScoringConfig.kt':
      ['SCORING_WORKER_SOURCE_REVISION'],
    'scoring-service/service/src/main/kotlin/com/frwhoop/scoring/health/HeartbeatReporter.kt':
      ['physiology_worker_heartbeats', 'source_revision', 'algorithm_version'],
    'supabase/migrations/20260919020000_physiology_worker_heartbeats.sql':
      ['physiology_worker_heartbeats', 'source_revision', 'algorithm_version'],
  })) for (const token of tokens) invariant(text(filename).includes(token), `${filename} lacks release contract ${token}`);
  const gradle = text('android/app/build.gradle.kts'), project = text('project.yml');
  validateLaunchCapacity(parseJSONBytes(sourceBytes(repo, commit, 'infra/vps/launch-capacity.json'),
    'launch capacity declaration'));
  const androidVersion = gradle.match(/versionName\s*=\s*"([^"]+)"/)?.[1];
  const androidBuild = Number(gradle.match(/versionCode\s*=\s*([0-9]+)/)?.[1]);
  const appleVersion = project.match(/MARKETING_VERSION:\s*"([^"]+)"/)?.[1];
  const appleBuild = project.match(/CURRENT_PROJECT_VERSION:\s*"([0-9]+)"/)?.[1];
  invariant(androidVersion && Number.isSafeInteger(androidBuild) && appleVersion && appleBuild, 'mobile build identity is unavailable');
  return { files, versions: { androidVersion, androidBuild, appleVersion, appleBuild } };
}

function validateInput(input) {
  exactKeys(input, ['schemaVersion', 'sourceSha', 'expected', 'artifacts'], 'release input');
  invariant(input.schemaVersion === 1 && REVISION.test(input.sourceSha), 'release input source SHA differs');
  validateIOSExpectedIdentities(input.expected);
  exactKeys(input.artifacts, ['selectedV1', 'shadowV2', 'intake', 'android', 'ios', 'edge', 'migrations', 'deployment'], 'release artifacts');
  exactKeys(input.artifacts.selectedV1, ['oci', 'buildMetadata', 'provenance'], 'selected v1 input');
  exactKeys(input.artifacts.shadowV2, ['oci', 'buildMetadata'], 'shadow v2 input');
  exactKeys(input.artifacts.intake, ['oci', 'buildMetadata'], 'intake input');
  exactKeys(input.artifacts.android, ['apk', 'outputMetadata', 'aapt2', 'apksigJar'], 'Android input');
  exactKeys(input.artifacts.ios, ['ipa'], 'iOS input');
  exactKeys(input.artifacts.edge, ['bundle', 'manifest'], 'Edge input');
  exactKeys(input.artifacts.migrations, ['manifest'], 'migration input');
  exactKeys(input.artifacts.deployment, ['bundle', 'manifest'], 'deployment input');
  for (const group of Object.values(input.artifacts)) for (const value of Object.values(group)) relative(value);
  return input;
}
export function validateIOSExpectedIdentities(value) {
  exactKeys(value, ['iosAppGroup', 'iosBundleIdentifiers'], 'release expected identities');
  invariant(Array.isArray(value.iosBundleIdentifiers) && value.iosBundleIdentifiers.length === 4 &&
    new Set(value.iosBundleIdentifiers).size === 4, 'four iOS bundle identities required');
  const phone = value.iosBundleIdentifiers.filter(identifier =>
    typeof identifier === 'string' && identifier.endsWith('.noop'));
  invariant(phone.length === 1, 'iOS phone bundle identity does not match the committed project topology');
  const prefix = phone[0].slice(0, -'.noop'.length);
  invariant(/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(prefix), 'iOS bundle prefix is invalid');
  const expectedBundles = [
    `${prefix}.noop`,
    `${prefix}.noop.widgets`,
    `${prefix}.noop.watch`,
    `${prefix}.noop.watch.complications`,
  ].sort();
  invariant(canonicalJSON([...value.iosBundleIdentifiers].sort()) === canonicalJSON(expectedBundles) &&
    value.iosAppGroup === `group.${prefix}.noop.staging`,
  'iOS bundle/App Group identities do not match the committed project topology');
  return value;
}
function validateV1Provenance(value, repo, sourceRevision) {
  invariant(value?.baseline_commit === BASELINE_COMMIT && value.algorithm_version === 'frwhoop-server-1' &&
    value.canonical_math_changed === false && value.build_status === 'built_and_repository_tests_passed' &&
    value.database_integration_environment === true && value.deployment_status === 'not_deployed',
    'v1 build/test provenance is incomplete');
  invariant(value?.image_build?.platform === PLATFORM && value.image_build.build_image === BUILD_IMAGE &&
    value.image_build.runtime_image === RUNTIME_IMAGE, 'v1 image inputs differ');
  invariant(value.database_ca_sha256 === '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7' &&
    value.database_ca_source_path === 'Tools/release/certificates/supabase-prod-ca-2021.crt' &&
    value.database_ca_runtime_path === '/opt/frwhoop/supabase-prod-ca-2021.crt', 'v1 public database trust provenance differs');
  invariant(SHA256.test(value.transport_patch_sha256) && SHA256.test(value.identity_patch_sha256) &&
    SHA256.test(value.frozen_files_sha256) && SHA256.test(value.baseline_result_mapper_sha256),
    'v1 source provenance hashes are invalid');
  invariant(value.transport_patch_sha256 === sha256(sourceBytes(repo, sourceRevision,
    'scoring-service/legacy-baseline/transport.patch')) &&
    value.identity_patch_sha256 === sha256(sourceBytes(repo, sourceRevision,
      'scoring-service/legacy-baseline/runtime-identity.patch')), 'v1 committed patch hashes differ');
  return value;
}
export function validateMigrationManifest(value, repo, commit, tree) {
  exactKeys(value, ['schemaVersion', 'kind', 'candidate', 'sourceWorkstreams', 'hostedBaseline', 'catalog',
    'counts', 'schemaFingerprintSha256', 'entries', 'manifestFingerprintSha256'], 'migration manifest');
  exactKeys(value.candidate, ['branch', 'sha', 'tree'], 'migration candidate');
  exactKeys(value.hostedBaseline, ['environment', 'projectRef', 'capturedAt', 'nativeLedgerRows',
    'fullIdentityRows', 'highestKnownIdentity', 'evidenceArtifacts'], 'migration hosted baseline');
  exactKeys(value.catalog, ['path', 'migrationDirectory', 'entryCount', 'baselineEntryCount',
    'pendingEntryCount'], 'migration catalog');
  exactKeys(value.counts, ['total', 'applied', 'pending'], 'migration counts');
  invariant(value.schemaVersion === 1 && value.kind === 'frwhoop-immutable-migration-manifest' &&
    value.candidate.branch === 'repair/vps-server-20260922' && value.candidate.sha === commit &&
    value.candidate.tree === tree, 'migration manifest source differs');
  invariant(canonicalJSON(value.sourceWorkstreams) === canonicalJSON(MIGRATION_WORKSTREAMS.map(row => ({ ...row, tip: row.tip ?? commit }))),
    'migration source workstreams differ');
  invariant(value.hostedBaseline.environment === 'hosted-production' &&
    value.hostedBaseline.projectRef === 'sgoyxzcagqyxexmsidtk' &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value.hostedBaseline.capturedAt) &&
    !Number.isNaN(Date.parse(value.hostedBaseline.capturedAt)) &&
    value.hostedBaseline.nativeLedgerRows === 110 && value.hostedBaseline.fullIdentityRows === MIGRATION_BASELINE &&
    value.hostedBaseline.highestKnownIdentity === '20260921104000_server_unrepresentable_clock.sql',
  'migration hosted baseline differs');
  invariant(Array.isArray(value.hostedBaseline.evidenceArtifacts) &&
    value.hostedBaseline.evidenceArtifacts.length > 0, 'migration hosted evidence is missing');
  const evidenceLabels = new Set();
  for (const [index, artifact] of value.hostedBaseline.evidenceArtifacts.entries()) {
    exactKeys(artifact, ['label', 'path', 'sha256'], `migration hosted evidence ${index + 1}`);
    invariant(typeof artifact.label === 'string' && artifact.label.length > 0 &&
      typeof artifact.path === 'string' && artifact.path.length > 0 && SHA256.test(artifact.sha256) &&
      !evidenceLabels.has(artifact.label), `migration hosted evidence ${index + 1} differs`);
    evidenceLabels.add(artifact.label);
  }
  invariant(value.catalog.path === MIGRATION_CATALOG_PATH && value.catalog.migrationDirectory === MIGRATION_DIRECTORY &&
    value.catalog.entryCount === MIGRATION_TOTAL && value.catalog.baselineEntryCount === MIGRATION_BASELINE &&
    value.catalog.pendingEntryCount === MIGRATION_TOTAL - MIGRATION_BASELINE &&
    value.counts.total === MIGRATION_TOTAL && value.counts.applied === MIGRATION_BASELINE &&
    value.counts.pending === MIGRATION_TOTAL - MIGRATION_BASELINE, 'migration counts differ');
  invariant(SHA256.test(value.schemaFingerprintSha256) && SHA256.test(value.manifestFingerprintSha256),
    'migration fingerprints are invalid');

  const catalog = parseJSONBytes(sourceBytes(repo, commit, MIGRATION_CATALOG_PATH), 'committed migration catalog');
  invariant(Array.isArray(catalog) && catalog.length === MIGRATION_TOTAL && Array.isArray(value.entries) &&
    value.entries.length === MIGRATION_TOTAL, `migration manifest must contain exactly ${MIGRATION_TOTAL} entries`);
  const migrationPaths = git(repo, 'ls-tree', '-r', '--name-only', '-z', commit, '--', MIGRATION_DIRECTORY)
    .toString('utf8').split('\0').filter(Boolean).filter(filename => filename.endsWith('.sql'));
  const expectedPaths = catalog.map(row => `${MIGRATION_DIRECTORY}/${row.basename}`).sort();
  invariant(canonicalJSON([...migrationPaths].sort()) === canonicalJSON(expectedPaths),
    'committed migration source set differs from the catalog');
  const timestampGroups = new Map();
  for (const row of catalog) {
    exactKeys(row, ['basename', 'sha256'], `committed migration catalog entry ${row.basename ?? 'unknown'}`);
    invariant(/^[0-9]{14}_[a-z0-9_]+\.sql$/.test(row.basename) && SHA256.test(row.sha256),
      'committed migration catalog entry is invalid');
    const timestamp = row.basename.slice(0, 14);
    timestampGroups.set(timestamp, [...(timestampGroups.get(timestamp) ?? []), row.basename]);
  }
  const workstreamAt = index => {
    const name = index < MIGRATION_BASELINE ? 'server-pipeline'
      : index < 121 ? 'multiuser-scale' : index === 121 ? 'sensor-algorithms'
      : index < 124 ? 'vps-only-compute' : index < 126 ? 'persistent-sync-followup' : 'server-repair';
    const row = MIGRATION_WORKSTREAMS.find(item => item.workstream === name);
    return { ...row, tip: row.tip ?? commit };
  };
  const renamed = new Map([
    ['20260921121000_final_hosted_compute_contract.sql',
      ['20260921110000_final_hosted_compute_contract.sql', '20260921110000_installation_retirement.sql']],
    ['20260921122000_compute_session_requests.sql',
      ['20260921111000_compute_session_requests.sql', '20260921111000_wearable_lifecycle.sql']],
  ]);
  for (const [index, entry] of value.entries.entries()) {
    const row = catalog[index], ordinal = index + 1, filename = row.basename;
    exactKeys(entry, ['ordinal', 'filename', 'stableIdentity', 'timestamp', 'sha256', 'sizeBytes',
      'sourceWorkstream', 'sourceBranch', 'sourceTip', 'dependencies', 'collisionRenameState', 'hostedStatus',
      'hostedIdentityState', 'freshInstallBehavior', 'upgradeBehavior'], `migration entry ${ordinal}`);
    const bytes = sourceBytes(repo, commit, `${MIGRATION_DIRECTORY}/${filename}`);
    invariant(entry.ordinal === ordinal && entry.filename === filename && entry.stableIdentity === filename &&
      entry.timestamp === filename.slice(0, 14) && entry.sha256 === row.sha256 && entry.sha256 === sha256(bytes) &&
      entry.sizeBytes === bytes.length, `migration entry ${ordinal} source identity differs`);
    const source = workstreamAt(index);
    invariant(entry.sourceWorkstream === source.workstream && entry.sourceBranch === source.branch &&
      entry.sourceTip === source.tip, `migration entry ${ordinal} workstream differs`);
    invariant(canonicalJSON(entry.dependencies) === canonicalJSON(index === 0 ? [] : [catalog[index - 1].basename]),
      `migration entry ${ordinal} apply order differs`);

    const rename = renamed.get(filename), peers = timestampGroups.get(entry.timestamp);
    if (rename) {
      exactKeys(entry.collisionRenameState, ['state', 'proposedStableIdentity', 'proposedTimestamp',
        'collidedWithStableIdentity', 'reason'], `migration entry ${ordinal} collision state`);
      invariant(entry.collisionRenameState.state === 'renamed_before_application' &&
        entry.collisionRenameState.proposedStableIdentity === rename[0] &&
        entry.collisionRenameState.proposedTimestamp === rename[0].slice(0, 14) &&
        entry.collisionRenameState.collidedWithStableIdentity === rename[1],
      `migration entry ${ordinal} rename state differs`);
    } else if (peers.length > 1) {
      exactKeys(entry.collisionRenameState, ['state', 'peerStableIdentities', 'reason'],
        `migration entry ${ordinal} collision state`);
      invariant(entry.collisionRenameState.state === 'historical_timestamp_collision' &&
        canonicalJSON(entry.collisionRenameState.peerStableIdentities) ===
          canonicalJSON(peers.filter(identity => identity !== filename)),
      `migration entry ${ordinal} collision state differs`);
    } else {
      exactKeys(entry.collisionRenameState, ['state'], `migration entry ${ordinal} collision state`);
      invariant(entry.collisionRenameState.state === 'unique', `migration entry ${ordinal} collision state differs`);
    }
    if ('reason' in entry.collisionRenameState)
      invariant(typeof entry.collisionRenameState.reason === 'string' && entry.collisionRenameState.reason.length > 0,
        `migration entry ${ordinal} collision reason is missing`);

    const applied = index < MIGRATION_BASELINE;
    const identityStateKeys = entry.hostedIdentityState?.supersededBy === undefined ? ['state', 'reason'] :
      ['state', 'reason', 'supersededBy'];
    exactKeys(entry.hostedIdentityState, identityStateKeys, `migration entry ${ordinal} hosted identity state`);
    const expectedIdentityState = !applied ? 'not_applied'
      : filename === '20260918234000_motion_evidence_provenance.sql' ? 'superseded_in_hosted_schema' : 'active';
    invariant(entry.hostedStatus === (applied ? 'applied' : 'pending') &&
      entry.hostedIdentityState.state === expectedIdentityState &&
      typeof entry.hostedIdentityState.reason === 'string' && entry.hostedIdentityState.reason.length > 0,
    `migration entry ${ordinal} hosted state differs`);
    if (entry.hostedIdentityState.supersededBy !== undefined) invariant(
      expectedIdentityState === 'superseded_in_hosted_schema' &&
      catalog.slice(0, MIGRATION_BASELINE).some(candidate => candidate.basename === entry.hostedIdentityState.supersededBy),
    `migration entry ${ordinal} superseding identity differs`);
    exactKeys(entry.freshInstallBehavior, ['action', 'applyOrdinal', 'verifySha256'],
      `migration entry ${ordinal} fresh-install behavior`);
    invariant(entry.freshInstallBehavior.action === 'apply_exact_source_once' &&
      entry.freshInstallBehavior.applyOrdinal === ordinal && entry.freshInstallBehavior.verifySha256 === true,
    `migration entry ${ordinal} fresh-install behavior differs`);
    exactKeys(entry.upgradeBehavior, applied ? ['action', 'execute', 'reason'] :
      ['action', 'execute', 'upgradeOrdinal', 'reason'], `migration entry ${ordinal} upgrade behavior`);
    invariant(entry.upgradeBehavior.action === (applied ? 'preserve_applied_identity' : 'apply_exact_source_once') &&
      entry.upgradeBehavior.execute === !applied &&
      (applied || entry.upgradeBehavior.upgradeOrdinal === ordinal - MIGRATION_BASELINE) &&
      typeof entry.upgradeBehavior.reason === 'string' && entry.upgradeBehavior.reason.length > 0,
    `migration entry ${ordinal} upgrade behavior differs`);
  }
  const schemaPayload = 'frwhoop-migration-schema-v1\n' + catalog.map((row, index) =>
    `${index + 1}\0${row.basename}\0${row.sha256}\n`).join('');
  invariant(value.schemaFingerprintSha256 === MIGRATION_SCHEMA_FINGERPRINT &&
    value.schemaFingerprintSha256 === sha256(schemaPayload), 'migration schema fingerprint differs');
  const { manifestFingerprintSha256, ...unsigned } = value;
  invariant(sha256(canonicalJSON(unsigned)) === manifestFingerprintSha256, 'migration manifest fingerprint differs');
  return { schemaFingerprintSha256: value.schemaFingerprintSha256,
    manifestFingerprintSha256, total: MIGRATION_TOTAL, applied: MIGRATION_BASELINE,
    pending: MIGRATION_TOTAL - MIGRATION_BASELINE };
}
function validateEdgeManifest(value, commit, tree, bundleIdentity) {
  exactKeys(value, ['schemaVersion', 'kind', 'source', 'bundle', 'includedRoots', 'exclusionPolicy',
    'deployableFunctions', 'files'], 'Edge manifest');
  exactKeys(value.source, ['commit', 'tree'], 'Edge source');
  exactKeys(value.bundle, ['filename', 'sha256', 'sizeBytes'], 'Edge bundle');
  invariant(value?.schemaVersion === 1 && value.kind === 'frwhoop-edge-bundle' &&
    value.source?.commit === commit && value.source.tree === tree, 'Edge bundle source differs');
  invariant(JSON.stringify([...value.deployableFunctions].sort()) === JSON.stringify(EDGE_FUNCTIONS), 'Edge function roles differ');
  invariant(value.bundle?.sha256 === bundleIdentity.sha256 && value.bundle.sizeBytes === bundleIdentity.sizeBytes &&
    value.bundle.filename === path.basename(bundleIdentity.path), 'Edge bundle identity differs');
  invariant(Array.isArray(value.files) && value.files.some(file => file.path === 'supabase/functions/deno.lock') &&
    value.files.some(file => file.path === 'supabase/functions/scores/index.ts'), 'Edge lockfile/scores source missing');
  return { deployableFunctions: EDGE_FUNCTIONS, fileCount: value.files.length };
}
function validateDeploymentManifest(value, commit, tree, bundleIdentity) {
  exactKeys(value, ['schemaVersion', 'kind', 'source', 'bundle', 'includedRoots',
    'requiredCapabilities', 'files'], 'deployment manifest');
  invariant(value.schemaVersion === 1 && value.kind === 'frwhoop-deployment-source-bundle' &&
    value.source?.commit === commit && value.source.tree === tree, 'deployment bundle source differs');
  invariant(value.bundle?.sha256 === bundleIdentity.sha256 && value.bundle.sizeBytes === bundleIdentity.sizeBytes &&
    value.bundle.filename === path.basename(bundleIdentity.path), 'deployment bundle identity differs');
  invariant(Array.isArray(value.files) && value.files.length > 0 &&
    value.files.some(file => file.path === 'infra/vps/scripts/deploy-scoring-service.sh') &&
    value.files.some(file => file.path === 'infra/vps/scripts/apply-migrations.sh') &&
    value.files.some(file => file.path === 'Tools/release/hosted-migration-release.mjs') &&
    value.files.some(file => file.path === 'infra/vps/scripts/deploy-hosted-edge-functions.mjs') &&
    value.files.some(file => file.path === 'infra/vps/scripts/verify-hosted-score-route-parity.mjs') &&
    value.files.some(file => file.path === 'infra/vps/scripts/remote/verify-scoring-runtime.sh') &&
    value.files.some(file => file.path === 'infra/vps/templates/Dockerfile.intake') &&
    value.files.some(file => file.path === INTAKE_COMPOSE_PATH) &&
    value.files.some(file => file.path === 'Tools/release/release-artifact-manifest.mjs'),
  'deployment bundle lacks required release/rollback sources');
  return { requiredCapabilities: value.requiredCapabilities, fileCount: value.files.length };
}
export function verifyBundleMatchesCommittedSource(repo, commit, provided, kind) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), `frwhoop-${kind}-source-`));
  const output = path.join(temporary, 'bundle');
  try {
    const generated = kind === 'edge'
      ? prepareEdgeSourceBundle({ repoRoot: repo, commitSha: commit, outputDirectory: output })
      : prepareDeploymentSourceBundle({ repoRoot: repo, commit, outputDirectory: output });
    invariant(canonicalJSON(generated) === canonicalJSON(provided),
      `${kind} bundle differs from deterministic committed source`);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}
export function verifyAndroidInspectionTools(value) {
  exactKeys(value, ['aapt2', 'apksigJar'], 'Android inspection tools');
  exactKeys(value.aapt2, ['file', 'version'], 'aapt2 identity');
  exactKeys(value.apksigJar, ['file'], 'apksig identity');
  for (const [name, identity] of Object.entries(value)) {
    exactKeys(identity.file, ['path', 'sizeBytes', 'sha256'], `${name} file identity`);
    relative(identity.file.path, `${name} artifact path`);
    invariant(Number.isSafeInteger(identity.file.sizeBytes) && identity.file.sizeBytes > 0 &&
      identity.file.sha256 === ANDROID_INSPECTION_TOOLS[name].sha256,
    `${name} bytes differ from reviewed Android SDK build-tools 34.0.0`);
  }
  invariant(value.aapt2.version === ANDROID_INSPECTION_TOOLS.aapt2.version,
    'aapt2 version differs from reviewed Android SDK build-tools 34.0.0');
  return value;
}
function inspectAndroid(repo, commit, root, value, versions) {
  const apk = fileIdentity(root, value.apk), metadataFile = fileIdentity(root, value.outputMetadata);
  const apkPath = artifactFile(root, value.apk), aapt2 = artifactFile(root, value.aapt2);
  const apksig = artifactFile(root, value.apksigJar);
  const aapt2File = fileIdentity(root, value.aapt2), apksigFile = fileIdentity(root, value.apksigJar);
  invariant(aapt2File.sha256 === ANDROID_INSPECTION_TOOLS.aapt2.sha256 &&
    apksigFile.sha256 === ANDROID_INSPECTION_TOOLS.apksigJar.sha256,
  'Android inspection tool bytes differ from reviewed SDK build-tools 34.0.0');
  const tools = verifyAndroidInspectionTools({
    aapt2: { file: aapt2File, version: inspectAapt2Version(aapt2) },
    apksigJar: { file: apksigFile },
  });
  const badging = run(aapt2, ['dump', 'badging', apkPath]).toString('utf8');
  const xml = run(aapt2, ['dump', 'xmltree', apkPath, '--file', 'AndroidManifest.xml']).toString('utf8');
  const identity = parseAndroidBadging(badging), release = parseAndroidReleaseMetadata(xml, commit);
  invariant(identity.applicationId === 'com.noop.whoop.staging' &&
    identity.versionCode === versions.androidBuild && identity.versionName === `${versions.androidVersion}-staging` &&
    identity.minSdk === 26 && identity.targetSdk === 34, 'Android package/build identity differs');
  const output = boundedJSON(artifactFile(root, value.outputMetadata));
  invariant(output?.version === 3 && output.applicationId === identity.applicationId && output.variantName === 'fullRelease' &&
    output.elements?.length === 1 && output.elements[0].outputFile === path.basename(value.apk) &&
    output.elements[0].versionCode === identity.versionCode && output.elements[0].versionName === identity.versionName,
    'Android Gradle output metadata differs');
  const helper = path.join(repo, 'Tools/release/VerifyApk.java');
  const signature = parseJSONBytes(run('java', ['-cp', apksig, helper, apkPath]), 'APK signature inspection');
  invariant(signature.verified === true && signature.certificateSha256?.length === 1, 'APK signature differs');
  const keyOutput = run('keytool', ['-list', '-v', '-keystore', path.join(repo, 'android/fork-debug.keystore'),
    '-storepass', 'android', '-alias', 'androiddebugkey']).toString('utf8');
  const expectedCertificate = keyOutput.match(/SHA256:\s*([0-9A-F:]+)/)?.[1]?.replaceAll(':', '').toLowerCase();
  invariant(SHA256.test(expectedCertificate) && signature.certificateSha256[0] === expectedCertificate,
    'APK signer is not the committed staging key');
  return { kind: 'android-staging-apk', file: apk, outputMetadata: metadataFile, package: identity, release, signature,
    tools };
}
function inspectIOS(repo, commit, root, value, expected, versions) {
  const file = fileIdentity(root, value.ipa), filename = artifactFile(root, value.ipa);
  const inspection = parseJSONBytes(run('python3', [path.join(repo, 'Tools/release/inspect_ipa.py'), filename],
    { maxBuffer: 128 * 1024 * 1024 }), 'IPA inspection');
  invariant(Array.isArray(inspection.bundles) && inspection.bundles.length === 4, 'IPA must contain phone/widget/watch/complication bundles');
  const actualIDs = inspection.bundles.map(bundle => bundle.bundleIdentifier).sort();
  invariant(JSON.stringify(actualIDs) === JSON.stringify([...expected.iosBundleIdentifiers].sort()), 'IPA bundle identifiers differ');
  const teams = new Set();
  for (const bundle of inspection.bundles) {
    invariant(bundle.version === versions.appleVersion && bundle.build === versions.appleBuild &&
      bundle.finalHostedCompute === true, `IPA version/final-hosted marker differs: ${bundle.bundleIdentifier}`);
    const isPhone = bundle.path.split('/').length === 2;
    invariant(isPhone ? bundle.sourceRevision === commit : bundle.sourceRevision == null,
      `IPA source revision placement differs: ${bundle.bundleIdentifier}`);
    invariant(bundle.signature?.identifier === bundle.bundleIdentifier && bundle.signature.cdhash &&
      bundle.profile?.applicationIdentifier?.endsWith(`.${bundle.bundleIdentifier}`) &&
      bundle.profile.deviceCount > 0 && bundle.profile.getTaskAllow === true,
      `IPA signature/profile differs: ${bundle.bundleIdentifier}`);
    invariant(JSON.stringify(bundle.signature.entitlements?.applicationGroups ?? []) ===
      JSON.stringify([expected.iosAppGroup]) &&
      JSON.stringify(bundle.profile.applicationGroups ?? []) === JSON.stringify([expected.iosAppGroup]),
      `IPA App Group differs: ${bundle.bundleIdentifier}`);
    teams.add(bundle.signature.teamIdentifier); teams.add(bundle.profile.teamIdentifier);
  }
  invariant(teams.size === 1, 'IPA bundles do not share one signing team');
  return { kind: 'ios-development-ipa', file, version: versions.appleVersion, build: versions.appleBuild,
    sourceRevision: commit, signingTeam: [...teams][0], appGroup: expected.iosAppGroup,
    bundles: inspection.bundles.sort((a, b) => a.bundleIdentifier.localeCompare(b.bundleIdentifier)) };
}
function roleContract(commit) {
  const heartbeat = { table: 'physiology_worker_heartbeats', contract: 'physiology_worker_heartbeats-v1',
    sourceRevision: commit, requiredProgress: ['last_poll_at', 'last_score_at'], processIdentityRequired: true };
  return {
    selectedV1: { imageArtifact: 'selectedV1', algorithmVersion: 'frwhoop-server-1',
      publicationRole: 'selected', heartbeat },
    shadowV2: { imageArtifact: 'shadowV2', algorithmVersion: 'frwhoop-physiology-2',
      publicationRole: 'shadow', heartbeat },
    intake: { imageArtifact: 'intake', contractVersion: 2, sourceRevision: commit,
      publicationRole: 'verified-indexed-input', lanes: ['verification', 'projection', 'legacy'],
      asyncAdmission: 'DISABLED_UNTIL_SEPARATELY_AUTHORIZED', progressTable: 'noop_intake_consumers' },
    historyV2: { imageArtifact: 'shadowV2', algorithmVersion: 'frwhoop-server-2-history',
      publicationRole: 'shadow-history', command: ['--history'], heartbeat },
  };
}

const workerLaneOrder = [
  { service: 'intake-consumer', contractVersion: 2,
    publicationRole: 'verified-indexed-input', imageRole: 'intake' },
  { service: 'scoring-baseline-v1', algorithmVersion: 'frwhoop-server-1',
    publicationRole: 'selected', imageRole: 'selectedV1' },
  { service: 'scoring-physiology-v2', algorithmVersion: 'frwhoop-physiology-2',
    publicationRole: 'shadow', imageRole: 'shadowV2' },
  { service: 'scoring-history', algorithmVersion: 'frwhoop-server-2-history',
    publicationRole: 'shadow-history', imageRole: 'shadowV2', command: ['--history'] },
];

function registryImage(reference, image, label) {
  invariant(REGISTRY_DIGEST_REFERENCE.test(reference), `${label} registry reference must be digest-pinned`);
  invariant(DIGEST.test(image?.manifestDigest) && DIGEST.test(image?.configDigest) && image.platform === PLATFORM,
    `${label} OCI identity is incomplete`);
  invariant(reference.endsWith(`@${image.manifestDigest}`), `${label} registry reference differs from OCI manifest digest`);
  return { reference, manifestDigest: image.manifestDigest, configDigest: image.configDigest };
}

function sshFingerprint(bytes) {
  return `SHA256:${crypto.createHash('sha256').update(bytes).digest('base64').replace(/=+$/, '')}`;
}

function reviewedSshPublicKey(line, fingerprint) {
  invariant(typeof line === 'string' && line.length <= 16 * 1024 && !/[\r\n\0]/.test(line),
    'target SSH host public-key line is invalid');
  const fields = line.split(' ');
  invariant(fields.length === 2 && fields[0] === 'ssh-ed25519' &&
    /^[A-Za-z0-9+/]+={0,2}$/.test(fields[1]), 'target SSH host public-key line must contain exactly type and key');
  let blob;
  try { blob = Buffer.from(fields[1], 'base64'); } catch { invariant(false, 'target SSH host public key is not base64'); }
  invariant(blob.length >= 8 && blob.toString('base64') === fields[1], 'target SSH host public key is not canonical base64');
  const typeLength = blob.readUInt32BE(0);
  invariant(typeLength > 0 && typeLength <= blob.length - 4 &&
    blob.subarray(4, 4 + typeLength).toString('ascii') === fields[0], 'target SSH host public-key type differs from its blob');
  const keyLengthOffset = 4 + typeLength;
  invariant(blob.length === keyLengthOffset + 4 + 32 && blob.readUInt32BE(keyLengthOffset) === 32,
    'target SSH host public key must be a complete Ed25519 key');
  invariant(/^SHA256:[A-Za-z0-9+/]{43}$/.test(fingerprint) && sshFingerprint(blob) === fingerprint,
    'target SSH host public-key fingerprint differs');
  return { type: fields[0], line, fingerprint };
}

function reviewedTarget(value) {
  invariant(isObject(value), 'reviewed target identity is required');
  const ip = value.ip;
  const port = typeof value.sshPort === 'string' && /^[0-9]+$/.test(value.sshPort)
    ? Number(value.sshPort) : value.sshPort;
  invariant(typeof ip === 'string' && ip.length <= 15 && net.isIP(ip) === 4,
    'target must be a canonical literal IPv4 address');
  invariant(Number.isSafeInteger(port) && port >= 1 && port <= 65535, 'target SSH port is invalid');
  invariant(/^SHA256:[A-Za-z0-9+/]{43}$/.test(value.deployPublicKeyFingerprint),
    'deploy public-key fingerprint is invalid');
  return {
    ip,
    sshPort: port,
    sshHostPublicKey: reviewedSshPublicKey(value.sshHostPublicKeyLine, value.sshHostPublicKeyFingerprint),
    deployPublicKeyFingerprint: value.deployPublicKeyFingerprint,
  };
}

function postgresClientContract(value) {
  invariant(canonicalJSON(value) === canonicalJSON(POSTGRES_CLIENT), 'PostgreSQL client OCI identity differs');
  return structuredClone(POSTGRES_CLIENT);
}

export function validateAdmission(value) {
  invariant(isObject(value), 'explicit worker admission is required');
  if (value.mode === 'all-eligible') {
    exactKeys(value, ['mode'], 'all-eligible admission');
  } else {
    exactKeys(value, ['mode', 'ownerId', 'deviceId'], 'canary admission');
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
    invariant(value.mode === 'canary' && typeof value.ownerId === 'string' && typeof value.deviceId === 'string' &&
      uuid.test(value.ownerId) && uuid.test(value.deviceId),
      'complete canonical canary scope required');
  }
  return structuredClone(value);
}

export function readPrivateJSON(filename) {
  // Descriptor checks keep a renamed/symlinked path from substituting public/private plan bytes.
  let descriptor;
  try {
    descriptor = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const stat = fs.fstatSync(descriptor);
    invariant(stat.isFile() && (stat.mode & 0o077) === 0 && stat.uid === process.getuid() &&
      stat.size > 0 && stat.size <= 1024 * 1024, 'private deployment file ownership, mode or size differs');
    return JSON.parse(fs.readFileSync(descriptor, 'utf8'));
  } catch {
    invariant(false, 'private deployment file is invalid; require owned regular 0600/0400 JSON');
  } finally { if (descriptor !== undefined) fs.closeSync(descriptor); }
}

export function admissionEnvironment(value, prefix) {
  const admission = validateAdmission(value);
  invariant(['INTAKE', 'SCORING'].includes(prefix), 'admission environment prefix differs');
  if (prefix === 'SCORING' && admission.mode === 'all-eligible') return { SCORING_ADMISSION_MODE: admission.mode };
  return { [`${prefix}_ADMISSION_MODE`]: admission.mode,
    // Empty values deliberately override stale ambient/env-file scope for explicit all-eligible.
    [`${prefix}_CANARY_OWNER_ID`]: admission.mode === 'canary' ? admission.ownerId : '',
    [`${prefix}_CANARY_DEVICE_ID`]: admission.mode === 'canary' ? admission.deviceId : '' };
}

export function intakeComposeContract(reference, sourceRevision, instanceId, projectRef, admission) {
  const environment = admissionEnvironment(admission, 'INTAKE');
  invariant(REGISTRY_DIGEST_REFERENCE.test(reference) && REVISION.test(sourceRevision),
    'intake Compose image/source identity is invalid');
  invariant(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(instanceId) &&
    projectRef === INTAKE_PROJECT, 'intake deployment instance/project identity differs');
  return { name: 'frwhoop-intake', services: { 'intake-consumer': {
    image: reference, container_name: 'intake-consumer', restart: admission.mode === 'canary' ? 'no' : 'unless-stopped', init: true,
    cpus: 1, mem_limit: '2147483648', pids_limit: 128, read_only: true,
    tmpfs: ['/tmp:rw,noexec,nosuid,size=64m'], cap_drop: ['ALL'], security_opt: ['no-new-privileges:true'],
    env_file: [{ path: '/opt/frwhoop/intake.env', required: true }, { path: '/opt/frwhoop/b2.env', required: true }],
    environment: { INTAKE_WORKER_SOURCE_REVISION: sourceRevision, INTAKE_WORKER_INSTANCE_ID: instanceId,
      INTAKE_EXPECTED_SUPABASE_PROJECT: projectRef, ...environment, RAW_STORE: 'b2' },
    command: [], entrypoint: null, network_mode: 'bridge', stop_grace_period: '5m0s',
    logging: { driver: 'json-file', options: { 'max-size': '10m', 'max-file': '3' } },
  } } };
}

// Compile committed bytes with nonsecret probe files. Compose versions can resolve env_file even
// with --no-env-resolution, so this never exposes deployed credentials to the packaging process.
// The two probe keys prove both files were included; only their reviewed runtime paths are bound.
export function compileIntakeCompose({ repoRoot, commit, reference, instanceId, projectRef, admission }) {
  const expected = intakeComposeContract(reference, commit, instanceId, projectRef, admission);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'frwhoop-intake-compose-'));
  try {
    const template = path.join(directory, 'compose.yml');
    fs.writeFileSync(template, sourceBytes(repoRoot, commit, INTAKE_COMPOSE_PATH));
    fs.writeFileSync(path.join(directory, 'intake.env'), 'FRWHOOP_RELEASE_INTAKE_PROBE=intake\n');
    fs.writeFileSync(path.join(directory, 'b2.env'), 'FRWHOOP_RELEASE_B2_PROBE=b2\n');
    const compiled = parseJSONBytes(run('docker', ['compose', '-p', 'frwhoop-intake', '-f', template,
      'config', '--format', 'json'], { cwd: directory, privateOutput: true, env: {
      PATH: process.env.PATH, INTAKE_WORKER_IMAGE: reference, INTAKE_WORKER_SOURCE_REVISION: commit,
      INTAKE_WORKER_INSTANCE_ID: instanceId, INTAKE_EXPECTED_SUPABASE_PROJECT: projectRef,
      ...admissionEnvironment(admission, 'INTAKE'),
      INTAKE_RESTART_POLICY: admission.mode === 'canary' ? 'no' : 'unless-stopped',
      INTAKE_WORKER_ENV_FILE: path.join(directory, 'intake.env'), INTAKE_B2_ENV_FILE: path.join(directory, 'b2.env'),
    } }), 'compiled intake Compose');
    const service = compiled?.services?.['intake-consumer'];
    invariant(service?.environment?.FRWHOOP_RELEASE_INTAKE_PROBE === 'intake' &&
      service.environment.FRWHOOP_RELEASE_B2_PROBE === 'b2', 'intake Compose env-file bindings differ');
    delete service.environment.FRWHOOP_RELEASE_INTAKE_PROBE;
    delete service.environment.FRWHOOP_RELEASE_B2_PROBE;
    service.env_file = expected.services['intake-consumer'].env_file;
    invariant(canonicalJSON(compiled) === canonicalJSON(expected),
      'committed intake Compose differs from reviewed identity/resource/command policy');
    return compiled;
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
}

function canaryGuardContract(release) {
  const file = filename => {
    const entries = release.source.contractFiles?.filter(row => row.path === filename);
    invariant(entries?.length === 1 && SHA256.test(entries[0].sha256) &&
      Number.isSafeInteger(entries[0].sizeBytes) && entries[0].sizeBytes > 0, 'canary guard source binding missing');
    return { path: filename, sha256: entries[0].sha256, sizeBytes: entries[0].sizeBytes };
  };
  return { ...Object.fromEntries(Object.entries(CANARY_GUARD_FILES).map(([role, filename]) => [role, file(filename)])),
    dependencies: CANARY_GUARD_DEPENDENCIES.map(file) };
}

export function createWorkerDeployment(release, selectedV1Reference, shadowV2Reference, targetIdentity, intake,
  scope, admissionInput) {
  const admission = validateAdmission(admissionInput);
  invariant(scope === 'initial-selected-v1' ? admission.mode === 'canary' : admission.mode === 'all-eligible',
    'initial deployment requires canary; full fleet requires separately reviewed all-eligible admission');
  invariant(['initial-selected-v1', 'full-fleet'].includes(scope), 'worker deployment scope differs');
  invariant(release?.schemaVersion === 1 && release.kind === 'frwhoop-phone-test-artifact-manifest' &&
    REVISION.test(release.source?.commit) && REVISION.test(release.source?.tree) &&
    SHA256.test(release.manifestFingerprintSha256), 'verified release manifest is required');
  invariant(canonicalJSON(release.roles) === canonicalJSON(roleContract(release.source.commit)),
    'release worker roles differ');
  const postgresClient = postgresClientContract(release.runtimeClients?.postgresql);
  const intakeImage = registryImage(intake?.reference, release.artifacts?.intake?.image, 'intake');
  const compiledCompose = intakeComposeContract(intakeImage.reference, release.source.commit,
    intake?.instanceId, intake?.projectRef, admission);
  invariant(canonicalJSON(intake?.compiledCompose) === canonicalJSON(compiledCompose),
    'intake compiled Compose differs from reviewed runtime limits/identity');
  const unsigned = {
    schemaVersion: 1,
    kind: 'frwhoop-worker-deployment',
    source: { commit: release.source.commit, tree: release.source.tree },
    releaseManifestFingerprintSha256: release.manifestFingerprintSha256,
    platform: PLATFORM,
    heartbeatContract: 'physiology_worker_heartbeats-v1',
    scope, admission, admissionSha256: sha256(canonicalJSON(admission)),
    canaryGuard: scope === 'initial-selected-v1' ? canaryGuardContract(release) : null,
    baselineEnvironment: admissionEnvironment(admission, 'SCORING'),
    laneOrder: structuredClone(scope === 'initial-selected-v1' ? workerLaneOrder.slice(0, 2) : workerLaneOrder),
    images: {
      intake: intakeImage,
      selectedV1: registryImage(selectedV1Reference, release.artifacts?.selectedV1?.image, 'selected v1'),
      shadowV2: registryImage(shadowV2Reference, release.artifacts?.shadowV2?.image, 'shadow v2'),
    },
    runtimeClients: { postgresql: postgresClient },
    target: reviewedTarget(targetIdentity),
    intake: { contractVersion: 2, instanceId: intake.instanceId, projectRef: intake.projectRef,
      asyncAdmission: 'DISABLED_UNTIL_SEPARATELY_AUTHORIZED',
      compiledCompose, compiledComposeSha256: sha256(canonicalJSON(compiledCompose)) },
    rollbackState: 'REQUIRES_SEPARATE_REVIEWED_COMPATIBLE_ARTIFACT',
  };
  return { ...unsigned, deploymentFingerprintSha256: sha256(canonicalJSON(unsigned)) };
}

export function verifyWorkerDeploymentContract(release, deployment) {
  exactKeys(deployment, ['schemaVersion', 'kind', 'source', 'releaseManifestFingerprintSha256', 'platform',
    'heartbeatContract', 'scope', 'admission', 'admissionSha256', 'baselineEnvironment', 'canaryGuard', 'laneOrder', 'images', 'runtimeClients', 'target', 'intake', 'rollbackState',
    'deploymentFingerprintSha256'],
  'worker deployment');
  exactKeys(deployment.source, ['commit', 'tree'], 'worker deployment source');
  exactKeys(deployment.images, ['selectedV1', 'shadowV2', 'intake'], 'worker deployment images');
  for (const [role, image] of Object.entries(deployment.images))
    exactKeys(image, ['reference', 'manifestDigest', 'configDigest'], `worker deployment ${role}`);
  exactKeys(deployment.runtimeClients, ['postgresql'], 'worker deployment runtime clients');
  exactKeys(deployment.runtimeClients.postgresql,
    ['reference', 'manifestDigest', 'configDigest', 'platform', 'version'], 'worker deployment PostgreSQL client');
  exactKeys(deployment.target,
    ['ip', 'sshPort', 'sshHostPublicKey', 'deployPublicKeyFingerprint'], 'worker deployment target');
  exactKeys(deployment.target.sshHostPublicKey, ['type', 'line', 'fingerprint'], 'worker deployment SSH host public key');
  exactKeys(deployment.intake, ['contractVersion', 'instanceId', 'projectRef', 'asyncAdmission',
    'compiledCompose', 'compiledComposeSha256'], 'intake deployment');
  const expected = createWorkerDeployment(release, deployment.images.selectedV1.reference,
    deployment.images.shadowV2.reference, {
      ip: deployment.target.ip,
      sshPort: deployment.target.sshPort,
      sshHostPublicKeyLine: deployment.target.sshHostPublicKey.line,
      sshHostPublicKeyFingerprint: deployment.target.sshHostPublicKey.fingerprint,
      deployPublicKeyFingerprint: deployment.target.deployPublicKeyFingerprint,
    }, { reference: deployment.images.intake.reference, ...deployment.intake }, deployment.scope, deployment.admission);
  invariant(canonicalJSON(deployment) === canonicalJSON(expected), 'worker deployment binding differs');
  return deployment;
}

export function bindWorkerDeployment({ repoRoot, artifactRoot, manifest, selectedV1Reference, shadowV2Reference,
  targetIdentity, intakeReference, intakeInstanceId, intakeProjectRef, scope, admission }) {
  const release = verifyReleaseManifest({ repoRoot, artifactRoot, manifest });
  const intake = { reference: intakeReference, instanceId: intakeInstanceId, projectRef: intakeProjectRef,
    compiledCompose: compileIntakeCompose({ repoRoot, commit: release.source.commit,
      reference: intakeReference, instanceId: intakeInstanceId, projectRef: intakeProjectRef, admission }) };
  return createWorkerDeployment(release, selectedV1Reference, shadowV2Reference, targetIdentity, intake, scope, admission);
}

export function verifyWorkerDeployment({ repoRoot, artifactRoot, manifest, deployment }) {
  const release = verifyReleaseManifest({ repoRoot, artifactRoot, manifest });
  verifyWorkerDeploymentContract(release, deployment);
  const compiled = compileIntakeCompose({ repoRoot, commit: release.source.commit,
    reference: deployment.images.intake.reference, instanceId: deployment.intake.instanceId,
    projectRef: deployment.intake.projectRef, admission: deployment.admission });
  invariant(canonicalJSON(compiled) === canonicalJSON(deployment.intake.compiledCompose),
    'intake committed Compose differs from deployment binding');
  return deployment;
}

export function prepareReleaseManifest({ repoRoot, artifactRoot, input }) {
  const repo = fs.realpathSync(repoRoot), root = fs.realpathSync(artifactRoot), value = validateInput(input);
  const commit = value.sourceSha;
  invariant(git(repo, 'cat-file', '-t', commit).toString().trim() === 'commit', 'source commit is unavailable locally');
  const tree = git(repo, 'rev-parse', `${commit}^{tree}`).toString().trim();
  invariant(REVISION.test(tree), 'source tree is invalid');
  const contract = sourceContract(repo, commit);

  const v1Input = value.artifacts.selectedV1, v2Input = value.artifacts.shadowV2;
  const v1File = fileIdentity(root, v1Input.oci), v1MetadataFile = fileIdentity(root, v1Input.buildMetadata);
  const v1ProvenanceFile = fileIdentity(root, v1Input.provenance);
  const v1Metadata = boundedJSON(artifactFile(root, v1Input.buildMetadata));
  const v1Provenance = validateV1Provenance(boundedJSON(artifactFile(root, v1Input.provenance)), repo, commit);
  const v1OCI = inspectOCI(artifactFile(root, v1Input.oci), 'selected-v1', commit, v1Metadata, v1Provenance);
  const v2File = fileIdentity(root, v2Input.oci), v2MetadataFile = fileIdentity(root, v2Input.buildMetadata);
  const v2Metadata = boundedJSON(artifactFile(root, v2Input.buildMetadata));
  const v2OCI = inspectOCI(artifactFile(root, v2Input.oci), 'shadow-v2', commit, v2Metadata);

  const intakeInput = value.artifacts.intake;
  const intakeFile = fileIdentity(root, intakeInput.oci);
  const intakeMetadataFile = fileIdentity(root, intakeInput.buildMetadata);
  const intakeOCI = inspectOCI(artifactFile(root, intakeInput.oci), 'intake', commit,
    boundedJSON(artifactFile(root, intakeInput.buildMetadata)));

  const edgeInput = value.artifacts.edge, edgeBundlePath = artifactFile(root, edgeInput.bundle);
  const edgeBundle = fileIdentity(root, edgeInput.bundle);
  const edgeManifestFile = fileIdentity(root, edgeInput.manifest);
  const edgeManifest = boundedJSON(artifactFile(root, edgeInput.manifest));
  const verifiedEdge = verifyEdgeSourceBundle(path.dirname(edgeBundlePath), { expectedBundleSha256: edgeBundle.sha256 });
  invariant(canonicalJSON(verifiedEdge) === canonicalJSON(edgeManifest), 'Edge verified manifest differs');
  verifyBundleMatchesCommittedSource(repo, commit, edgeManifest, 'edge');
  const edge = validateEdgeManifest(edgeManifest, commit, tree, edgeBundle);
  const migrationInput = value.artifacts.migrations, migrationFile = fileIdentity(root, migrationInput.manifest);
  const migrations = validateMigrationManifest(boundedJSON(artifactFile(root, migrationInput.manifest)), repo, commit, tree);
  const deploymentInput = value.artifacts.deployment;
  const deploymentBundlePath = artifactFile(root, deploymentInput.bundle);
  const deploymentFile = fileIdentity(root, deploymentInput.bundle);
  const deploymentManifestFile = fileIdentity(root, deploymentInput.manifest);
  const deploymentManifest = boundedJSON(artifactFile(root, deploymentInput.manifest));
  const verifiedDeployment = verifyDeploymentSourceBundle(path.dirname(deploymentBundlePath),
    { expectedBundleSha256: deploymentFile.sha256 });
  invariant(canonicalJSON(verifiedDeployment) === canonicalJSON(deploymentManifest),
    'deployment verified manifest differs');
  verifyBundleMatchesCommittedSource(repo, commit, deploymentManifest, 'deployment');
  const deployment = validateDeploymentManifest(deploymentManifest, commit, tree, deploymentFile);

  const unsigned = {
    schemaVersion: 1,
    kind: 'frwhoop-phone-test-artifact-manifest',
    source: { commit, tree, contractFiles: contract.files },
    roles: roleContract(commit),
    runtimeClients: { postgresql: structuredClone(POSTGRES_CLIENT) },
    artifacts: {
      selectedV1: { kind: 'oci-image', file: v1File, buildMetadata: v1MetadataFile,
        provenance: v1ProvenanceFile, image: v1OCI, algorithmVersion: 'frwhoop-server-1' },
      shadowV2: { kind: 'oci-image', file: v2File, buildMetadata: v2MetadataFile,
        image: v2OCI, algorithmVersions: ['frwhoop-physiology-2', 'frwhoop-server-2-history'] },
      intake: { kind: 'oci-image', file: intakeFile, buildMetadata: intakeMetadataFile,
        image: intakeOCI, contractVersion: 2 },
      android: inspectAndroid(repo, commit, root, value.artifacts.android, contract.versions),
      ios: inspectIOS(repo, commit, root, value.artifacts.ios, value.expected, contract.versions),
      edge: { kind: 'edge-source-bundle', file: edgeBundle, manifest: edgeManifestFile, ...edge },
      migrations: { kind: 'migration-manifest', file: migrationFile, ...migrations },
      deployment: { kind: 'deployment-verification-bundle', file: deploymentFile,
        manifest: deploymentManifestFile, ...deployment },
    },
    operationalState: {
      registryPublication: 'BLOCKED',
      deployment: 'NOT_PERFORMED',
      productionMigrations: 'NOT_APPLIED',
      phoneInstallation: 'NOT_PERFORMED',
      heartbeatVerification: 'BLOCKED_UNTIL_AUTHORIZED_DEPLOYMENT',
    },
  };
  return { ...unsigned, manifestFingerprintSha256: sha256(canonicalJSON(unsigned)) };
}

export function releaseInputFromManifest(manifest) {
  const artifacts = manifest?.artifacts;
  return {
    schemaVersion: 1,
    sourceSha: manifest?.source?.commit,
    expected: {
      iosAppGroup: artifacts?.ios?.appGroup,
      iosBundleIdentifiers: artifacts?.ios?.bundles?.map(bundle => bundle.bundleIdentifier),
    },
    artifacts: {
      selectedV1: { oci: artifacts?.selectedV1?.file?.path,
        buildMetadata: artifacts?.selectedV1?.buildMetadata?.path,
        provenance: artifacts?.selectedV1?.provenance?.path },
      shadowV2: { oci: artifacts?.shadowV2?.file?.path,
        buildMetadata: artifacts?.shadowV2?.buildMetadata?.path },
      intake: { oci: artifacts?.intake?.file?.path, buildMetadata: artifacts?.intake?.buildMetadata?.path },
      android: { apk: artifacts?.android?.file?.path,
        outputMetadata: artifacts?.android?.outputMetadata?.path,
        aapt2: artifacts?.android?.tools?.aapt2?.file?.path,
        apksigJar: artifacts?.android?.tools?.apksigJar?.file?.path },
      ios: { ipa: artifacts?.ios?.file?.path },
      edge: { bundle: artifacts?.edge?.file?.path, manifest: artifacts?.edge?.manifest?.path },
      migrations: { manifest: artifacts?.migrations?.file?.path },
      deployment: { bundle: artifacts?.deployment?.file?.path, manifest: artifacts?.deployment?.manifest?.path },
    },
  };
}
export function verifyReleaseManifest({ repoRoot, artifactRoot, manifest }) {
  invariant(manifest?.schemaVersion === 1 && manifest.kind === 'frwhoop-phone-test-artifact-manifest' &&
    REVISION.test(manifest.source?.commit) && REVISION.test(manifest.source?.tree), 'release artifact manifest is invalid');
  const { manifestFingerprintSha256, ...unsigned } = manifest;
  invariant(SHA256.test(manifestFingerprintSha256) &&
    sha256(canonicalJSON(unsigned)) === manifestFingerprintSha256, 'release artifact manifest fingerprint differs');
  const repo = fs.realpathSync(repoRoot), root = fs.realpathSync(artifactRoot);
  invariant(git(repo, 'rev-parse', `${manifest.source.commit}^{tree}`).toString().trim() === manifest.source.tree,
    'release source tree differs');
  // Recreate every semantic field from the bound artifact bytes and exact committed source. This
  // rejects a coherently reauthored manifest whose own fingerprint and file hashes are internally
  // consistent but whose package, signature, migration, role, or operational claims were changed.
  const regenerated = prepareReleaseManifest({ repoRoot: repo, artifactRoot: root,
    input: releaseInputFromManifest(manifest) });
  invariant(canonicalJSON(regenerated) === canonicalJSON(manifest),
    'release artifact manifest differs from deterministic semantic regeneration');
  return manifest;
}

function usage() {
  return 'usage: release-artifact-manifest.mjs compile-intake --repo-root PATH --commit SHA --intake-image REF --intake-instance-id UUID --intake-project-ref REF --admission-config PRIVATE_JSON --output PRIVATE_JSON | prepare --repo-root PATH --artifact-root PATH --inputs JSON --output JSON | verify --repo-root PATH --artifact-root PATH --manifest JSON | bind-deployment --repo-root PATH --artifact-root PATH --manifest JSON --selected-v1-image REF --shadow-v2-image REF --intake-image REF --intake-instance-id UUID --intake-project-ref REF --scope initial-selected-v1|full-fleet --admission-config PRIVATE_JSON --target-ip IP --target-ssh-port PORT --target-ssh-host-key-line KEY --target-ssh-host-key-fingerprint SHA256:BASE64 --deploy-public-key-fingerprint SHA256:BASE64 --output JSON | verify-deployment --repo-root PATH --artifact-root PATH --manifest JSON --deployment JSON';
}
function argumentsFor(argv, keys) {
  invariant(argv.length === keys.length * 2, usage());
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    invariant(keys.includes(argv[index]) && !(argv[index] in result) && argv[index + 1], usage());
    result[argv[index]] = argv[index + 1];
  }
  invariant(keys.every(key => key in result), usage());
  return result;
}
export function atomicWrite(filename, value, mode = 0o644) {
  const resolved = path.resolve(filename), bytes = Buffer.from(JSON.stringify(sorted(value), null, 2) + '\n');
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  const temporary = path.join(path.dirname(resolved), `.${path.basename(resolved)}.${process.pid}.tmp`);
  try { fs.writeFileSync(temporary, bytes, { flag: 'wx', mode }); fs.renameSync(temporary, resolved); }
  finally { fs.rmSync(temporary, { force: true }); }
}
export function runCLI(argv) {
  const [mode, ...rest] = argv;
  if (mode === 'compile-intake') {
    const args = argumentsFor(rest, ['--repo-root', '--commit', '--intake-image', '--intake-instance-id',
      '--intake-project-ref', '--admission-config', '--output']);
    const admission = validateAdmission(readPrivateJSON(args['--admission-config']));
    const compiled = compileIntakeCompose({ repoRoot: args['--repo-root'], commit: args['--commit'],
      reference: args['--intake-image'], instanceId: args['--intake-instance-id'],
      projectRef: args['--intake-project-ref'], admission });
    atomicWrite(args['--output'], compiled, 0o600);
    process.stdout.write(JSON.stringify({ status: 'INTAKE_COMPOSE_COMPILED_OFFLINE',
      output: path.resolve(args['--output']), sha256: sha256(canonicalJSON(compiled)),
      admissionMode: admission.mode, admissionSha256: sha256(canonicalJSON(admission)) }) + '\n');
    return compiled;
  }
  if (mode === 'prepare') {
    const args = argumentsFor(rest, ['--repo-root', '--artifact-root', '--inputs', '--output']);
    const manifest = prepareReleaseManifest({ repoRoot: args['--repo-root'], artifactRoot: args['--artifact-root'],
      input: boundedJSON(path.resolve(args['--inputs'])) });
    atomicWrite(args['--output'], manifest);
    process.stdout.write(JSON.stringify({ status: 'ARTIFACTS_BOUND_OFFLINE', output: path.resolve(args['--output']),
      fingerprint: manifest.manifestFingerprintSha256 }) + '\n');
    return manifest;
  }
  if (mode === 'verify') {
    const args = argumentsFor(rest, ['--repo-root', '--artifact-root', '--manifest']);
    const manifest = boundedJSON(path.resolve(args['--manifest']));
    verifyReleaseManifest({ repoRoot: args['--repo-root'], artifactRoot: args['--artifact-root'], manifest });
    process.stdout.write(JSON.stringify({ status: 'ARTIFACT_MANIFEST_VERIFIED',
      fingerprint: manifest.manifestFingerprintSha256 }) + '\n');
    return manifest;
  }
  if (mode === 'bind-deployment') {
    const args = argumentsFor(rest, ['--repo-root', '--artifact-root', '--manifest', '--selected-v1-image',
      '--shadow-v2-image', '--intake-image', '--intake-instance-id', '--intake-project-ref', '--scope', '--admission-config', '--target-ip', '--target-ssh-port', '--target-ssh-host-key-line',
      '--target-ssh-host-key-fingerprint', '--deploy-public-key-fingerprint', '--output']);
    const manifest = boundedJSON(path.resolve(args['--manifest']));
    const deployment = bindWorkerDeployment({ repoRoot: args['--repo-root'], artifactRoot: args['--artifact-root'],
      manifest, selectedV1Reference: args['--selected-v1-image'], shadowV2Reference: args['--shadow-v2-image'],
      intakeReference: args['--intake-image'], intakeInstanceId: args['--intake-instance-id'],
      intakeProjectRef: args['--intake-project-ref'],
      scope: args['--scope'], admission: validateAdmission(readPrivateJSON(args['--admission-config'])),
      targetIdentity: {
        ip: args['--target-ip'], sshPort: args['--target-ssh-port'],
        sshHostPublicKeyLine: args['--target-ssh-host-key-line'],
        sshHostPublicKeyFingerprint: args['--target-ssh-host-key-fingerprint'],
        deployPublicKeyFingerprint: args['--deploy-public-key-fingerprint'],
      } });
    atomicWrite(args['--output'], deployment, 0o600);
    process.stdout.write(JSON.stringify({ status: 'WORKER_DEPLOYMENT_BOUND', output: path.resolve(args['--output']),
      fingerprint: deployment.deploymentFingerprintSha256, admissionMode: deployment.admission.mode,
      admissionSha256: deployment.admissionSha256 }) + '\n');
    return deployment;
  }
  if (mode === 'verify-deployment') {
    const args = argumentsFor(rest, ['--repo-root', '--artifact-root', '--manifest', '--deployment']);
    const manifest = boundedJSON(path.resolve(args['--manifest']));
    const deployment = readPrivateJSON(path.resolve(args['--deployment']));
    verifyWorkerDeployment({ repoRoot: args['--repo-root'], artifactRoot: args['--artifact-root'],
      manifest, deployment });
    process.stdout.write(JSON.stringify({ status: 'WORKER_DEPLOYMENT_VERIFIED',
      sourceSha: deployment.source.commit, sourceTree: deployment.source.tree,
      fingerprint: deployment.deploymentFingerprintSha256,
      scope: deployment.scope, admissionMode: deployment.admission.mode, admissionSha256: deployment.admissionSha256,
      selectedV1: deployment.images.selectedV1, shadowV2: deployment.images.shadowV2,
      intake: deployment.images.intake, intakeContract: deployment.intake.contractVersion,
      postgresqlClient: deployment.runtimeClients.postgresql, target: deployment.target }) + '\n');
    return deployment;
  }
  invariant(false, usage());
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { runCLI(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`${error instanceof Error ? error.message : 'NOT_READY: unknown artifact error'}\n`); process.exitCode = 1; }
}
