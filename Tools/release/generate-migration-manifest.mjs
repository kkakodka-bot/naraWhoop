#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const CATALOG_RELATIVE_PATH = 'scoring-service/service/src/main/resources/scoring-migration-catalog.json';
const MIGRATIONS_RELATIVE_PATH = 'supabase/migrations';
const BASELINE_COUNT = 117;
const EXPECTED_TOTAL = 128;
const EXPECTED_SCHEMA_FINGERPRINT = 'f5d9f630389b1236efbe8494878faecb0fe8e9e17f5d25b47723759d9c58d92d';
const HOSTED_PROJECT_REF = 'sgoyxzcagqyxexmsidtk';
const HOSTED_HIGHEST_IDENTITY = '20260921104000_server_unrepresentable_clock.sql';
const SUPERSEDED_HOSTED_IDENTITY = '20260918234000_motion_evidence_provenance.sql';

const SOURCE_CONTRACT = Object.freeze({
  'persistent-sync-followup': Object.freeze({
    branch: 'codex/persistent-sync-followup-2026-09-22',
    tip: 'a972493212f2eae29f01ecaddf9182260153400f',
  }),
  'server-repair': Object.freeze({
    branch: 'repair/vps-server-20260922',
    tip: null, // This workstream is the candidate itself, not an earlier release artifact.
  }),
  'server-pipeline': Object.freeze({
    branch: 'fix/server-pipeline',
    tip: 'cfb94434b1b4ed4dba587e5c4e7af405e782e560',
  }),
  'multiuser-scale': Object.freeze({
    branch: 'feat/multiuser-scale',
    tip: '0eac19cce495e761dc3d832dd1cfd8a07221c61d',
  }),
  'sensor-algorithms': Object.freeze({
    branch: 'feat/sensor-algorithms',
    tip: '198b99924a79148ff01833115fe2f47f2025bfa4',
  }),
  'ble-sync': Object.freeze({
    branch: 'fix/ble-sync',
    tip: 'af9468f7a48cc3fddeb33d7a3b983204af620ca6',
  }),
  'vps-only-compute': Object.freeze({
    branch: 'feat/vps-only-compute',
    tip: '63ac35d0cab0644d197e8225d9fc97e1bd9446cf',
  }),
});

const PENDING_CONTRACT = Object.freeze([
  Object.freeze({
    stableIdentity: '20260921110000_installation_retirement.sql',
    sha256: '352dd120144c07ef3f9f37bf5b6f90a336957d1f2a39f95281621bbc56b7234b',
    workstream: 'multiuser-scale',
  }),
  Object.freeze({
    stableIdentity: '20260921111000_wearable_lifecycle.sql',
    sha256: '9ed18ae85c98d1eb28f4b9d646b2b91278cead273f72f88c6305147bafa08583',
    workstream: 'multiuser-scale',
  }),
  Object.freeze({
    stableIdentity: '20260921112000_fleet_scheduler.sql',
    sha256: '52743cf103be90ef53815a519e3d49e0cf6bfdeacb3be2a39a6588e2ff3e9a37',
    workstream: 'multiuser-scale',
  }),
  Object.freeze({
    stableIdentity: '20260921113000_fleet_admission_retention.sql',
    sha256: 'c393e5236880709ebcf01b7e1390d5b5a8925647b31f03864e4100f524c13369',
    workstream: 'multiuser-scale',
  }),
  Object.freeze({
    stableIdentity: '20260921120000_sensor_acquisition_windows.sql',
    sha256: 'aeb8a076e4d04a88ba0f16fb3744627259a4fbe82fd0113be77f6eb6341fde93',
    workstream: 'sensor-algorithms',
  }),
  Object.freeze({
    stableIdentity: '20260921121000_final_hosted_compute_contract.sql',
    sha256: '4f19d77777d1da06f5a3be1683fd03264f8563a4b0fa104d2a80dd9fc74d300a',
    workstream: 'vps-only-compute',
  }),
  Object.freeze({
    stableIdentity: '20260921122000_compute_session_requests.sql',
    sha256: '14efd30ff5754a779ee300e86be08ce2db8bd6c4aa3b3e8a96bc97abf8b773a1',
    workstream: 'vps-only-compute',
  }),
  Object.freeze({
    stableIdentity: '20260922010000_object_copy_intents.sql',
    sha256: '5955c91bebaf706ab0cfc67f3c9a09e67a7438226bd04d66c4d4dd42a12b6eb4',
    workstream: 'persistent-sync-followup',
  }),
  Object.freeze({
    stableIdentity: '20260922020000_async_object_verification.sql',
    sha256: 'dc8ce2caf80bf34b83027d4651386609bb7f63c6045b92c37e1e9c64dbf38a0d',
    workstream: 'persistent-sync-followup',
  }),
  Object.freeze({
    stableIdentity: '20260922120000_intake_service_contract.sql',
    sha256: 'efb7ea5b812b24ca87f877752dc8f266de6443bdf199c40f869d208e2d051285',
    workstream: 'server-repair',
  }),
  Object.freeze({
    stableIdentity: '20260922130000_scoped_intake_admission.sql',
    sha256: '076ef5db0e4837378c9070adcf7a8a8df5cae1cf33ac680b7070cd117514ec52',
    workstream: 'server-repair',
  }),
]);

