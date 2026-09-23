#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const KIND = 'frwhoop-deployment-source-bundle';
const BUNDLE_NAME = 'deployment-source-bundle.tar';
const MANIFEST_NAME = 'deployment-source-bundle-manifest.json';
const METADATA_NAME = 'deployment-source-bundle-metadata.json';
const PAYLOAD_NAME = 'payload';
const GIT_EXECUTABLE = '/usr/bin/git';
const RELEASE_TOOL_EXTENSIONS = new Set(['.java', '.mjs', '.py', '.sql']);
const MODES = new Map([['100644', 0o644], ['100755', 0o755]]);

export const INCLUDED_ROOTS = Object.freeze([
  'Tools/prepare-ios-sideload-app.sh',
  'Tools/release/*.{java,mjs,py,sql}',
  'infra/vps/**',
]);

export const REQUIRED_CAPABILITIES = Object.freeze({
  aggregateVerification: Object.freeze(['Tools/release/release-artifact-manifest.mjs']),
  applySelfHostedMigrations: Object.freeze([
    'infra/vps/scripts/apply-migrations.sh',
    'infra/vps/scripts/scoring-migration-catalog.mjs',
    'infra/vps/scripts/scoring-migration-plan.mjs',
    'Tools/release/verify-integrated-schema.sql',
  ]),
  applyHostedMigrations: Object.freeze([
    'Tools/release/hosted-migration-release.mjs',
    'Tools/release/generate-migration-manifest.mjs',
    'Tools/release/verify-integrated-schema.sql',
  ]),
  deploySelfHostedEdge: Object.freeze(['infra/vps/scripts/deploy-edge-functions.sh']),
  deployHostedEdge: Object.freeze([
    'infra/vps/scripts/deploy-hosted-edge-functions.mjs',
    'infra/vps/scripts/verify-hosted-score-route-parity.mjs',
  ]),
  deployWorkers: Object.freeze([
    'infra/vps/scripts/deploy-scoring-service.sh',
    'infra/vps/scripts/scorer-image-release.mjs',
  ]),
  workerDeploymentBinding: Object.freeze([
    'Tools/release/release-artifact-manifest.mjs',
    'infra/vps/scripts/deploy-scoring-service.sh',
    'infra/vps/scripts/scoring-hosted-query.py',
    'infra/vps/scripts/remote/read-scoring-query.sh',
    'infra/vps/scripts/verify-pinned-postgres-client.py',
  ]),
  deploymentBundle: Object.freeze(['Tools/release/deployment-source-bundle.mjs']),
  deploymentRunbook: Object.freeze(['infra/vps/SERVER_PIPELINE_DEPLOYMENT.md']),
  edgeBundle: Object.freeze(['Tools/release/edge-source-bundle.mjs']),
  fleetCompose: Object.freeze(['infra/vps/templates/docker-compose.fleet.yml']),
  migrationManifest: Object.freeze(['Tools/release/generate-migration-manifest.mjs']),
  mobileArtifactVerification: Object.freeze([
    'Tools/prepare-ios-sideload-app.sh',
    'Tools/release/VerifyApk.java',
    'Tools/release/inspect_ipa.py',
  ]),
  rollbackAndRestore: Object.freeze([
    'infra/vps/scripts/remote/04-backup.sh',
    'infra/vps/scripts/remote/05-restore-drill.sh',
    'infra/vps/scripts/remote/12-truncate-for-restore.sh',
  ]),
  selectedV1Image: Object.freeze(['infra/vps/templates/Dockerfile.baseline']),
  intakeImageAndCompose: Object.freeze([
    'infra/vps/templates/Dockerfile.intake',
    'infra/vps/templates/docker-compose.intake.yml',
  ]),
  verifyRuntimeAndProgress: Object.freeze([
    'infra/vps/scripts/remote/verify-scoring-runtime.sh',
    'infra/vps/scripts/scoring-progress.sh',
  ]),
});

