#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ARTIFACT_KIND = 'frwhoop-edge-bundle';
const SCHEMA_VERSION = 1;
const PAYLOAD_ROOT = 'payload';
const MANIFEST_NAME = 'edge-source-bundle-manifest.json';
const BUNDLE_NAME = 'edge-source-bundle.tar';
const INTERNAL_METADATA_NAME = 'edge-source-bundle-metadata.json';

export const DEPLOYABLE_ROLES = Object.freeze([
  'account-deletion',
  'ingest-verify',
  'push',
  'reconcile',
  'retention-sweep',
  'scores',
]);

export const INCLUDED_ROOTS = Object.freeze([
  'supabase/config.toml',
  'supabase/functions/_shared',
  'supabase/functions/account-deletion',
  'supabase/functions/deno.lock',
  'supabase/functions/ingest-verify',
  'supabase/functions/push',
  'supabase/functions/reconcile',
  'supabase/functions/retention-sweep',
  'supabase/functions/scores',
]);

const EXCLUSION_POLICY = 'tests-and-documentation-v1';
const ALLOWED_FILE_MODES = new Map([
  ['100644', 0o644],
  ['100755', 0o755],
]);

function fail(message) {
  throw new Error(`INVALID_EDGE_BUNDLE: ${message}`);
}

function prepareFail(message) {
  throw new Error(`NOT_READY: ${message}`);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function requireExactKeys(value, expected, label) {
  if (!isObject(value)) fail(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    fail(`${label} fields differ from the reviewed contract`);
  }
}

export function sha256Hex(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function requireSha(value, label) {
  if (typeof value !== 'string' || !/^[0-9a-f]{40}$/.test(value)) {
    fail(`${label} must be a full lowercase Git SHA-1`);
  }
}

function requireSha256(value, label) {
  if (typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value)) {
    fail(`${label} must be a lowercase SHA-256`);
  }
}

function equalArray(actual, expected) {
  return Array.isArray(actual) && JSON.stringify(actual) === JSON.stringify(expected);
}

function comparePaths(left, right) {
  return Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));
}

function isExcludedSourcePath(relativePath) {
  const segments = relativePath.split('/');
  const basename = segments.at(-1).toLowerCase();
  if (segments.some((segment) => /^(?:test|tests|doc|docs)$/i.test(segment))) return true;
  if (/\.(?:md|markdown)$/i.test(basename)) return true;
  return /(?:^|[._-])(?:test|tests|spec)(?:[._-]|$)/i.test(basename);
}

function isAllowedPayloadPath(relativePath) {
  if (relativePath === 'supabase/config.toml' || relativePath === 'supabase/functions/deno.lock') return true;
  return ['_shared', ...DEPLOYABLE_ROLES].some((directory) =>
    relativePath.startsWith(`supabase/functions/${directory}/`));
}

function validateRelativePath(relativePath, label) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || relativePath.includes('\\') ||
      relativePath.includes('\0') || path.posix.normalize(relativePath) !== relativePath ||
      relativePath.startsWith('/') || relativePath.split('/').some((segment) => segment === '..' || segment === '.')) {
    fail(`${label} is not a normalized repository-relative path`);
  }
  if (!isAllowedPayloadPath(relativePath)) fail(`${label} is outside the reviewed Edge source roots`);
  if (isExcludedSourcePath(relativePath)) fail(`${label} violates the tests/documentation exclusion policy`);
}