const COMPUTE_RENAMES = new Map([
  ['20260921121000_final_hosted_compute_contract.sql', Object.freeze({
    proposedStableIdentity: '20260921110000_final_hosted_compute_contract.sql',
    collidedWithStableIdentity: '20260921110000_installation_retirement.sql',
  })],
  ['20260921122000_compute_session_requests.sql', Object.freeze({
    proposedStableIdentity: '20260921111000_compute_session_requests.sql',
    collidedWithStableIdentity: '20260921111000_wearable_lifecycle.sql',
  })],
]);

function invariant(condition, message) {
  if (!condition) throw new Error(`NOT_READY: ${message}`);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function requireObject(value, label) {
  invariant(isObject(value), `${label} must be an object`);
  return value;
}

function requireExactKeys(value, expected, label) {
  const actual = Object.keys(requireObject(value, label)).sort();
  const wanted = [...expected].sort();
  invariant(JSON.stringify(actual) === JSON.stringify(wanted), `${label} fields differ from the reviewed contract`);
}

function requireString(value, label) {
  invariant(typeof value === 'string' && value.trim() === value && value.length > 0, `${label} must be a nonempty string`);
  return value;
}

function requireSha256(value, label) {
  invariant(typeof value === 'string' && /^[0-9a-f]{64}$/.test(value), `${label} must be a lowercase SHA-256`);
  return value;
}

function requireGitSha(value, label) {
  invariant(typeof value === 'string' && /^[0-9a-f]{40}$/.test(value), `${label} must be a full Git SHA`);
  return value;
}

export function sha256Hex(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function sortForCanonicalJSON(value) {
  if (Array.isArray(value)) return value.map(sortForCanonicalJSON);
  if (!isObject(value)) return value;
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, sortForCanonicalJSON(value[key])]));
}

export function canonicalJSON(value) {
  return JSON.stringify(sortForCanonicalJSON(value));
}

function readJSON(filename, label) {
  try {
    return JSON.parse(fs.readFileSync(filename, 'utf8'));
  } catch {
    throw new Error(`NOT_READY: ${label} is not readable JSON`);
  }
}

function schemaFingerprint(catalog) {
  const payload = 'frwhoop-migration-schema-v1\n' + catalog.map((row, index) =>
    `${index + 1}\0${row.basename}\0${row.sha256}\n`).join('');
  return sha256Hex(payload);
}