function invalid(message) { throw new Error(`INVALID_DEPLOYMENT_BUNDLE: ${message}`); }
function notReady(message) { throw new Error(`NOT_READY: ${message}`); }
function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function hash(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function compare(left, right) { return Buffer.compare(Buffer.from(left), Buffer.from(right)); }
function same(actual, expected) { return Array.isArray(actual) && JSON.stringify(actual) === JSON.stringify(expected); }

function exactKeys(value, keys, label) {
  if (!object(value) || !same(Object.keys(value).sort(), [...keys].sort())) invalid(`${label} fields differ`);
}
function sha(value, label) {
  if (typeof value !== 'string' || !/^[0-9a-f]{40}$/.test(value)) invalid(`${label} must be a full Git SHA-1`);
}
function sha256(value, label) {
  if (typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value)) invalid(`${label} must be a SHA-256`);
}
function safePath(value, label) {
  if (typeof value !== 'string' || !value || value.includes('\\') || /[\0-\x1f\x7f]/.test(value) ||
      value.startsWith('/') || path.posix.normalize(value) !== value ||
      value.split('/').some(part => !part || part === '.' || part === '..')) invalid(`${label} is not repository-relative`);
}

function selected(relative) {
  if (relative === 'Tools/prepare-ios-sideload-app.sh') return true;
  if (relative.startsWith('infra/vps/')) return true;
  if (!relative.startsWith('Tools/release/')) return false;
  const suffix = relative.slice('Tools/release/'.length);
  return !suffix.includes('/') && RELEASE_TOOL_EXTENSIONS.has(path.posix.extname(suffix));
}