function runGit(repoRoot, args, options = {}) {
  const result = spawnSync('git', ['-C', repoRoot, ...args], {
    encoding: options.binary ? undefined : 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) prepareFail(`git ${args[0]} could not run: ${result.error.message}`);
  if (result.status !== 0) {
    const detail = Buffer.isBuffer(result.stderr) ? result.stderr.toString('utf8') : result.stderr;
    prepareFail(`git ${args[0]} failed${detail?.trim() ? `: ${detail.trim()}` : ''}`);
  }
  return result.stdout;
}

function requireFullCommit(repoRoot, commitSha) {
  if (typeof commitSha !== 'string' || !/^[0-9a-f]{40}$/.test(commitSha)) {
    prepareFail('--commit must be a full lowercase 40-character Git SHA');
  }
  const resolved = runGit(repoRoot, ['rev-parse', '--verify', `${commitSha}^{commit}`]).trim();
  if (resolved !== commitSha) prepareFail('specified commit did not resolve to the exact requested SHA');
  return runGit(repoRoot, ['rev-parse', '--verify', `${commitSha}^{tree}`]).trim();
}

function parseTreeEntries(raw) {
  const entries = [];
  for (const record of raw.toString('utf8').split('\0')) {
    if (record.length === 0) continue;
    const match = /^([0-7]{6}) ([a-z]+) ([0-9a-f]{40})\t(.+)$/.exec(record);
    if (!match) prepareFail('git ls-tree returned an unsupported record');
    entries.push({ mode: match[1], type: match[2], objectSha: match[3], path: match[4] });
  }
  return entries;
}

function readCommittedEntries(repoRoot, commitSha) {
  const raw = runGit(repoRoot, ['ls-tree', '-r', '-z', commitSha, '--', ...INCLUDED_ROOTS], { binary: true });
  const entries = parseTreeEntries(raw)
    .filter((entry) => !isExcludedSourcePath(entry.path))
    .sort((left, right) => comparePaths(left.path, right.path));

  if (entries.length === 0) prepareFail('specified commit has no reviewed Edge source files');
  const seen = new Set();
  for (const entry of entries) {
    if (seen.has(entry.path)) prepareFail(`duplicate committed path: ${entry.path}`);
    seen.add(entry.path);
    if (entry.type !== 'blob') prepareFail(`committed Edge source is not a blob: ${entry.path}`);
    if (!ALLOWED_FILE_MODES.has(entry.mode)) {
      prepareFail(`committed Edge source has an unsupported mode or symlink: ${entry.path} (${entry.mode})`);
    }
    if (!isAllowedPayloadPath(entry.path)) prepareFail(`committed path escaped reviewed roots: ${entry.path}`);
  }

  for (const singleton of ['supabase/config.toml', 'supabase/functions/deno.lock']) {
    if (!seen.has(singleton)) prepareFail(`specified commit is missing ${singleton}`);
  }
  if (![...seen].some((name) => name.startsWith('supabase/functions/_shared/'))) {
    prepareFail('specified commit is missing deployable _shared sources');
  }
  for (const role of DEPLOYABLE_ROLES) {
    const entrypoint = `supabase/functions/${role}/index.ts`;
    if (!seen.has(entrypoint)) prepareFail(`specified commit is missing role entrypoint ${entrypoint}`);
  }
  return entries;
}

function sourceMetadata(source, files) {
  return {
    schemaVersion: SCHEMA_VERSION,
    kind: ARTIFACT_KIND,
    source,
    includedRoots: [...INCLUDED_ROOTS],
    exclusionPolicy: EXCLUSION_POLICY,
    deployableFunctions: [...DEPLOYABLE_ROLES],
    files,
  };
}

function writeTarText(header, offset, length, value, label) {
  const encoded = Buffer.from(value, 'utf8');
  if (encoded.length > length) prepareFail(`${label} is too long for deterministic ustar`);
  encoded.copy(header, offset);
}

function writeTarOctal(header, offset, length, value, label) {
  if (!Number.isSafeInteger(value) || value < 0) prepareFail(`${label} is not a nonnegative safe integer`);
  const octal = value.toString(8);
  if (octal.length > length - 1) prepareFail(`${label} is too large for deterministic ustar`);
  writeTarText(header, offset, length, `${octal.padStart(length - 1, '0')}\0`, label);
}

function tarHeader(entry) {
  const header = Buffer.alloc(512);
  writeTarText(header, 0, 100, entry.path, 'tar entry path');
  writeTarOctal(header, 100, 8, entry.mode === '100755' ? 0o755 : 0o644, 'tar entry mode');
  writeTarOctal(header, 108, 8, 0, 'tar uid');
  writeTarOctal(header, 116, 8, 0, 'tar gid');
  writeTarOctal(header, 124, 12, entry.bytes.length, 'tar entry size');
  writeTarOctal(header, 136, 12, 0, 'tar mtime');
  header.fill(0x20, 148, 156);
  header[156] = 0x30;
  writeTarText(header, 257, 6, 'ustar\0', 'tar magic');
  writeTarText(header, 263, 2, '00', 'tar version');
  const checksum = header.reduce((total, byte) => total + byte, 0);
  const checksumText = checksum.toString(8).padStart(6, '0');
  writeTarText(header, 148, 8, `${checksumText}\0 `, 'tar checksum');
  return header;
}

function deterministicTar(metadata, payloadEntries) {
  const metadataBytes = Buffer.from(`${JSON.stringify(metadata, null, 2)}\n`, 'utf8');
  const entries = [
    { path: INTERNAL_METADATA_NAME, mode: '100644', bytes: metadataBytes },
    ...payloadEntries,
  ];
  const chunks = [];
  for (const entry of entries) {
    chunks.push(tarHeader(entry), entry.bytes);
    const padding = (512 - (entry.bytes.length % 512)) % 512;
    if (padding > 0) chunks.push(Buffer.alloc(padding));
  }
  chunks.push(Buffer.alloc(1024));
  return Buffer.concat(chunks);
}

export function prepareEdgeSourceBundle({ repoRoot, commitSha, outputDirectory }) {
  if (typeof repoRoot !== 'string' || repoRoot.length === 0) prepareFail('--repo-root is required');
  if (typeof outputDirectory !== 'string' || outputDirectory.length === 0) prepareFail('--output is required');
  const repository = path.resolve(repoRoot);
  const output = path.resolve(outputDirectory);
  let repositoryStat;
  try {
    repositoryStat = fs.statSync(repository);
  } catch {
    prepareFail('repository root is not readable');
  }
  if (!repositoryStat.isDirectory()) prepareFail('repository root is not a directory');
  if (fs.existsSync(output)) prepareFail('output directory already exists');

  const treeSha = requireFullCommit(repository, commitSha);
  const entries = readCommittedEntries(repository, commitSha);
  const parent = path.dirname(output);
  fs.mkdirSync(parent, { recursive: true });
  const temporary = fs.mkdtempSync(path.join(parent, `.${path.basename(output)}.tmp-`));

  try {
    const files = [];
    const payloadEntries = [];
    for (const entry of entries) {
      const bytes = runGit(repository, ['cat-file', 'blob', entry.objectSha], { binary: true });
      const destination = path.join(temporary, PAYLOAD_ROOT, ...entry.path.split('/'));
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.writeFileSync(destination, bytes, { mode: ALLOWED_FILE_MODES.get(entry.mode) });
      fs.chmodSync(destination, ALLOWED_FILE_MODES.get(entry.mode));
      files.push({
        path: entry.path,
        mode: entry.mode,
        sizeBytes: bytes.length,
        sha256: sha256Hex(bytes),
      });
      payloadEntries.push({ path: entry.path, mode: entry.mode, bytes });
    }

    const metadata = sourceMetadata({ commit: commitSha, tree: treeSha }, files);
    const tarBytes = deterministicTar(metadata, payloadEntries);
    const manifest = {
      schemaVersion: metadata.schemaVersion,
      kind: metadata.kind,
      source: metadata.source,
      bundle: {
        filename: BUNDLE_NAME,
        sha256: sha256Hex(tarBytes),
        sizeBytes: tarBytes.length,
      },
      includedRoots: metadata.includedRoots,
      exclusionPolicy: metadata.exclusionPolicy,
      deployableFunctions: metadata.deployableFunctions,
      files: metadata.files,
    };
    fs.writeFileSync(path.join(temporary, BUNDLE_NAME), tarBytes, { mode: 0o644 });
    fs.chmodSync(path.join(temporary, BUNDLE_NAME), 0o644);
    fs.writeFileSync(path.join(temporary, MANIFEST_NAME), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 });
    fs.chmodSync(path.join(temporary, MANIFEST_NAME), 0o644);
    verifyEdgeSourceBundle(temporary, { expectedBundleSha256: manifest.bundle.sha256 });
    fs.renameSync(temporary, output);
    return manifest;
  } catch (error) {
    fs.rmSync(temporary, { recursive: true, force: true });
    throw error;
  }
}