function validateCatalog(repoRoot) {
  const catalogPath = path.join(repoRoot, CATALOG_RELATIVE_PATH);
  const migrationDirectory = path.join(repoRoot, MIGRATIONS_RELATIVE_PATH);
  const catalog = readJSON(catalogPath, 'runtime migration catalog');
  invariant(Array.isArray(catalog) && catalog.length === EXPECTED_TOTAL,
    `runtime migration catalog must contain exactly ${EXPECTED_TOTAL} entries`);

  const identities = new Set();
  for (const [index, row] of catalog.entries()) {
    requireExactKeys(row, ['basename', 'sha256'], `catalog entry ${index + 1}`);
    invariant(/^[0-9]{14}_[a-z0-9_]+\.sql$/.test(row.basename), `catalog entry ${index + 1} has an invalid stable identity`);
    requireSha256(row.sha256, `catalog entry ${index + 1} hash`);
    invariant(!identities.has(row.basename), `duplicate catalog identity ${row.basename}`);
    identities.add(row.basename);
  }

  const actualFingerprint = schemaFingerprint(catalog);
  invariant(actualFingerprint === EXPECTED_SCHEMA_FINGERPRINT,
    'runtime migration catalog order or identity/hash contract drifted');

  const pending = catalog.slice(BASELINE_COUNT);
  invariant(pending.length === PENDING_CONTRACT.length, 'pending migration count drifted');
  for (const [index, expected] of PENDING_CONTRACT.entries()) {
    invariant(pending[index].basename === expected.stableIdentity && pending[index].sha256 === expected.sha256,
      `pending migration contract drifted at upgrade ordinal ${index + 1}`);
  }

  const oldComputeNames = [...COMPUTE_RENAMES.values()].map(row => row.proposedStableIdentity);
  invariant(oldComputeNames.every(name => !identities.has(name)), 'colliding compute proposal remains in the runtime catalog');

  let migrationNames;
  try {
    migrationNames = fs.readdirSync(migrationDirectory).filter(name => name.endsWith('.sql')).sort();
  } catch {
    throw new Error('NOT_READY: migration source directory is not readable');
  }
  const catalogNames = [...identities].sort();
  invariant(JSON.stringify(migrationNames) === JSON.stringify(catalogNames),
    'migration source file set differs from the runtime catalog');

  const fileMetadata = new Map();
  for (const row of catalog) {
    const filename = path.join(migrationDirectory, row.basename);
    const stat = fs.lstatSync(filename);
    invariant(stat.isFile() && !stat.isSymbolicLink(), `migration source is not a regular file: ${row.basename}`);
    const bytes = fs.readFileSync(filename);
    invariant(sha256Hex(bytes) === row.sha256, `migration source hash differs: ${row.basename}`);
    fileMetadata.set(row.basename, { sizeBytes: bytes.length });
  }
  return { catalog, fileMetadata, actualFingerprint };
}

function validateCandidateSources(raw) {
  requireExactKeys(raw, ['schemaVersion', 'candidate', 'sources'], 'candidate/source metadata');
  invariant(raw.schemaVersion === 1, 'candidate/source metadata schemaVersion must be 1');
  requireExactKeys(raw.candidate, ['branch', 'sha', 'tree'], 'candidate metadata');
  invariant(raw.candidate.branch === 'repair/vps-server-20260922', 'candidate branch must be repair/vps-server-20260922');
  requireGitSha(raw.candidate.sha, 'candidate SHA');
  requireGitSha(raw.candidate.tree, 'candidate tree');

  const expectedWorkstreams = Object.keys(SOURCE_CONTRACT);
  invariant(isObject(raw.sources) && JSON.stringify(Object.keys(raw.sources).sort()) === JSON.stringify([...expectedWorkstreams].sort()),
    'source workstream set differs from the reviewed integration contract');
  for (const workstream of expectedWorkstreams) {
    const source = raw.sources[workstream];
    requireExactKeys(source, ['branch', 'tip'], `source metadata for ${workstream}`);
    invariant(source.branch === SOURCE_CONTRACT[workstream].branch, `${workstream} branch differs from the reviewed source`);
    invariant(source.tip === (SOURCE_CONTRACT[workstream].tip ?? raw.candidate.sha), `${workstream} tip differs from the reviewed source`);
  }
  return raw;
}