function git(repo, args, binary = false) {
  const result = spawnSync(GIT_EXECUTABLE, [
    '--no-replace-objects', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
    '-c', 'protocol.allow=never', '-C', repo, ...args,
  ], {
    encoding: binary ? undefined : 'utf8',
    maxBuffer: 64 * 1024 * 1024,
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
    const detail = result.stderr?.toString('utf8').trim();
    notReady(`git ${args[0]} failed${detail ? `: ${detail}` : ''}`);
  }
  return result.stdout;
}

function committedFiles(repo, commit) {
  if (typeof commit !== 'string' || !/^[0-9a-f]{40}$/.test(commit)) {
    notReady('--commit must be a full lowercase 40-character Git SHA');
  }
  const resolved = git(repo, ['rev-parse', '--verify', `${commit}^{commit}`]).trim();
  if (resolved !== commit) notReady('commit did not resolve exactly');
  const tree = git(repo, ['rev-parse', '--verify', `${commit}^{tree}`]).trim();
  const raw = git(repo, ['ls-tree', '-r', '-z', commit, '--',
    'infra/vps', 'Tools/release', 'Tools/prepare-ios-sideload-app.sh'], true);
  const entries = [];
  for (const record of raw.toString('utf8').split('\0')) {
    if (!record) continue;
    const match = /^([0-7]{6}) ([a-z]+) ([0-9a-f]{40})\t(.+)$/.exec(record);
    if (!match) notReady('git ls-tree returned an unsupported record');
    const entry = { mode: match[1], type: match[2], object: match[3], path: match[4] };
    if (!selected(entry.path)) continue;
    if (entry.type !== 'blob' || !MODES.has(entry.mode)) {
      notReady(`selected source is not a regular file: ${entry.path}`);
    }
    entries.push(entry);
  }
  entries.sort((left, right) => compare(left.path, right.path));
  const names = new Set(entries.map(entry => entry.path));
  if (names.size !== entries.length) notReady('selected committed paths are not unique');
  for (const [capability, paths] of Object.entries(REQUIRED_CAPABILITIES)) {
    for (const required of paths) if (!names.has(required)) {
      notReady(`required ${capability} source is missing: ${required}`);
    }
  }
  return { tree, entries };
}

function metadata(source, files) {
  return {
    schemaVersion: 1,
    kind: KIND,
    source,
    includedRoots: [...INCLUDED_ROOTS],
    requiredCapabilities: Object.fromEntries(Object.entries(REQUIRED_CAPABILITIES).map(([key, value]) => [key, [...value]])),
    files,
  };
}

function field(header, offset, length, value, label) {
  const bytes = Buffer.from(value);
  if (bytes.length > length) notReady(`${label} is too long for deterministic ustar`);
  bytes.copy(header, offset);
}
function octal(header, offset, length, value, label) {
  if (!Number.isSafeInteger(value) || value < 0) notReady(`${label} is invalid`);
  const valueOctal = value.toString(8);
  if (valueOctal.length > length - 1) notReady(`${label} is too large for deterministic ustar`);
  field(header, offset, length, `${valueOctal.padStart(length - 1, '0')}\0`, label);
}
function header(entry) {
  const value = Buffer.alloc(512);
  field(value, 0, 100, entry.path, 'tar path');
  octal(value, 100, 8, entry.mode === '100755' ? 0o755 : 0o644, 'tar mode');
  octal(value, 108, 8, 0, 'tar uid');
  octal(value, 116, 8, 0, 'tar gid');
  octal(value, 124, 12, entry.bytes.length, 'tar size');
  octal(value, 136, 12, 0, 'tar mtime');
  value.fill(32, 148, 156);
  value[156] = 48;
  field(value, 257, 6, 'ustar\0', 'tar magic');
  field(value, 263, 2, '00', 'tar version');
  const checksum = value.reduce((sum, byte) => sum + byte, 0);
  field(value, 148, 8, `${checksum.toString(8).padStart(6, '0')}\0 `, 'tar checksum');
  return value;
}
function tarBytes(sourceMetadata, payload) {
  const entries = [{ path: METADATA_NAME, mode: '100644',
    bytes: Buffer.from(`${JSON.stringify(sourceMetadata, null, 2)}\n`) }, ...payload];
  const chunks = [];
  for (const entry of entries) {
    chunks.push(header(entry), entry.bytes);
    const padding = (512 - (entry.bytes.length % 512)) % 512;
    if (padding) chunks.push(Buffer.alloc(padding));
  }
  chunks.push(Buffer.alloc(1024));
  return Buffer.concat(chunks);
}

export function prepareDeploymentSourceBundle({ repoRoot, commit, outputDirectory }) {
  if (!repoRoot || !outputDirectory) notReady('--repo-root and --output are required');
  const repo = path.resolve(repoRoot), output = path.resolve(outputDirectory);
  if (!fs.statSync(repo).isDirectory()) notReady('repository root is not a directory');
  if (fs.existsSync(output)) notReady('output directory already exists');
  const committed = committedFiles(repo, commit);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  const temporary = fs.mkdtempSync(path.join(path.dirname(output), `.${path.basename(output)}.tmp-`));
  try {
    const files = [], payload = [];
    for (const entry of committed.entries) {
      const bytes = git(repo, ['cat-file', 'blob', entry.object], true);
      const destination = path.join(temporary, PAYLOAD_NAME, ...entry.path.split('/'));
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.writeFileSync(destination, bytes, { mode: MODES.get(entry.mode) });
      fs.chmodSync(destination, MODES.get(entry.mode));
      files.push({ path: entry.path, mode: entry.mode, sizeBytes: bytes.length, sha256: hash(bytes) });
      payload.push({ path: entry.path, mode: entry.mode, bytes });
    }
    const sourceMetadata = metadata({ commit, tree: committed.tree }, files);
    const archive = tarBytes(sourceMetadata, payload);
    const manifest = {
      schemaVersion: sourceMetadata.schemaVersion,
      kind: sourceMetadata.kind,
      source: sourceMetadata.source,
      bundle: { filename: BUNDLE_NAME, sizeBytes: archive.length, sha256: hash(archive) },
      includedRoots: sourceMetadata.includedRoots,
      requiredCapabilities: sourceMetadata.requiredCapabilities,
      files: sourceMetadata.files,
    };
    fs.writeFileSync(path.join(temporary, BUNDLE_NAME), archive, { mode: 0o644 });
    fs.writeFileSync(path.join(temporary, MANIFEST_NAME), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 });
    fs.chmodSync(path.join(temporary, BUNDLE_NAME), 0o644);
    fs.chmodSync(path.join(temporary, MANIFEST_NAME), 0o644);
    verifyDeploymentSourceBundle(temporary, { expectedBundleSha256: manifest.bundle.sha256 });
    fs.renameSync(temporary, output);
    return manifest;
  } catch (error) {
    fs.rmSync(temporary, { recursive: true, force: true });
    throw error;
  }
}