function readManifest(bundleRoot) {
  const filename = path.join(bundleRoot, MANIFEST_NAME);
  let raw;
  try {
    const stat = fs.lstatSync(filename);
    if (!stat.isFile() || stat.isSymbolicLink()) fail(`${MANIFEST_NAME} must be a regular file`);
    if ((stat.mode & 0o777) !== 0o644) fail(`${MANIFEST_NAME} mode differs`);
    raw = fs.readFileSync(filename, 'utf8');
  } catch (error) {
    if (error?.message?.startsWith('INVALID_EDGE_BUNDLE:')) throw error;
    fail(`${MANIFEST_NAME} is missing or unreadable`);
  }
  try {
    return JSON.parse(raw);
  } catch {
    fail(`${MANIFEST_NAME} is not valid JSON`);
  }
}

function validateManifest(manifest, expectedBundleSha256) {
  requireExactKeys(manifest, [
    'schemaVersion', 'kind', 'source', 'bundle', 'includedRoots', 'exclusionPolicy',
    'deployableFunctions', 'files',
  ], 'manifest');
  if (manifest.schemaVersion !== SCHEMA_VERSION) fail(`schemaVersion must be ${SCHEMA_VERSION}`);
  if (manifest.kind !== ARTIFACT_KIND) fail('kind differs from the reviewed Edge bundle');
  requireExactKeys(manifest.source, ['commit', 'tree'], 'source');
  requireSha(manifest.source.commit, 'source.commit');
  requireSha(manifest.source.tree, 'source.tree');
  requireExactKeys(manifest.bundle, ['filename', 'sha256', 'sizeBytes'], 'bundle');
  if (manifest.bundle.filename !== BUNDLE_NAME) fail(`bundle filename must be ${BUNDLE_NAME}`);
  requireSha256(manifest.bundle.sha256, 'bundle.sha256');
  if (!Number.isSafeInteger(manifest.bundle.sizeBytes) || manifest.bundle.sizeBytes < 1) {
    fail('bundle.sizeBytes must be a positive safe integer');
  }
  if (!equalArray(manifest.includedRoots, INCLUDED_ROOTS)) fail('included root set or order differs from the reviewed contract');
  if (manifest.exclusionPolicy !== EXCLUSION_POLICY) fail('tests/documentation exclusion policy differs from the reviewed contract');
  if (!equalArray(manifest.deployableFunctions, DEPLOYABLE_ROLES)) {
    fail('deployable function set or order differs from the reviewed contract');
  }
  if (!Array.isArray(manifest.files) || manifest.files.length < 1) fail('files must be a nonempty array');

  const seen = new Set();
  let prior = '';
  for (const [index, file] of manifest.files.entries()) {
    requireExactKeys(file, ['path', 'mode', 'sizeBytes', 'sha256'], `files[${index}]`);
    validateRelativePath(file.path, `files[${index}].path`);
    if (comparePaths(file.path, prior) <= 0 && index > 0) fail('files must be unique and sorted by path');
    prior = file.path;
    if (seen.has(file.path)) fail(`duplicate file path: ${file.path}`);
    seen.add(file.path);
    if (!ALLOWED_FILE_MODES.has(file.mode)) fail(`unsupported file mode for ${file.path}`);
    if (!Number.isSafeInteger(file.sizeBytes) || file.sizeBytes < 0) fail(`invalid size for ${file.path}`);
    requireSha256(file.sha256, `SHA-256 for ${file.path}`);
  }
  for (const singleton of ['supabase/config.toml', 'supabase/functions/deno.lock']) {
    if (!seen.has(singleton)) fail(`manifest is missing ${singleton}`);
  }
  if (![...seen].some((name) => name.startsWith('supabase/functions/_shared/'))) {
    fail('manifest is missing deployable _shared sources');
  }
  for (const role of DEPLOYABLE_ROLES) {
    if (!seen.has(`supabase/functions/${role}/index.ts`)) fail(`manifest is missing role entrypoint for ${role}`);
  }

  if (expectedBundleSha256 !== undefined) {
    requireSha256(expectedBundleSha256, 'expected bundle SHA-256');
    if (manifest.bundle.sha256 !== expectedBundleSha256) fail('bundle SHA-256 differs from the expected release identity');
  }
  return manifest;
}

