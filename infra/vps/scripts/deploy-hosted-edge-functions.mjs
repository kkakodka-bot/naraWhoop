#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  DEPLOYABLE_ROLES,
  sha256Hex,
  verifyEdgeSourceBundle,
} from '../../../Tools/release/edge-source-bundle.mjs';
import { verifyReleaseManifest as verifyAggregateReleaseManifest } from '../../../Tools/release/release-artifact-manifest.mjs';

export const HOSTED_PROJECT_REF = 'sgoyxzcagqyxexmsidtk';
export const HOSTED_FUNCTIONS = Object.freeze([...DEPLOYABLE_ROLES]);

const RECEIPT_SCHEMA_VERSION = 1;
const METADATA_NAME = 'edge-source-bundle-metadata.json';
const CANDIDATE_PARITY_PATH = 'infra/vps/scripts/verify-hosted-score-route-parity.mjs';
const GIT_EXECUTABLE = '/usr/bin/git';
const MAX_RELEASE_MANIFEST_BYTES = 64 * 1024 * 1024;
const PROCESS_ENVIRONMENT = Object.freeze([
  'PATH', 'TMPDIR', 'TMP', 'TEMP', 'SSL_CERT_FILE', 'SSL_CERT_DIR',
  'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
]);
const PARITY_PROCESS_ENVIRONMENT = Object.freeze(
  PROCESS_ENVIRONMENT.filter((name) => name !== 'PATH'),
);
const SUPABASE_ENVIRONMENT = Object.freeze([
  ...PROCESS_ENVIRONMENT, 'SUPABASE_ACCESS_TOKEN',
]);
const PARITY_CREDENTIALS = Object.freeze([
  'FRWHOOP_HOSTED_ACCOUNT_JWT',
  'FRWHOOP_HOSTED_ANON_KEY',
  'FRWHOOP_HOSTED_ENROLLMENT_TOKEN',
  'FRWHOOP_HOSTED_FLEET_TOKEN',
  'FRWHOOP_HOSTED_USER_ID',
  'FRWHOOP_HOSTED_SOURCE_ID',
  'FRWHOOP_HOSTED_DEVICE_ID',
  'FRWHOOP_HOSTED_DAY',
]);
const PARITY_ENVIRONMENT = Object.freeze([...PARITY_PROCESS_ENVIRONMENT, ...PARITY_CREDENTIALS]);
const PARITY_CONTRACT = Object.freeze({
  kind: 'frwhoop-hosted-score-route-parity',
  schemaVersion: 1,
});

class HostedEdgeError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function fail(code, message) {
  throw new HostedEdgeError(code, message);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function exactKeys(value, expected, label) {
  if (!isObject(value) || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...expected].sort())) {
    fail('PARITY_RESULT_INVALID', `${label} fields differ from the hosted parity contract`);
  }
}

function requireSha256(value, label) {
  if (typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value)) {
    fail('ARGUMENT_INVALID', `${label} must be a lowercase SHA-256`);
  }
}

function selectedEnvironment(source, names) {
  const result = {};
  for (const name of names) {
    if (typeof source[name] === 'string' && source[name].length > 0) result[name] = source[name];
  }
  return result;
}

function regularFileIdentity(filename, label) {
  if (typeof filename !== 'string' || !path.isAbsolute(filename)) {
    fail('ARGUMENT_INVALID', `${label} must be an absolute file path`);
  }
  let stat;
  try {
    stat = fs.lstatSync(filename);
  } catch {
    fail('ARGUMENT_INVALID', `${label} is missing or unreadable`);
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail('ARGUMENT_INVALID', `${label} must be a regular file`);
  const realPath = fs.realpathSync(filename);
  return { path: realPath, sizeBytes: stat.size, sha256: sha256Hex(fs.readFileSync(realPath)) };
}

function releaseArtifactFile(artifactRoot, relativePath, label) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || path.isAbsolute(relativePath) ||
      relativePath.includes('\\') || relativePath.split('/').some((part) => !part || part === '.' || part === '..')) {
    fail('RELEASE_MANIFEST_INVALID', `${label} path is not a normalized artifact-relative path`);
  }
  const root = fs.realpathSync(artifactRoot);
  let current = root;
  for (const part of relativePath.split('/')) {
    current = path.join(current, part);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) fail('RELEASE_MANIFEST_INVALID', `${label} path contains a symbolic link`);
  }
  const realPath = fs.realpathSync(current);
  if (!realPath.startsWith(`${root}${path.sep}`) || !fs.statSync(realPath).isFile()) {
    fail('RELEASE_MANIFEST_INVALID', `${label} is outside the artifact root or is not a file`);
  }
  return realPath;
}

function readReleaseManifest(filename) {
  const identity = regularFileIdentity(filename, '--release-manifest');
  if (identity.sizeBytes === 0 || identity.sizeBytes > MAX_RELEASE_MANIFEST_BYTES) {
    fail('RELEASE_MANIFEST_INVALID', 'aggregate release manifest size is outside the reviewed bound');
  }
  try {
    return { identity, value: JSON.parse(fs.readFileSync(identity.path, 'utf8')) };
  } catch {
    fail('RELEASE_MANIFEST_INVALID', 'aggregate release manifest is not valid JSON');
  }
}