function manifestAt(root) {
  const filename = path.join(root, MANIFEST_NAME);
  try {
    const stat = fs.lstatSync(filename);
    if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o777) !== 0o644) invalid('manifest is not a mode-0644 regular file');
    return JSON.parse(fs.readFileSync(filename, 'utf8'));
  } catch (error) {
    if (error?.message?.startsWith('INVALID_DEPLOYMENT_BUNDLE:')) throw error;
    invalid('manifest is missing, unreadable, or invalid JSON');
  }
}

function validateManifest(value, expectedBundleSha256) {
  exactKeys(value, ['schemaVersion', 'kind', 'source', 'bundle', 'includedRoots', 'requiredCapabilities', 'files'], 'manifest');
  if (value.schemaVersion !== 1 || value.kind !== KIND) invalid('manifest kind or schema differs');
  exactKeys(value.source, ['commit', 'tree'], 'source');
  sha(value.source.commit, 'source.commit'); sha(value.source.tree, 'source.tree');
  exactKeys(value.bundle, ['filename', 'sizeBytes', 'sha256'], 'bundle');
  if (value.bundle.filename !== BUNDLE_NAME || !Number.isSafeInteger(value.bundle.sizeBytes) || value.bundle.sizeBytes < 1) {
    invalid('bundle filename or size differs');
  }
  sha256(value.bundle.sha256, 'bundle.sha256');
  if (expectedBundleSha256 !== undefined) {
    sha256(expectedBundleSha256, 'expected bundle SHA-256');
    if (value.bundle.sha256 !== expectedBundleSha256) invalid('bundle SHA-256 differs from expected identity');
  }
  if (!same(value.includedRoots, INCLUDED_ROOTS)) invalid('included roots differ');
  exactKeys(value.requiredCapabilities, Object.keys(REQUIRED_CAPABILITIES), 'requiredCapabilities');
  for (const [capability, paths] of Object.entries(REQUIRED_CAPABILITIES)) {
    if (!same(value.requiredCapabilities[capability], paths)) invalid(`required ${capability} paths differ`);
  }
  if (!Array.isArray(value.files) || !value.files.length) invalid('files must be nonempty');
  const names = new Set();
  let prior = '';
  for (const [index, file] of value.files.entries()) {
    exactKeys(file, ['path', 'mode', 'sizeBytes', 'sha256'], `files[${index}]`);
    safePath(file.path, `files[${index}].path`);
    if (!selected(file.path)) invalid(`unreviewed file path: ${file.path}`);
    if (index && compare(file.path, prior) <= 0) invalid('files are not uniquely byte-sorted');
    prior = file.path; names.add(file.path);
    if (!MODES.has(file.mode) || !Number.isSafeInteger(file.sizeBytes) || file.sizeBytes < 0) invalid(`mode or size differs: ${file.path}`);
    sha256(file.sha256, `files[${index}].sha256`);
  }
  for (const [capability, paths] of Object.entries(REQUIRED_CAPABILITIES)) for (const required of paths) {
    if (!names.has(required)) invalid(`required ${capability} source is missing: ${required}`);
  }
  return value;
}

function walk(directory, relative = '') {
  const files = [], directories = [];
  let entries;
  try { entries = fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => compare(a.name, b.name)); }
  catch { invalid(`payload directory is missing or unreadable: ${relative || PAYLOAD_NAME}`); }
  for (const entry of entries) {
    const name = relative ? `${relative}/${entry.name}` : entry.name;
    const filename = path.join(directory, entry.name), stat = fs.lstatSync(filename);
    if (stat.isSymbolicLink()) invalid(`payload contains a symlink: ${name}`);
    if (stat.isDirectory()) {
      directories.push(name);
      const nested = walk(filename, name); files.push(...nested.files); directories.push(...nested.directories);
    } else if (stat.isFile()) files.push(name);
    else invalid(`payload contains a non-regular entry: ${name}`);
  }
  return { files, directories };
}