function validateHostedEvidence(raw, catalog) {
  requireExactKeys(raw, [
    'schemaVersion', 'environment', 'projectRef', 'capturedAt', 'nativeLedgerRows', 'fullIdentityRows',
    'highestKnownIdentity', 'applied', 'identityStates', 'evidenceArtifacts',
  ], 'hosted-ledger evidence');
  invariant(raw.schemaVersion === 1, 'hosted-ledger evidence schemaVersion must be 1');
  invariant(raw.environment === 'hosted-production', 'hosted-ledger environment must be hosted-production');
  invariant(raw.projectRef === HOSTED_PROJECT_REF, 'hosted project ref differs from FRWHOOP');
  invariant(typeof raw.capturedAt === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(raw.capturedAt)
    && !Number.isNaN(Date.parse(raw.capturedAt)), 'hosted capture time must be an explicit UTC timestamp');
  invariant(raw.nativeLedgerRows === 110, 'hosted native ledger row count must be the reviewed 110-row baseline');
  invariant(raw.fullIdentityRows === BASELINE_COUNT, `hosted full-identity row count must be ${BASELINE_COUNT}`);
  invariant(raw.highestKnownIdentity === HOSTED_HIGHEST_IDENTITY, 'hosted highest known migration identity drifted');

  invariant(Array.isArray(raw.applied) && raw.applied.length === BASELINE_COUNT,
    `hosted applied identities must contain exactly ${BASELINE_COUNT} entries`);
  const applied = new Map();
  for (const [index, row] of raw.applied.entries()) {
    requireExactKeys(row, ['stableIdentity', 'sha256'], `hosted applied identity ${index + 1}`);
    requireString(row.stableIdentity, `hosted applied identity ${index + 1}`);
    requireSha256(row.sha256, `hosted applied identity ${index + 1} hash`);
    invariant(!applied.has(row.stableIdentity), `duplicate hosted identity ${row.stableIdentity}`);
    applied.set(row.stableIdentity, row.sha256);
  }
  for (const row of catalog.slice(0, BASELINE_COUNT)) {
    invariant(applied.get(row.basename) === row.sha256, `hosted applied identity/hash differs: ${row.basename}`);
  }
  invariant([...applied.keys()].every(identity => catalog.slice(0, BASELINE_COUNT).some(row => row.basename === identity)),
    'hosted applied identities differ from the reviewed 117-entry baseline');

  requireObject(raw.identityStates, 'hosted identity states');
  const identityStates = new Map();
  for (const [identity, state] of Object.entries(raw.identityStates)) {
    invariant(applied.has(identity), `hosted identity state is not in the applied baseline: ${identity}`);
    invariant(isObject(state), `hosted identity state must be an object: ${identity}`);
    const allowedKeys = state.supersededBy === undefined ? ['state', 'reason'] : ['state', 'reason', 'supersededBy'];
    requireExactKeys(state, allowedKeys, `hosted identity state for ${identity}`);
    invariant(['active', 'superseded_in_hosted_schema'].includes(state.state), `unsupported hosted identity state for ${identity}`);
    requireString(state.reason, `hosted identity state reason for ${identity}`);
    if (state.supersededBy !== undefined) {
      requireString(state.supersededBy, `hosted superseding identity for ${identity}`);
      invariant(applied.has(state.supersededBy), `hosted superseding identity is not applied: ${state.supersededBy}`);
    }
    identityStates.set(identity, { ...state });
  }
  invariant(identityStates.get(SUPERSEDED_HOSTED_IDENTITY)?.state === 'superseded_in_hosted_schema',
    `hosted evidence must record ${SUPERSEDED_HOSTED_IDENTITY} as superseded`);

  invariant(Array.isArray(raw.evidenceArtifacts) && raw.evidenceArtifacts.length > 0,
    'hosted evidence must bind at least one immutable evidence artifact');
  const evidenceLabels = new Set();
  const evidenceArtifacts = raw.evidenceArtifacts.map((artifact, index) => {
    requireExactKeys(artifact, ['label', 'path', 'sha256'], `hosted evidence artifact ${index + 1}`);
    const label = requireString(artifact.label, `hosted evidence artifact ${index + 1} label`);
    invariant(!evidenceLabels.has(label), `duplicate hosted evidence artifact label ${label}`);
    evidenceLabels.add(label);
    return {
      label,
      path: requireString(artifact.path, `hosted evidence artifact ${index + 1} path`),
      sha256: requireSha256(artifact.sha256, `hosted evidence artifact ${index + 1} hash`),
    };
  }).sort((left, right) => left.label.localeCompare(right.label) || left.path.localeCompare(right.path));

  return { ...raw, applied, identityStates, evidenceArtifacts };
}