function candidateFileBytes(repoRoot, commit, relativePath) {
  if (!/^[0-9a-f]{40}$/.test(commit) || !/^[A-Za-z0-9._/-]+$/.test(relativePath) || relativePath.includes('..')) {
    fail('RELEASE_MANIFEST_INVALID', 'candidate file identity is invalid');
  }
  const result = spawnSync(GIT_EXECUTABLE, [
    '--no-replace-objects', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
    '-c', 'protocol.allow=never', '-C', repoRoot, 'show', `${commit}:${relativePath}`,
  ], {
    encoding: null,
    maxBuffer: 16 * 1024 * 1024,
    env: {
      PATH: process.env.PATH,
      TMPDIR: process.env.TMPDIR,
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_CONFIG_GLOBAL: '/dev/null',
      GIT_NO_LAZY_FETCH: '1',
      GIT_NO_REPLACE_OBJECTS: '1',
    },
  });
  if (result.error || result.signal || result.status !== 0) {
    fail('RELEASE_MANIFEST_INVALID', `candidate file is unavailable: ${relativePath}`);
  }
  return result.stdout;
}

function utcNow() {
  return new Date().toISOString();
}

function executableIdentity(filename, label) {
  if (typeof filename !== 'string' || !path.isAbsolute(filename)) {
    fail('ARGUMENT_INVALID', `${label} must be an absolute executable path`);
  }
  let realPath;
  let stat;
  try {
    realPath = fs.realpathSync(filename);
    stat = fs.statSync(realPath);
  } catch {
    fail('ARGUMENT_INVALID', `${label} is missing or unreadable`);
  }
  if (!stat.isFile() || (stat.mode & 0o111) === 0) {
    fail('ARGUMENT_INVALID', `${label} must resolve to an executable regular file`);
  }
  return {
    path: realPath,
    sizeBytes: stat.size,
    sha256: sha256Hex(fs.readFileSync(realPath)),
  };
}

function nodeInterpreterIdentity() {
  const identity = executableIdentity(process.execPath, 'Node interpreter');
  if (typeof process.version !== 'string' || !/^v\d+\.\d+\.\d+$/.test(process.version)) {
    fail('PARITY_COMMAND_MISMATCH', 'Node interpreter version is unavailable');
  }
  return { ...identity, version: process.version };
}

function verifyNodeInterpreterIdentity(expected) {
  const actual = nodeInterpreterIdentity();
  if (actual.path !== expected.path || actual.sizeBytes !== expected.sizeBytes ||
      actual.sha256 !== expected.sha256 || actual.version !== expected.version) {
    fail('PARITY_COMMAND_MISMATCH', 'Node interpreter identity changed after preflight');
  }
  return expected;
}