function collectPayloadTree(directory, relative = '') {
  const files = [];
  const directories = [];
  let entries;
  try {
    entries = fs.readdirSync(directory, { withFileTypes: true });
  } catch {
    fail(`payload directory is missing or unreadable: ${relative || PAYLOAD_ROOT}`);
  }
  entries.sort((left, right) => comparePaths(left.name, right.name));
  for (const entry of entries) {
    const childRelative = relative ? `${relative}/${entry.name}` : entry.name;
    const child = path.join(directory, entry.name);
    const stat = fs.lstatSync(child);
    if (stat.isSymbolicLink()) fail(`payload contains a symlink: ${childRelative}`);
    if (stat.isDirectory()) {
      directories.push(childRelative);
      const nested = collectPayloadTree(child, childRelative);
      files.push(...nested.files);
      directories.push(...nested.directories);
    } else if (stat.isFile()) {
      files.push(childRelative);
    } else {
      fail(`payload contains a non-regular entry: ${childRelative}`);
    }
  }
  return { files, directories };
}

export function verifyEdgeSourceBundle(bundleDirectory, { expectedBundleSha256 } = {}) {
  if (typeof bundleDirectory !== 'string' || bundleDirectory.length === 0) fail('bundle directory is required');
  const bundleRoot = path.resolve(bundleDirectory);
  let rootStat;
  try {
    rootStat = fs.lstatSync(bundleRoot);
  } catch {
    fail('bundle directory is missing or unreadable');
  }
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) fail('bundle root must be a regular directory');

  const rootEntries = fs.readdirSync(bundleRoot, { withFileTypes: true })
    .map((entry) => entry.name)
    .sort(comparePaths);
  const expectedRootEntries = [BUNDLE_NAME, MANIFEST_NAME, PAYLOAD_ROOT]
    .sort(comparePaths);
  if (!equalArray(rootEntries, expectedRootEntries)) fail('bundle root contains missing or extra entries');

  const manifest = validateManifest(readManifest(bundleRoot), expectedBundleSha256);
  const payload = path.join(bundleRoot, PAYLOAD_ROOT);
  const payloadStat = fs.lstatSync(payload);
  if (!payloadStat.isDirectory() || payloadStat.isSymbolicLink()) fail('payload root must be a regular directory');
  const actualTree = collectPayloadTree(payload);
  const manifestPaths = manifest.files.map((file) => file.path);
  if (!equalArray(actualTree.files, manifestPaths)) fail('payload file set has missing or extra entries');
  const expectedDirectories = [...new Set(manifestPaths.flatMap((file) => {
    const segments = file.split('/');
    return segments.slice(0, -1).map((_, index) => segments.slice(0, index + 1).join('/'));
  }))].sort(comparePaths);
  if (!equalArray(actualTree.directories, expectedDirectories)) {
    fail('payload directory set has missing or extra entries');
  }

  for (const file of manifest.files) {
    const filename = path.join(payload, ...file.path.split('/'));
    const stat = fs.lstatSync(filename);
    if (!stat.isFile() || stat.isSymbolicLink()) fail(`payload entry is not a regular file: ${file.path}`);
    const actualMode = stat.mode & 0o777;
    if (actualMode !== ALLOWED_FILE_MODES.get(file.mode)) fail(`file mode differs: ${file.path}`);
    if (stat.size !== file.sizeBytes) fail(`file size differs: ${file.path}`);
    const actualSha = sha256Hex(fs.readFileSync(filename));
    if (actualSha !== file.sha256) fail(`file SHA-256 differs: ${file.path}`);
  }

  const bundleFilename = path.join(bundleRoot, BUNDLE_NAME);
  const bundleStat = fs.lstatSync(bundleFilename);
  if (!bundleStat.isFile() || bundleStat.isSymbolicLink()) fail('bundle tar must be a regular file');
  if ((bundleStat.mode & 0o777) !== 0o644) fail('bundle tar mode differs');
  if (bundleStat.size !== manifest.bundle.sizeBytes) fail('bundle tar size differs');
  const bundleBytes = fs.readFileSync(bundleFilename);
  if (sha256Hex(bundleBytes) !== manifest.bundle.sha256) fail('bundle tar SHA-256 differs');

  const metadata = sourceMetadata(manifest.source, manifest.files);
  const payloadEntries = manifest.files.map((file) => ({
    path: file.path,
    mode: file.mode,
    bytes: fs.readFileSync(path.join(payload, ...file.path.split('/'))),
  }));
  const expectedTar = deterministicTar(metadata, payloadEntries);
  if (!bundleBytes.equals(expectedTar)) fail('bundle tar does not match deterministic source metadata and payload');
  return manifest;
}