function workstreamFor(row, index) {
  if (index < BASELINE_COUNT) return 'server-pipeline';
  const pending = PENDING_CONTRACT[index - BASELINE_COUNT];
  invariant(pending?.stableIdentity === row.basename, `missing workstream ownership for ${row.basename}`);
  return pending.workstream;
}

function collisionRenameState(row, timestampGroups) {
  const renamed = COMPUTE_RENAMES.get(row.basename);
  if (renamed) {
    return {
      state: 'renamed_before_application',
      proposedStableIdentity: renamed.proposedStableIdentity,
      proposedTimestamp: renamed.proposedStableIdentity.slice(0, 14),
      collidedWithStableIdentity: renamed.collidedWithStableIdentity,
      reason: 'The proposed timestamp was already owned by the multi-user workstream; no applied history was rewritten.',
    };
  }
  const peers = timestampGroups.get(row.basename.slice(0, 14));
  if (peers.length > 1) {
    return {
      state: 'historical_timestamp_collision',
      peerStableIdentities: peers.filter(identity => identity !== row.basename),
      reason: 'The hosted full-identity ledger distinguishes identities that the native timestamp ledger cannot represent separately.',
    };
  }
  return { state: 'unique' };
}

export function generateMigrationManifest({ repoRoot, candidateSources, hostedLedgerEvidence }) {
  const resolvedRoot = fs.realpathSync(repoRoot);
  const { catalog, fileMetadata, actualFingerprint } = validateCatalog(resolvedRoot);
  const metadata = validateCandidateSources(candidateSources);
  const hosted = validateHostedEvidence(hostedLedgerEvidence, catalog);

  const timestampGroups = new Map();
  for (const row of catalog) {
    const timestamp = row.basename.slice(0, 14);
    timestampGroups.set(timestamp, [...(timestampGroups.get(timestamp) ?? []), row.basename]);
  }

  const entries = catalog.map((row, index) => {
    const ordinal = index + 1;
    const workstream = workstreamFor(row, index);
    const applied = hosted.applied.has(row.basename);
    const explicitIdentityState = hosted.identityStates.get(row.basename);
    const hostedIdentityState = applied
      ? (explicitIdentityState ?? { state: 'active', reason: 'Attested by the hosted full-identity ledger.' })
      : { state: 'not_applied', reason: 'Absent from the reviewed hosted baseline.' };
    return {
      ordinal,
      filename: row.basename,
      stableIdentity: row.basename,
      timestamp: row.basename.slice(0, 14),
      sha256: row.sha256,
      sizeBytes: fileMetadata.get(row.basename).sizeBytes,
      sourceWorkstream: workstream,
      sourceBranch: metadata.sources[workstream].branch,
      sourceTip: metadata.sources[workstream].tip,
      dependencies: index === 0 ? [] : [catalog[index - 1].basename],
      collisionRenameState: collisionRenameState(row, timestampGroups),
      hostedStatus: applied ? 'applied' : 'pending',
      hostedIdentityState,
      freshInstallBehavior: {
        action: 'apply_exact_source_once',
        applyOrdinal: ordinal,
        verifySha256: true,
      },
      upgradeBehavior: applied ? {
        action: 'preserve_applied_identity',
        execute: false,
        reason: 'The identity and source hash are attested in the hosted baseline; never replay or rename it.',
      } : {
        action: 'apply_exact_source_once',
        execute: true,
        upgradeOrdinal: ordinal - BASELINE_COUNT,
        reason: 'The identity is absent from the reviewed hosted baseline and is ordered after every required predecessor.',
      },
    };
  });

  const sourceWorkstreams = Object.keys(SOURCE_CONTRACT).map(workstream => ({
    workstream,
    branch: metadata.sources[workstream].branch,
    tip: metadata.sources[workstream].tip,
    migrationCount: entries.filter(entry => entry.sourceWorkstream === workstream).length,
  }));

  const unsignedManifest = {
    schemaVersion: 1,
    kind: 'frwhoop-immutable-migration-manifest',
    candidate: { ...metadata.candidate },
    sourceWorkstreams,
    hostedBaseline: {
      environment: hosted.environment,
      projectRef: hosted.projectRef,
      capturedAt: hosted.capturedAt,
      nativeLedgerRows: hosted.nativeLedgerRows,
      fullIdentityRows: hosted.fullIdentityRows,
      highestKnownIdentity: hosted.highestKnownIdentity,
      evidenceArtifacts: hosted.evidenceArtifacts,
    },
    catalog: {
      path: CATALOG_RELATIVE_PATH,
      migrationDirectory: MIGRATIONS_RELATIVE_PATH,
      entryCount: entries.length,
      baselineEntryCount: BASELINE_COUNT,
      pendingEntryCount: entries.length - BASELINE_COUNT,
    },
    counts: {
      total: entries.length,
      applied: entries.filter(entry => entry.hostedStatus === 'applied').length,
      pending: entries.filter(entry => entry.hostedStatus === 'pending').length,
    },
    schemaFingerprintSha256: actualFingerprint,
    entries,
  };
  return {
    ...unsignedManifest,
    manifestFingerprintSha256: sha256Hex(canonicalJSON(unsignedManifest)),
  };
}