export function verifyDeploymentSourceBundle(bundleDirectory, { expectedBundleSha256 } = {}) {
  const root = path.resolve(bundleDirectory);
  let rootStat;
  try { rootStat = fs.lstatSync(root); } catch { invalid('bundle root is missing'); }
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) invalid('bundle root must be a regular directory');
  const rootNames = fs.readdirSync(root).sort(compare);
  if (!same(rootNames, [BUNDLE_NAME, MANIFEST_NAME, PAYLOAD_NAME].sort(compare))) invalid('bundle root has missing or extra entries');
  const value = validateManifest(manifestAt(root), expectedBundleSha256);
  const payloadRoot = path.join(root, PAYLOAD_NAME), payloadStat = fs.lstatSync(payloadRoot);
  if (!payloadStat.isDirectory() || payloadStat.isSymbolicLink()) invalid('payload root must be a regular directory');
  const actual = walk(payloadRoot), paths = value.files.map(file => file.path);
  if (!same(actual.files, paths)) invalid('payload file set has missing or extra entries');
  const expectedDirectories = [...new Set(paths.flatMap(file => {
    const parts = file.split('/');
    return parts.slice(0, -1).map((_, index) => parts.slice(0, index + 1).join('/'));
  }))].sort(compare);
  if (!same(actual.directories, expectedDirectories)) invalid('payload directory set has missing or extra entries');
  const payload = [];
  for (const file of value.files) {
    const filename = path.join(payloadRoot, ...file.path.split('/')), stat = fs.lstatSync(filename);
    if (!stat.isFile() || stat.isSymbolicLink()) invalid(`payload is not a regular file: ${file.path}`);
    if ((stat.mode & 0o777) !== MODES.get(file.mode)) invalid(`file mode differs: ${file.path}`);
    const bytes = fs.readFileSync(filename);
    if (bytes.length !== file.sizeBytes || hash(bytes) !== file.sha256) invalid(`file bytes differ: ${file.path}`);
    payload.push({ path: file.path, mode: file.mode, bytes });
  }
  const archivePath = path.join(root, BUNDLE_NAME), archiveStat = fs.lstatSync(archivePath);
  if (!archiveStat.isFile() || archiveStat.isSymbolicLink() || (archiveStat.mode & 0o777) !== 0o644) invalid('tar is not a mode-0644 regular file');
  const archive = fs.readFileSync(archivePath);
  if (archive.length !== value.bundle.sizeBytes || hash(archive) !== value.bundle.sha256) invalid('tar identity differs');
  const sourceMetadata = metadata(value.source, value.files);
  if (!archive.equals(tarBytes(sourceMetadata, payload))) invalid('tar differs from deterministic source metadata and payload');
  return value;
}

function flags(args, allowed) {
  const result = {};
  if (args.length % 2) throw new Error('usage error');
  for (let index = 0; index < args.length; index += 2) {
    if (!allowed.includes(args[index]) || result[args[index]] !== undefined || !args[index + 1]) throw new Error('usage error');
    result[args[index]] = args[index + 1];
  }
  return result;
}
function usage() {
  return 'usage: deployment-source-bundle.mjs prepare --repo-root PATH --commit FULL_SHA --output DIR | verify --bundle DIR [--expected-bundle-sha SHA256]';
}
function main(argv) {
  const [mode, ...rest] = argv;
  if (mode === 'prepare') {
    const args = flags(rest, ['--repo-root', '--commit', '--output']);
    if (!args['--repo-root'] || !args['--commit'] || !args['--output']) throw new Error(usage());
    const value = prepareDeploymentSourceBundle({ repoRoot: args['--repo-root'], commit: args['--commit'], outputDirectory: args['--output'] });
    process.stdout.write(`${JSON.stringify({ status: 'prepared', outputDirectory: path.resolve(args['--output']),
      source: value.source, bundle: value.bundle, fileCount: value.files.length })}\n`);
    return;
  }
  if (mode === 'verify') {
    const args = flags(rest, ['--bundle', '--expected-bundle-sha']);
    if (!args['--bundle']) throw new Error(usage());
    const value = verifyDeploymentSourceBundle(args['--bundle'], { expectedBundleSha256: args['--expected-bundle-sha'] });
    process.stdout.write(`${JSON.stringify({ status: 'verified', bundleDirectory: path.resolve(args['--bundle']),
      source: value.source, bundle: value.bundle, fileCount: value.files.length })}\n`);
    return;
  }
  throw new Error(usage());
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}