function durableWriteJson(filename, value) {
  const parent = path.dirname(filename);
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  const temporary = `${filename}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
  const bytes = Buffer.from(`${JSON.stringify(value, null, 2)}\n`, 'utf8');
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, bytes);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporary, filename);
    const parentDescriptor = fs.openSync(parent, fs.constants.O_RDONLY);
    try {
      fs.fsyncSync(parentDescriptor);
    } finally {
      fs.closeSync(parentDescriptor);
    }
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    fs.rmSync(temporary, { force: true });
  }
}

function commandEvidence(result) {
  const stdout = Buffer.isBuffer(result.stdout) ? result.stdout : Buffer.from(result.stdout ?? '');
  const stderr = Buffer.isBuffer(result.stderr) ? result.stderr : Buffer.from(result.stderr ?? '');
  return {
    exitCode: result.status,
    signal: result.signal ?? null,
    stdoutBytes: stdout.length,
    stdoutSha256: sha256Hex(stdout),
    stderrBytes: stderr.length,
    stderrSha256: sha256Hex(stderr),
  };
}

function run(executable, args, options = {}) {
  const result = spawnSync(executable, args, {
    cwd: options.cwd,
    env: options.env ?? {},
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) {
    return {
      ...result,
      status: null,
      stdout: result.stdout ?? '',
      stderr: result.stderr ?? '',
    };
  }
  return result;
}

function parseJsonOutput(result, label) {
  if (result.error || result.signal || result.status !== 0) {
    fail('CLI_PREFLIGHT_FAILED', `${label} did not complete successfully`);
  }
  try {
    return JSON.parse(result.stdout);
  } catch {
    fail('CLI_PREFLIGHT_FAILED', `${label} did not return JSON`);
  }
}

function projectRows(value) {
  if (Array.isArray(value)) return value;
  if (isObject(value) && Array.isArray(value.projects)) return value.projects;
  fail('PROJECT_MISMATCH', 'Supabase project discovery returned an unsupported shape');
}

function projectReference(row) {
  if (!isObject(row)) return null;
  for (const field of ['id', 'ref', 'project_ref', 'projectRef']) {
    if (typeof row[field] === 'string') return row[field];
  }
  return null;
}

function functionRows(value) {
  if (Array.isArray(value)) return value;
  if (isObject(value) && Array.isArray(value.functions)) return value.functions;
  fail('FUNCTION_LIST_INVALID', 'Supabase function discovery returned an unsupported shape');
}

function normalizeFunctionIdentity(row) {
  if (!isObject(row)) return null;
  const role = typeof row.slug === 'string' ? row.slug : (typeof row.name === 'string' ? row.name : null);
  if (!role) return null;
  const id = typeof row.id === 'string' ? row.id
    : (typeof row.function_id === 'string' ? row.function_id : null);
  const version = (typeof row.version === 'string' || Number.isSafeInteger(row.version))
    ? String(row.version) : null;
  return {
    role,
    id,
    version,
    status: typeof row.status === 'string' ? row.status : null,
    updatedAt: typeof row.updated_at === 'string' ? row.updated_at
      : (typeof row.updatedAt === 'string' ? row.updatedAt : null),
    verifyJwt: typeof row.verify_jwt === 'boolean' ? row.verify_jwt
      : (typeof row.verifyJwt === 'boolean' ? row.verifyJwt : null),
  };
}

function indexedFunctionIdentities(value) {
  const indexed = new Map();
  for (const row of functionRows(value)) {
    const identity = normalizeFunctionIdentity(row);
    if (!identity || !HOSTED_FUNCTIONS.includes(identity.role)) continue;
    if (indexed.has(identity.role)) fail('FUNCTION_LIST_INVALID', `duplicate hosted function identity for ${identity.role}`);
    indexed.set(identity.role, identity);
  }
  return indexed;
}

function listFunctions(cliPath, environment) {
  const result = run(cliPath, [
    'functions', 'list', '--project-ref', HOSTED_PROJECT_REF, '--output', 'json',
  ], { env: environment });
  const value = parseJsonOutput(result, 'Supabase function discovery');
  return { result, indexed: indexedFunctionIdentities(value) };
}

function requireActiveNoJwtFunctions(indexed, label) {
  for (const role of HOSTED_FUNCTIONS) {
    const identity = indexed.get(role);
    if (!identity?.id || !identity.version || identity.status !== 'ACTIVE' || identity.verifyJwt !== false) {
      fail('FUNCTION_IDENTITY_UNVERIFIED',
        `${label} requires ${role} to have an ID, version, ACTIVE status and verify_jwt=false`);
    }
  }
}

function identityRecord(indexed) {
  return HOSTED_FUNCTIONS.map((role) => indexed.get(role) ?? {
    role,
    id: null,
    version: null,
    status: null,
    updatedAt: null,
    verifyJwt: null,
  });
}

function parseOctal(field, label) {
  const text = field.toString('ascii').replace(/\0.*$/, '').trim();
  if (!/^[0-7]+$/.test(text)) fail('BUNDLE_ARCHIVE_INVALID', `${label} is not valid octal`);
  return Number.parseInt(text, 8);
}

function parseTar(archive) {
  const entries = [];
  let offset = 0;
  while (offset + 512 <= archive.length) {
    const header = archive.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const name = header.subarray(0, 100).toString('utf8').replace(/\0.*$/, '');
    const size = parseOctal(header.subarray(124, 136), `tar size for ${name || '<empty>'}`);
    const mode = parseOctal(header.subarray(100, 108), `tar mode for ${name || '<empty>'}`);
    const type = header[156];
    if (!name || (type !== 0 && type !== 0x30) || !Number.isSafeInteger(size) || size < 0) {
      fail('BUNDLE_ARCHIVE_INVALID', 'bundle tar contains an unsupported entry');
    }
    const start = offset + 512;
    const end = start + size;
    if (end > archive.length) fail('BUNDLE_ARCHIVE_INVALID', `bundle tar entry is truncated: ${name}`);
    entries.push({ name, mode, bytes: archive.subarray(start, end) });
    offset = end + ((512 - (size % 512)) % 512);
  }
  return entries;
}

function stageVerifiedArchive(bundleDirectory, manifest) {
  const archivePath = path.join(path.resolve(bundleDirectory), manifest.bundle.filename);
  const archive = fs.readFileSync(archivePath);
  const entries = parseTar(archive);
  const expectedNames = [METADATA_NAME, ...manifest.files.map((file) => file.path)];
  if (JSON.stringify(entries.map((entry) => entry.name)) !== JSON.stringify(expectedNames)) {
    fail('BUNDLE_ARCHIVE_INVALID', 'bundle tar entry set or order differs from the verified manifest');
  }
  const stagingRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'frwhoop-hosted-edge-'));
  try {
    for (const [index, file] of manifest.files.entries()) {
      const entry = entries[index + 1];
      if (entry.mode !== (file.mode === '100755' ? 0o755 : 0o644) ||
          entry.bytes.length !== file.sizeBytes || sha256Hex(entry.bytes) !== file.sha256) {
        fail('BUNDLE_ARCHIVE_INVALID', `bundle tar source identity differs: ${file.path}`);
      }
      const destination = path.join(stagingRoot, ...file.path.split('/'));
      fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
      fs.writeFileSync(destination, entry.bytes, { mode: entry.mode });
      fs.chmodSync(destination, entry.mode);
    }
    verifyStagedSource(stagingRoot, manifest);
    return stagingRoot;
  } catch (error) {
    fs.rmSync(stagingRoot, { recursive: true, force: true });
    throw error;
  }
}

function verifyStagedSource(stagingRoot, manifest) {
  for (const file of manifest.files) {
    const filename = path.join(stagingRoot, ...file.path.split('/'));
    let stat;
    try {
      stat = fs.lstatSync(filename);
    } catch {
      fail('STAGED_SOURCE_MUTATED', `staged source is missing: ${file.path}`);
    }
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== file.sizeBytes ||
        (stat.mode & 0o777) !== (file.mode === '100755' ? 0o755 : 0o644) ||
        sha256Hex(fs.readFileSync(filename)) !== file.sha256) {
      fail('STAGED_SOURCE_MUTATED', `staged source identity changed: ${file.path}`);
    }
  }
}

function parseCliVersion(result) {
  if (result.error || result.signal || result.status !== 0) {
    fail('CLI_PREFLIGHT_FAILED', 'Supabase CLI version check failed');
  }
  const match = /(?:^|\s)(\d+\.\d+\.\d+)(?:\s|$)/.exec(result.stdout.trim());
  if (!match) fail('CLI_PREFLIGHT_FAILED', 'Supabase CLI returned an unsupported version');
  return match[1];
}

function verifyParityCommandContract(result) {
  if (result.error || result.signal || result.status !== 0) {
    fail('PARITY_COMMAND_MISMATCH', 'parity command contract discovery failed');
  }
  let value;
  try {
    value = JSON.parse(result.stdout);
  } catch {
    fail('PARITY_COMMAND_MISMATCH', 'parity command contract discovery did not return JSON');
  }
  if (!isObject(value) || JSON.stringify(Object.keys(value).sort()) !==
      JSON.stringify(Object.keys(PARITY_CONTRACT).sort()) ||
      value.kind !== PARITY_CONTRACT.kind || value.schemaVersion !== PARITY_CONTRACT.schemaVersion) {
    fail('PARITY_COMMAND_MISMATCH', 'parity command contract differs from the hosted release contract');
  }
  return value;
}

function verifyParityResult(value, manifest) {
  exactKeys(value, [
    'status', 'projectRef', 'bundleSha256', 'sourceCommit', 'account', 'enrollment', 'parity',
  ], 'parity result');
  if (value.status !== 'PASS' || value.projectRef !== HOSTED_PROJECT_REF ||
      value.bundleSha256 !== manifest.bundle.sha256 || value.sourceCommit !== manifest.source.commit) {
    fail('PARITY_FAILED', 'route parity result does not bind the deployed release');
  }
  for (const name of ['account', 'enrollment']) {
    exactKeys(value[name], ['status', 'responseEnvelopeSha256'], `${name} route result`);
    if (value[name].status !== 'PASS') fail('PARITY_FAILED', `${name} score route did not pass`);
    requireSha256(value[name].responseEnvelopeSha256, `${name} response envelope SHA-256`);
  }
  exactKeys(value.parity, ['status', 'comparisonSha256'], 'route parity comparison');
  if (value.parity.status !== 'PASS') fail('PARITY_FAILED', 'account/enrollment route parity did not pass');
  requireSha256(value.parity.comparisonSha256, 'route parity comparison SHA-256');
  if (value.account.responseEnvelopeSha256 !== value.enrollment.responseEnvelopeSha256) {
    fail('PARITY_FAILED', 'account and enrollment response envelope identities differ');
  }
  return value;
}

function safeState(status, deployed, remaining) {
  if (status === 'SUCCEEDED') {
    return {
      classification: 'DEPLOYED_AND_ROUTE_PARITY_VERIFIED',
      forward: 'Preserve this receipt and continue only with separately authorized release checks.',
      rollback: 'No automatic rollback was attempted; use separately reviewed prior function versions if rollback is authorized.',
      automaticRollback: 'DISABLED',
    };
  }
  if (deployed.length === 0 && ['INITIALIZED', 'PREFLIGHT_VERIFIED', 'PREFLIGHT_FAILED'].includes(status)) {
    return {
      classification: 'NO_REMOTE_FUNCTION_MUTATION_STARTED',
      forward: 'Repair preflight evidence and start a new receipt from the same verified bundle.',
      rollback: 'No function rollback is required by this attempt.',
      automaticRollback: 'DISABLED',
    };
  }
  if (deployed.length === 0) {
    return {
      classification: 'FUNCTION_MUTATION_OUTCOME_UNKNOWN_RECONCILIATION_REQUIRED',
      forward: `Read the hosted function list and reconcile the attempted role before continuing: ${remaining.join(', ')}.`,
      rollback: 'Do not assume the failed command was atomic. Use separately reviewed prior bundle bytes and authority if rollback is required.',
      automaticRollback: 'DISABLED',
    };
  }
  return {
    classification: remaining.length === 0
      ? 'ALL_FUNCTIONS_DEPLOYED_ROUTE_PARITY_UNVERIFIED'
      : 'MIXED_FUNCTION_VERSIONS_RECONCILIATION_REQUIRED',
    forward: remaining.length === 0
      ? 'Investigate the parity evidence, then rerun the required parity check before release acceptance.'
      : `Reconcile the recorded remote versions, then start a new complete six-role deployment from the same exact bundle; unresolved roles are: ${remaining.join(', ')}.`,
    rollback: 'Do not guess or auto-deploy old source. Rollback requires the recorded prior identities plus separately reviewed prior bundle bytes and authority.',
    automaticRollback: 'DISABLED',
  };
}

function parseFunctions(value) {
  if (typeof value !== 'string') fail('ARGUMENT_INVALID', '--functions is required');
  const functions = value.split(',');
  if (JSON.stringify(functions) !== JSON.stringify(HOSTED_FUNCTIONS)) {
    fail('ROLE_MISMATCH', `--functions must be exactly ${HOSTED_FUNCTIONS.join(',')}`);
  }
  return functions;
}

export function deployHostedEdge(options, dependencies = {}) {
  const receiptPath = path.resolve(options.receipt ?? '');
  if (!options.receipt || fs.existsSync(receiptPath)) {
    fail('ARGUMENT_INVALID', '--receipt must name a new receipt file');
  }

  const receipt = {
    schemaVersion: RECEIPT_SCHEMA_VERSION,
    kind: 'frwhoop-hosted-edge-deployment-receipt',
    receiptId: crypto.randomUUID(),
    createdAt: utcNow(),
    updatedAt: utcNow(),
    status: 'INITIALIZED',
    projectRef: options.projectRef ?? null,
    requestedFunctions: typeof options.functions === 'string' ? options.functions.split(',') : [],
    release: null,
    bundle: null,
    cli: null,
    parityCommand: null,
    preDeploymentFunctions: [],
    deployments: [],
    finalFunctions: [],
    parityVerification: null,
    currentFunction: null,
    safeState: safeState('INITIALIZED', [], HOSTED_FUNCTIONS),
    failure: null,
  };
  const persist = () => {
    receipt.updatedAt = utcNow();
    durableWriteJson(receiptPath, receipt);
  };
  persist();

  let stagingRoot = null;
  let parityRoot = null;
  try {
    if (options.projectRef !== HOSTED_PROJECT_REF) {
      fail('PROJECT_MISMATCH', `--project-ref must be exactly ${HOSTED_PROJECT_REF}`);
    }
    const functions = parseFunctions(options.functions);
    requireSha256(options.expectedBundleSha256, '--expected-bundle-sha');
    requireSha256(options.expectedCliSha256, '--expected-cli-sha');
    if (typeof options.expectedCliVersion !== 'string' || !/^\d+\.\d+\.\d+$/.test(options.expectedCliVersion)) {
      fail('ARGUMENT_INVALID', '--expected-cli-version must be an exact semantic version');
    }

    const repoRoot = fs.realpathSync(options.repoRoot);
    const artifactRoot = fs.realpathSync(options.artifactRoot);
    const releaseInput = readReleaseManifest(options.releaseManifest);
    const releaseVerifier = dependencies.verifyReleaseManifest ?? verifyAggregateReleaseManifest;
    let release;
    try {
      release = releaseVerifier({
        repoRoot,
        artifactRoot,
        manifest: releaseInput.value,
      });
    } catch {
      fail('RELEASE_MANIFEST_INVALID', 'aggregate release manifest verification failed');
    }
    if (release !== releaseInput.value && JSON.stringify(release) !== JSON.stringify(releaseInput.value)) {
      fail('RELEASE_MANIFEST_INVALID', 'aggregate release verifier returned a different manifest');
    }
    const releaseEdge = release?.artifacts?.edge;
    if (!releaseEdge?.file || releaseEdge.kind !== 'edge-source-bundle' ||
        releaseEdge.file.sha256 !== options.expectedBundleSha256) {
      fail('RELEASE_MANIFEST_INVALID', 'requested Edge bundle is not the aggregate release Edge artifact');
    }
    const aggregateBundleFile = releaseArtifactFile(artifactRoot, releaseEdge.file.path, 'Edge bundle');
    const aggregateBundleDirectory = fs.realpathSync(path.dirname(aggregateBundleFile));
    if (fs.realpathSync(options.bundle) !== aggregateBundleDirectory) {
      fail('RELEASE_MANIFEST_INVALID', '--bundle does not name the aggregate release Edge artifact directory');
    }
    receipt.release = {
      manifest: releaseInput.identity,
      manifestFingerprintSha256: release.manifestFingerprintSha256,
      sourceCommit: release.source.commit,
      sourceTree: release.source.tree,
      artifactRoot,
    };

    const manifest = verifyEdgeSourceBundle(options.bundle, {
      expectedBundleSha256: options.expectedBundleSha256,
    });
    if (manifest.source.commit !== release.source.commit || manifest.source.tree !== release.source.tree ||
        manifest.bundle.sha256 !== releaseEdge.file.sha256 ||
        manifest.bundle.sizeBytes !== releaseEdge.file.sizeBytes ||
        path.basename(aggregateBundleFile) !== manifest.bundle.filename) {
      fail('RELEASE_MANIFEST_INVALID', 'verified Edge bundle differs from the aggregate release candidate');
    }
    if (JSON.stringify(manifest.deployableFunctions) !== JSON.stringify(functions)) {
      fail('ROLE_MISMATCH', 'verified bundle function roles differ from the hosted deployment request');
    }
    receipt.bundle = {
      directory: path.resolve(options.bundle),
      sourceCommit: manifest.source.commit,
      sourceTree: manifest.source.tree,
      sha256: manifest.bundle.sha256,
      sizeBytes: manifest.bundle.sizeBytes,
      fileCount: manifest.files.length,
      functions: [...manifest.deployableFunctions],
    };

    const sourceEnvironment = options.environment ?? process.env;
    const cliEnvironment = selectedEnvironment(sourceEnvironment, SUPABASE_ENVIRONMENT);
    const parityEnvironment = selectedEnvironment(sourceEnvironment, PARITY_ENVIRONMENT);
    if (!cliEnvironment.SUPABASE_ACCESS_TOKEN) {
      fail('CONFIGURATION_MISSING', 'SUPABASE_ACCESS_TOKEN is required before hosted discovery');
    }
    for (const name of PARITY_CREDENTIALS) {
      if (!parityEnvironment[name]) {
        fail('CONFIGURATION_MISSING', `${name} is required before any hosted function mutation`);
      }
    }
    const cli = executableIdentity(options.supabaseCli, '--supabase-cli');
    if (cli.sha256 !== options.expectedCliSha256) {
      fail('CLI_IDENTITY_MISMATCH', 'Supabase CLI SHA-256 differs from --expected-cli-sha');
    }
    const parityCommand = executableIdentity(options.parityCommand, '--parity-command');
    const nodeInterpreter = nodeInterpreterIdentity();
    const candidateParityBytes = candidateFileBytes(repoRoot, release.source.commit, CANDIDATE_PARITY_PATH);
    const candidateParitySha256 = sha256Hex(candidateParityBytes);
    if (parityCommand.sha256 !== candidateParitySha256 ||
        !fs.readFileSync(parityCommand.path).equals(candidateParityBytes)) {
      fail('PARITY_COMMAND_MISMATCH', 'parity command bytes differ from the exact release candidate');
    }
    parityRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'frwhoop-hosted-parity-'));
    const stagedParityCommand = path.join(parityRoot, 'verify-hosted-score-route-parity.mjs');
    fs.writeFileSync(stagedParityCommand, candidateParityBytes, { mode: 0o700 });
    fs.chmodSync(stagedParityCommand, 0o700);
    const versionResult = run(cli.path, ['--version'], { env: cliEnvironment });
    const version = parseCliVersion(versionResult);
    if (version !== options.expectedCliVersion) {
      fail('CLI_VERSION_MISMATCH', 'Supabase CLI version differs from --expected-cli-version');
    }
    receipt.cli = {
      ...cli,
      expectedSha256: options.expectedCliSha256,
      expectedVersion: options.expectedCliVersion,
      version,
      environmentKeys: Object.keys(cliEnvironment).sort(),
      versionCommand: commandEvidence(versionResult),
    };
    verifyNodeInterpreterIdentity(nodeInterpreter);
    const parityContractResult = run(nodeInterpreter.path, [
      stagedParityCommand, '--contract-version',
    ], { env: parityEnvironment });
    const parityContract = verifyParityCommandContract(parityContractResult);
    receipt.parityCommand = {
      ...parityCommand,
      interpreter: nodeInterpreter,
      candidatePath: CANDIDATE_PARITY_PATH,
      candidateSha256: candidateParitySha256,
      environmentKeys: Object.keys(parityEnvironment).sort(),
      contract: parityContract,
      contractCommand: commandEvidence(parityContractResult),
    };

    const projectsResult = run(cli.path, ['projects', 'list', '--output', 'json'], { env: cliEnvironment });
    const projects = projectRows(parseJsonOutput(projectsResult, 'Supabase project discovery'));
    if (!projects.some((project) => projectReference(project) === HOSTED_PROJECT_REF)) {
      fail('PROJECT_MISMATCH', 'authenticated Supabase CLI context does not contain the required project');
    }
    receipt.cli.projectDiscovery = commandEvidence(projectsResult);

    const before = listFunctions(cli.path, cliEnvironment);
    receipt.cli.preDeploymentFunctionDiscovery = commandEvidence(before.result);
    receipt.preDeploymentFunctions = identityRecord(before.indexed);
    stagingRoot = stageVerifiedArchive(options.bundle, manifest);
    verifyStagedSource(stagingRoot, manifest);

    receipt.status = 'PREFLIGHT_VERIFIED';
    receipt.safeState = safeState(receipt.status, [], functions);
    persist();

    for (const role of functions) {
      verifyStagedSource(stagingRoot, manifest);
      receipt.status = 'DEPLOYING';
      receipt.currentFunction = role;
      receipt.deployments.push({
        role,
        state: 'STARTED',
        startedAt: utcNow(),
        finishedAt: null,
        command: null,
        identity: null,
      });
      receipt.safeState = safeState(receipt.status,
        receipt.deployments.filter((entry) => entry.state === 'VERIFIED').map((entry) => entry.role),
        functions.filter((candidate) => !receipt.deployments.some((entry) => entry.role === candidate && entry.state === 'VERIFIED')));
      persist();

      const deployment = receipt.deployments.at(-1);
      const deployResult = run(cli.path, [
        'functions', 'deploy', role,
        '--project-ref', HOSTED_PROJECT_REF,
        '--workdir', stagingRoot,
        '--use-api',
        '--no-verify-jwt',
        '--output', 'json',
      ], { cwd: stagingRoot, env: cliEnvironment });
      deployment.command = commandEvidence(deployResult);
      deployment.finishedAt = utcNow();
      if (deployResult.error || deployResult.signal || deployResult.status !== 0) {
        deployment.state = 'FAILED';
        fail('FUNCTION_DEPLOY_FAILED', `hosted function deployment failed for ${role}`);
      }
      deployment.state = 'COMMAND_SUCCEEDED_IDENTITY_PENDING';
      persist();
      verifyStagedSource(stagingRoot, manifest);

      const after = listFunctions(cli.path, cliEnvironment);
      deployment.discoveryCommand = commandEvidence(after.result);
      requireActiveNoJwtFunctions(after.indexed, `post-deploy discovery for ${role}`);
      const identity = after.indexed.get(role);
      if (!identity || !identity.id || !identity.version) {
        fail('FUNCTION_IDENTITY_UNVERIFIED', `post-deploy identity/version is unavailable for ${role}`);
      }
      const prior = before.indexed.get(role);
      if (prior && prior.id === identity.id && prior.version === identity.version) {
        fail('FUNCTION_IDENTITY_UNVERIFIED', `post-deploy identity/version did not advance for ${role}`);
      }
      deployment.identity = identity;
      deployment.state = 'VERIFIED';
      receipt.currentFunction = null;
      receipt.safeState = safeState(receipt.status,
        receipt.deployments.filter((entry) => entry.state === 'VERIFIED').map((entry) => entry.role),
        functions.filter((candidate) => !receipt.deployments.some((entry) => entry.role === candidate && entry.state === 'VERIFIED')));
      persist();
    }

    verifyStagedSource(stagingRoot, manifest);
    const finalDiscovery = listFunctions(cli.path, cliEnvironment);
    receipt.cli.finalFunctionDiscovery = commandEvidence(finalDiscovery.result);
    receipt.finalFunctions = identityRecord(finalDiscovery.indexed);
    requireActiveNoJwtFunctions(finalDiscovery.indexed, 'final hosted function discovery');
    for (const deployment of receipt.deployments) {
      const finalIdentity = finalDiscovery.indexed.get(deployment.role);
      if (!finalIdentity || finalIdentity.id !== deployment.identity?.id ||
          finalIdentity.version !== deployment.identity?.version) {
        fail('FUNCTION_IDENTITY_UNVERIFIED',
          `final hosted identity/version changed after deployment for ${deployment.role}`);
      }
    }

    receipt.status = 'FUNCTIONS_DEPLOYED_PARITY_PENDING';
    receipt.safeState = safeState(receipt.status, functions, []);
    persist();
    if (sha256Hex(fs.readFileSync(stagedParityCommand)) !== candidateParitySha256) {
      fail('PARITY_COMMAND_MISMATCH', 'staged parity command changed after preflight');
    }
    verifyNodeInterpreterIdentity(nodeInterpreter);
    const parityResult = run(nodeInterpreter.path, [
      stagedParityCommand, '--project-ref', HOSTED_PROJECT_REF,
      '--bundle-sha256', manifest.bundle.sha256,
      '--source-commit', manifest.source.commit,
    ], { env: parityEnvironment });
    const parityEvidence = commandEvidence(parityResult);
    if (parityResult.error || parityResult.signal || parityResult.status !== 0) {
      receipt.parityVerification = { status: 'FAIL', command: parityEvidence, result: null };
      fail('PARITY_FAILED', 'account/enrollment score route parity command failed');
    }
    let parsedParity;
    try {
      parsedParity = JSON.parse(parityResult.stdout);
    } catch {
      receipt.parityVerification = { status: 'FAIL', command: parityEvidence, result: null };
      fail('PARITY_RESULT_INVALID', 'route parity command did not return JSON');
    }
    receipt.parityVerification = { status: 'FAIL', command: parityEvidence, result: null };
    const verifiedParity = verifyParityResult(parsedParity, manifest);
    receipt.parityVerification = {
      status: 'PASS',
      command: parityEvidence,
      result: verifiedParity,
    };
    receipt.status = 'SUCCEEDED';
    receipt.safeState = safeState(receipt.status, functions, []);
    receipt.failure = null;
    persist();
    return receipt;
  } catch (error) {
    const code = error instanceof HostedEdgeError ? error.code
      : (error?.message?.startsWith('INVALID_EDGE_BUNDLE:') ? 'BUNDLE_INVALID' : 'UNEXPECTED_FAILURE');
    const deployed = receipt.deployments.filter((entry) => entry.state === 'VERIFIED').map((entry) => entry.role);
    const remaining = HOSTED_FUNCTIONS.filter((role) => !deployed.includes(role));
    receipt.status = receipt.deployments.length === 0
      ? 'PREFLIGHT_FAILED'
      : (remaining.length === 0 ? 'PARITY_FAILED' : 'PARTIAL_FAILURE');
    receipt.currentFunction = null;
    receipt.failure = {
      code,
      message: error instanceof HostedEdgeError ? error.message
        : (code === 'BUNDLE_INVALID' ? error.message : 'unexpected hosted deployment failure'),
    };
    receipt.safeState = safeState(receipt.status, deployed, remaining);
    persist();
    throw new HostedEdgeError(code, receipt.failure.message);
  } finally {
    if (stagingRoot) fs.rmSync(stagingRoot, { recursive: true, force: true });
    if (parityRoot) fs.rmSync(parityRoot, { recursive: true, force: true });
  }
}

function parseFlags(args) {
  const allowed = new Set([
    '--project-ref', '--repo-root', '--artifact-root', '--release-manifest', '--bundle',
    '--expected-bundle-sha', '--functions', '--supabase-cli', '--expected-cli-version',
    '--expected-cli-sha', '--parity-command', '--receipt',
  ]);
  const values = {};
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (!allowed.has(flag) || value === undefined || value.startsWith('--') || values[flag] !== undefined) {
      fail('ARGUMENT_INVALID', `usage error near ${flag ?? '<end>'}`);
    }
    values[flag] = value;
  }
  return values;
}

function usage() {
  return [
    'Usage:',
    '  node infra/vps/scripts/deploy-hosted-edge-functions.mjs deploy \\',
    `    --project-ref ${HOSTED_PROJECT_REF} --repo-root REPOSITORY --artifact-root ARTIFACTS \\`,
    '    --release-manifest /ABSOLUTE/PATH --bundle DIRECTORY --expected-bundle-sha SHA256 \\',
    `    --functions ${HOSTED_FUNCTIONS.join(',')} \\`,
    '    --supabase-cli /ABSOLUTE/PATH --expected-cli-version X.Y.Z --expected-cli-sha SHA256 \\',
    '    --parity-command /ABSOLUTE/PATH --receipt NEW_FILE',
  ].join('\n');
}

function main(argv) {
  const [command, ...rest] = argv;
  if (command !== 'deploy') fail('ARGUMENT_INVALID', usage());
  const flags = parseFlags(rest);
  for (const required of [
    '--project-ref', '--repo-root', '--artifact-root', '--release-manifest', '--bundle',
    '--expected-bundle-sha', '--functions', '--supabase-cli', '--expected-cli-version',
    '--expected-cli-sha', '--parity-command', '--receipt',
  ]) {
    if (!flags[required]) fail('ARGUMENT_INVALID', usage());
  }
  const receipt = deployHostedEdge({
    projectRef: flags['--project-ref'],
    repoRoot: flags['--repo-root'],
    artifactRoot: flags['--artifact-root'],
    releaseManifest: flags['--release-manifest'],
    bundle: flags['--bundle'],
    expectedBundleSha256: flags['--expected-bundle-sha'],
    functions: flags['--functions'],
    supabaseCli: flags['--supabase-cli'],
    expectedCliVersion: flags['--expected-cli-version'],
    expectedCliSha256: flags['--expected-cli-sha'],
    parityCommand: flags['--parity-command'],
    receipt: flags['--receipt'],
  });
  process.stdout.write(`${JSON.stringify({
    status: receipt.status,
    projectRef: receipt.projectRef,
    sourceCommit: receipt.bundle.sourceCommit,
    bundleSha256: receipt.bundle.sha256,
    receipt: path.resolve(flags['--receipt']),
  })}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    const code = error instanceof HostedEdgeError ? error.code : 'UNEXPECTED_FAILURE';
    process.stderr.write(`HOSTED_EDGE_${code}: ${error.message}\n`);
    process.exitCode = 1;
  }
}