function parseFlags(args, allowed) {
  const values = {};
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (!allowed.has(flag) || value === undefined || value.startsWith('--')) {
      throw new Error(`usage error near ${flag ?? '<end>'}`);
    }
    if (values[flag] !== undefined) throw new Error(`duplicate flag ${flag}`);
    values[flag] = value;
  }
  return values;
}

function usage() {
  return [
    'Usage:',
    '  node Tools/release/edge-source-bundle.mjs prepare --repo-root PATH --commit FULL_SHA --output DIRECTORY',
    '  node Tools/release/edge-source-bundle.mjs verify --bundle DIRECTORY [--expected-bundle-sha SHA256]',
  ].join('\n');
}

function main(argv) {
  const [command, ...rest] = argv;
  if (command === 'prepare') {
    const flags = parseFlags(rest, new Set(['--repo-root', '--commit', '--output']));
    if (!flags['--repo-root'] || !flags['--commit'] || !flags['--output']) throw new Error(usage());
    const manifest = prepareEdgeSourceBundle({
      repoRoot: flags['--repo-root'],
      commitSha: flags['--commit'],
      outputDirectory: flags['--output'],
    });
    process.stdout.write(`${JSON.stringify({
      status: 'prepared',
      outputDirectory: path.resolve(flags['--output']),
      commit: manifest.source.commit,
      tree: manifest.source.tree,
      fileCount: manifest.files.length,
      bundleFilename: manifest.bundle.filename,
      bundleSha256: manifest.bundle.sha256,
      bundleSizeBytes: manifest.bundle.sizeBytes,
    })}\n`);
    return;
  }
  if (command === 'verify') {
    const flags = parseFlags(rest, new Set(['--bundle', '--expected-bundle-sha']));
    if (!flags['--bundle']) throw new Error(usage());
    const manifest = verifyEdgeSourceBundle(flags['--bundle'], {
      expectedBundleSha256: flags['--expected-bundle-sha'],
    });
    process.stdout.write(`${JSON.stringify({
      status: 'verified',
      bundleDirectory: path.resolve(flags['--bundle']),
      commit: manifest.source.commit,
      tree: manifest.source.tree,
      fileCount: manifest.files.length,
      bundleFilename: manifest.bundle.filename,
      bundleSha256: manifest.bundle.sha256,
      bundleSizeBytes: manifest.bundle.sizeBytes,
    })}\n`);
    return;
  }
  throw new Error(usage());
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