function usage() {
  return 'usage: generate-migration-manifest.mjs --repo-root PATH --candidate-sources JSON --hosted-ledger-evidence JSON --output PATH|-';
}

function parseArguments(argv) {
  const allowed = new Set(['--repo-root', '--candidate-sources', '--hosted-ledger-evidence', '--output']);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    invariant(allowed.has(key) && value !== undefined && !values.has(key), usage());
    values.set(key, value);
  }
  invariant(values.size === allowed.size, usage());
  return Object.fromEntries([...values].map(([key, value]) => [key.slice(2).replaceAll('-', '_'), value]));
}

function writeOutput(filename, manifest) {
  const bytes = `${JSON.stringify(sortForCanonicalJSON(manifest), null, 2)}\n`;
  if (filename === '-') {
    process.stdout.write(bytes);
    return;
  }
  const resolved = path.resolve(filename);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  const temporary = path.join(path.dirname(resolved), `.${path.basename(resolved)}.${process.pid}.tmp`);
  try {
    fs.writeFileSync(temporary, bytes, { flag: 'wx', mode: 0o644 });
    fs.renameSync(temporary, resolved);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

export function runCLI(argv) {
  const args = parseArguments(argv);
  const manifest = generateMigrationManifest({
    repoRoot: path.resolve(args.repo_root),
    candidateSources: readJSON(path.resolve(args.candidate_sources), 'candidate/source metadata'),
    hostedLedgerEvidence: readJSON(path.resolve(args.hosted_ledger_evidence), 'hosted-ledger evidence'),
  });
  writeOutput(args.output, manifest);
  return manifest;
}

if (process.argv[1] && fs.existsSync(process.argv[1]) && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  try {
    runCLI(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : 'NOT_READY: unknown manifest error'}\n`);
    process.exitCode = 1;
  }
}
