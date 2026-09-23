#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

import { canonicalJSON, sha256Hex } from './generate-migration-manifest.mjs';

export const HOSTED_PROJECT_REF = 'sgoyxzcagqyxexmsidtk';
export const CREDENTIAL_ENVIRONMENT = 'FRWHOOP_HOSTED_DATABASE_URL';
export const EXPECTED_SCHEMA_FINGERPRINT = 'e71489e9317a7a47c1f4c591ca8c26187bf726149e4c456246098673c4d66b24';
export const EXPECTED_DATABASE_SCHEMA_FINGERPRINT = '8c0f6b62fadc0d42fafab8b7ff0140b75198fddbbc728b8b5f2e62ded0e69663';
export const PSQL_CONNECT_TIMEOUT_SECONDS = 10;
export const PSQL_QUERY_TIMEOUT_MILLISECONDS = 10 * 60 * 1000;
export const LEDGER_STATEMENT_TIMEOUT_SECONDS = 30;
export const MIGRATION_STATEMENT_TIMEOUT_SECONDS = 5 * 60;
export const POSTVERIFY_STATEMENT_TIMEOUT_SECONDS = 5 * 60;
export const PENDING_IDENTITIES = Object.freeze([
  '20260921110000_installation_retirement.sql',
  '20260921111000_wearable_lifecycle.sql',
  '20260921112000_fleet_scheduler.sql',
  '20260921113000_fleet_admission_retention.sql',
  '20260921120000_sensor_acquisition_windows.sql',
  '20260921121000_final_hosted_compute_contract.sql',
  '20260921122000_compute_session_requests.sql',
  '20260922010000_object_copy_intents.sql',
  '20260922020000_async_object_verification.sql',
  '20260922120000_intake_service_contract.sql',
]);

const MANIFEST_KIND = 'frwhoop-immutable-migration-manifest';
const TARGET_KIND = 'frwhoop-hosted-db-target';
const PLAN_KIND = 'frwhoop-hosted-migration-plan';
const STATE_KIND = 'frwhoop-hosted-migration-state';
const LEDGER_KIND = 'frwhoop-hosted-ledger-export';
const VERIFY_RELATIVE_PATH = 'Tools/release/verify-integrated-schema.sql';
const MIGRATION_DIRECTORY = 'supabase/migrations';
const CATALOG_RELATIVE_PATH = 'scoring-service/service/src/main/resources/scoring-migration-catalog.json';
const BASELINE_COUNT = 117;
const TOTAL_COUNT = 127;
const GIT_EXECUTABLE = '/usr/bin/git';
const DATABASE_CLIENT_KIND = 'frwhoop-hosted-database-client';

function invariant(condition, message) {
  if (!condition) throw new Error(`NOT_READY: ${message}`);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function exactKeys(value, expected, label) {
  invariant(isObject(value), `${label} must be an object`);
  invariant(JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort()),
    `${label} fields differ from the reviewed contract`);
}

function nonempty(value, label) {
  invariant(typeof value === 'string' && value.length > 0 && value.trim() === value, `${label} must be a nonempty string`);
  return value;
}

function sha256(value, label) {
  invariant(typeof value === 'string' && /^[0-9a-f]{64}$/.test(value), `${label} must be a lowercase SHA-256`);
  return value;
}

function gitSha(value, label) {
  invariant(typeof value === 'string' && /^[0-9a-f]{40}$/.test(value), `${label} must be a full Git SHA`);
  return value;
}

function stableIdentity(value, label) {
  invariant(typeof value === 'string' && /^[0-9]{14}_[a-z0-9_]+\.sql$/.test(value), `${label} is not a stable migration identity`);
  return value;
}

function fingerprint(value) {
  return sha256Hex(canonicalJSON(value));
}

function signed(value, field) {
  const { [field]: ignored, ...unsigned } = value;
  void ignored;
  return { unsigned, fingerprint: fingerprint(unsigned) };
}

function readJSON(filename, label) {
  let stat;
  try {
    stat = fs.lstatSync(filename);
    invariant(stat.isFile() && !stat.isSymbolicLink(), `${label} must be a regular file`);
    return JSON.parse(fs.readFileSync(filename, 'utf8'));
  } catch (error) {
    if (error instanceof Error && error.message.startsWith('NOT_READY:')) throw error;
    throw new Error(`NOT_READY: ${label} is not readable JSON`);
  }
}

function git(repoRoot, ...args) {
  const result = spawnSync(GIT_EXECUTABLE, [
    '--no-replace-objects', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
    '-c', 'protocol.allow=never', '-C', repoRoot, ...args,
  ], {
    encoding: null,
    timeout: 30 * 1000,
    maxBuffer: 64 * 1024 * 1024,
    env: {
      LANG: 'C',
      LC_ALL: 'C',
      ...(process.env.TMPDIR ? { TMPDIR: process.env.TMPDIR } : {}),
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_CONFIG_GLOBAL: '/dev/null',
      GIT_NO_LAZY_FETCH: '1',
      GIT_NO_REPLACE_OBJECTS: '1',
      GIT_OPTIONAL_LOCKS: '0',
    },
  });
  invariant(!result.error && !result.signal && result.status === 0,
    `git ${args[0]} failed while binding hosted migration source`);
  return result.stdout;
}

function verifyDatabaseClient(client) {
  exactKeys(client, ['schemaVersion', 'kind', 'path', 'sha256', 'sizeBytes', 'version'], 'database client');
  invariant(client.schemaVersion === 1 && client.kind === DATABASE_CLIENT_KIND,
    'database client type differs');
  invariant(path.isAbsolute(client.path) && fs.realpathSync(client.path) === client.path,
    'database client path must be an absolute canonical path');
  const stat = fs.lstatSync(client.path);
  invariant(stat.isFile() && !stat.isSymbolicLink() && (stat.mode & 0o111) !== 0,
    'database client must be an executable regular file');
  sha256(client.sha256, 'database client hash');
  invariant(Number.isInteger(client.sizeBytes) && client.sizeBytes > 0 && stat.size === client.sizeBytes,
    'database client size differs');
  invariant(sha256Hex(fs.readFileSync(client.path)) === client.sha256, 'database client bytes differ');
  invariant(typeof client.version === 'string' && /^psql \(PostgreSQL\) \d+(?:\.\d+)+(?: .+)?$/.test(client.version),
    'database client version is not a reviewed psql version');
  return client;
}

export function inspectPsqlExecutable(psqlPath, spawn = spawnSync, expectedClient = undefined) {
  invariant(typeof psqlPath === 'string' && path.isAbsolute(psqlPath),
    'psql path must be absolute');
  let resolved;
  try { resolved = fs.realpathSync(psqlPath); } catch { throw new Error('NOT_READY: psql path is not readable'); }
  invariant(resolved === psqlPath, 'psql path must be canonical and may not traverse a symlink');
  const stat = fs.lstatSync(resolved);
  invariant(stat.isFile() && !stat.isSymbolicLink() && (stat.mode & 0o111) !== 0,
    'psql path must identify an executable regular file');
  if (expectedClient !== undefined) {
    verifyDatabaseClient(expectedClient);
    invariant(resolved === expectedClient.path && stat.size === expectedClient.sizeBytes &&
      sha256Hex(fs.readFileSync(resolved)) === expectedClient.sha256,
    'psql executable differs from the reviewed plan before version inspection');
  }
  const result = spawn(resolved, ['--version'], {
    encoding: 'utf8',
    env: { LANG: 'C', LC_ALL: 'C' },
    timeout: 10 * 1000,
    maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  invariant(!result.error && !result.signal && result.status === 0,
    'psql --version failed for the reviewed executable');
  const client = {
    schemaVersion: 1,
    kind: DATABASE_CLIENT_KIND,
    path: resolved,
    sha256: sha256Hex(fs.readFileSync(resolved)),
    sizeBytes: stat.size,
    version: result.stdout.trim(),
  };
  verifyDatabaseClient(client);
  if (expectedClient !== undefined) {
    invariant(canonicalJSON(client) === canonicalJSON(expectedClient),
      'psql executable version differs from the reviewed plan');
  }
  return client;
}

function atomicWrite(filename, value, { exclusive = false } = {}) {
  const resolved = path.resolve(filename);
  fs.mkdirSync(path.dirname(resolved), { recursive: true, mode: 0o700 });
  invariant(!fs.existsSync(resolved) || (!exclusive && fs.lstatSync(resolved).isFile() && !fs.lstatSync(resolved).isSymbolicLink()),
    `${path.basename(resolved)} already exists or is not a regular file`);
  const temporary = path.join(path.dirname(resolved), `.${path.basename(resolved)}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`);
  const bytes = `${JSON.stringify(value, null, 2)}\n`;
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, bytes);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    if (exclusive) fs.linkSync(temporary, resolved);
    else fs.renameSync(temporary, resolved);
    if (exclusive) fs.unlinkSync(temporary);
    const directory = fs.openSync(path.dirname(resolved), 'r');
    try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    fs.rmSync(temporary, { force: true });
  }
}

function normalizedHost(value) {
  const host = nonempty(value, 'target host').toLowerCase();
  invariant(/^[a-z0-9.-]+$/.test(host) && !host.startsWith('.') && !host.endsWith('.') && !host.includes('..'),
    'target host is malformed');
  return host;
}

function targetShape({ projectRef, host, port, database, user }) {
  invariant(projectRef === HOSTED_PROJECT_REF, `project ref must be ${HOSTED_PROJECT_REF}`);
  const normalized = normalizedHost(host);
  invariant(Number.isInteger(port) && [5432, 6543].includes(port), 'target port must be 5432 or 6543');
  invariant(database === 'postgres', 'hosted target database must be postgres');
  const direct = normalized === `db.${HOSTED_PROJECT_REF}.supabase.co` && user === 'postgres' && port === 5432;
  const pooler = normalized.endsWith('.pooler.supabase.com') && user === `postgres.${HOSTED_PROJECT_REF}`;
  invariant(direct || pooler,
    'host/user/port do not bind the direct FRWHOOP database or an FRWHOOP-qualified Supabase pooler user');
  return { host: normalized, accessPath: direct ? 'direct' : 'pooler' };
}

function verifyRootCertificate(filename, expectedHash) {
  sha256(expectedHash, 'root certificate hash');
  invariant(typeof filename === 'string' && path.isAbsolute(filename), 'root certificate path must be absolute');
  const stat = fs.lstatSync(filename);
  invariant(stat.isFile() && !stat.isSymbolicLink() && fs.realpathSync(filename) === filename,
    'root certificate must be a canonical regular file');
  invariant(stat.size > 0 && stat.size <= 128 * 1024, 'root certificate size is invalid');
  const bytes = fs.readFileSync(filename);
  invariant(sha256Hex(bytes) === expectedHash, 'root certificate bytes differ from reviewed hash');
  const pem = bytes.toString('utf8');
  invariant(/^\s*-----BEGIN CERTIFICATE-----[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\s*$/.test(pem),
    'root certificate must contain exactly one PEM certificate');
  let certificate;
  try { certificate = new crypto.X509Certificate(bytes); }
  catch { throw new Error('NOT_READY: root certificate is invalid'); }
  invariant(certificate.ca, 'root certificate is not a CA');
  invariant(Date.parse(certificate.validFrom) <= Date.now() && Date.parse(certificate.validTo) > Date.now(),
    'root certificate is outside its validity interval');
}

export function createTargetBinding({ projectRef, host, port, database = 'postgres', user, expectedCurrentUser = 'postgres',
  sslRootCert = 'system', sslRootCertSha256 }) {
  const shape = targetShape({ projectRef, host, port, database, user });
  invariant(expectedCurrentUser === 'postgres', 'expected hosted current_user must be postgres');
  if (sslRootCert === 'system') invariant(sslRootCertSha256 === undefined, 'system roots cannot carry a file hash');
  else verifyRootCertificate(sslRootCert, sslRootCertSha256);
  const unsigned = {
    schemaVersion: 1,
    kind: TARGET_KIND,
    environment: 'hosted-production',
    projectRef,
    host: shape.host,
    port,
    database,
    user,
    expectedCurrentUser,
    accessPath: shape.accessPath,
    sslMode: 'verify-full',
    sslRootCert,
    ...(sslRootCert === 'system' ? {} : { sslRootCertSha256 }),
    credentialEnvironment: CREDENTIAL_ENVIRONMENT,
  };
  return { ...unsigned, targetBindingFingerprintSha256: fingerprint(unsigned) };
}

export function verifyTargetBinding(binding, projectRef = HOSTED_PROJECT_REF) {
  exactKeys(binding, [
    'schemaVersion', 'kind', 'environment', 'projectRef', 'host', 'port', 'database', 'user',
    'expectedCurrentUser', 'accessPath', 'sslMode', 'sslRootCert', 'credentialEnvironment', 'targetBindingFingerprintSha256',
    ...(binding?.sslRootCert === 'system' ? [] : ['sslRootCertSha256']),
  ], 'hosted target binding');
  invariant(binding.schemaVersion === 1 && binding.kind === TARGET_KIND, 'hosted target binding type differs');
  invariant(binding.environment === 'hosted-production', 'target environment must be hosted-production');
  invariant(projectRef === HOSTED_PROJECT_REF && binding.projectRef === projectRef,
    `project ref must be ${HOSTED_PROJECT_REF}`);
  const shape = targetShape(binding);
  invariant(binding.accessPath === shape.accessPath, 'target access path differs from host/user binding');
  invariant(binding.expectedCurrentUser === 'postgres', 'expected hosted current_user must be postgres');
  invariant(binding.sslMode === 'verify-full', 'hosted target must require sslmode=verify-full');
  if (binding.sslRootCert !== 'system') verifyRootCertificate(binding.sslRootCert, binding.sslRootCertSha256);
  invariant(binding.credentialEnvironment === CREDENTIAL_ENVIRONMENT, 'hosted credential environment differs');
  const { fingerprint: actual } = signed(binding, 'targetBindingFingerprintSha256');
  sha256(binding.targetBindingFingerprintSha256, 'target binding fingerprint');
  invariant(actual === binding.targetBindingFingerprintSha256, 'target binding fingerprint differs');
  return binding;
}

export function connectionFromEnvironment(binding, environment = process.env) {
  verifyTargetBinding(binding);
  const raw = environment[CREDENTIAL_ENVIRONMENT];
  invariant(typeof raw === 'string' && raw.length > 0, `${CREDENTIAL_ENVIRONMENT} is required`);
  let url;
  try { url = new URL(raw); } catch { throw new Error(`NOT_READY: ${CREDENTIAL_ENVIRONMENT} is not a PostgreSQL URL`); }
  invariant(['postgres:', 'postgresql:'].includes(url.protocol), `${CREDENTIAL_ENVIRONMENT} must use PostgreSQL`);
  invariant(!url.hash, `${CREDENTIAL_ENVIRONMENT} must not contain a fragment`);
  invariant(url.hostname.toLowerCase() === binding.host, 'database URL host differs from the reviewed target binding');
  invariant(Number(url.port || 5432) === binding.port, 'database URL port differs from the reviewed target binding');
  invariant(decodeURIComponent(url.username) === binding.user, 'database URL user differs from the reviewed target binding');
  invariant(decodeURIComponent(url.pathname.replace(/^\//, '')) === binding.database,
    'database URL database differs from the reviewed target binding');
  const sslModes = url.searchParams.getAll('sslmode');
  invariant(sslModes.length === 1 && sslModes[0] === binding.sslMode,
    'database URL must contain exactly sslmode=verify-full');
  const sslRoots = url.searchParams.getAll('sslrootcert');
  invariant(sslRoots.length === 1 && sslRoots[0] === binding.sslRootCert,
    'database URL must contain exactly the reviewed sslrootcert');
  invariant(url.password.length > 0, 'database URL password is missing');
  for (const key of url.searchParams.keys()) {
    invariant(key === 'sslmode' || key === 'sslrootcert', `database URL parameter is not reviewed: ${key}`);
  }
  return {
    host: binding.host,
    port: binding.port,
    database: binding.database,
    user: binding.user,
    password: decodeURIComponent(url.password),
    sslMode: binding.sslMode,
    sslRootCert: binding.sslRootCert,
  };
}

function redact(value, secrets) {
  let output = String(value ?? '');
  const reviewedSecrets = [...new Set(secrets.filter(item => typeof item === 'string' && item.length > 0))]
    .sort((left, right) => right.length - left.length);
  for (const secret of reviewedSecrets) output = output.split(secret).join('[REDACTED]');
  return output;
}

export function createPsqlRunner(binding, databaseClient, environment = process.env, spawn = spawnSync) {
  const connection = connectionFromEnvironment(binding, environment);
  verifyDatabaseClient(databaseClient);
  return (sql, label) => {
    verifyDatabaseClient(databaseClient);
    // Recheck the pinned trust bytes before every connection, including after a prior query.
    verifyTargetBinding(binding);
    const childEnvironment = {
      LANG: 'C',
      LC_ALL: 'C',
      PGPASSWORD: connection.password,
      PGSSLMODE: connection.sslMode,
      PGSSLROOTCERT: connection.sslRootCert,
      PGCONNECT_TIMEOUT: String(PSQL_CONNECT_TIMEOUT_SECONDS),
      PGAPPNAME: 'frwhoop-hosted-migration-release',
    };
    const result = spawn(databaseClient.path, [
      '-X', '-w', '-qAt', '-v', 'ON_ERROR_STOP=1',
      '-h', connection.host, '-p', String(connection.port), '-U', connection.user, '-d', connection.database,
    ], {
      input: sql,
      encoding: 'utf8',
      env: childEnvironment,
      timeout: PSQL_QUERY_TIMEOUT_MILLISECONDS,
      killSignal: 'SIGKILL',
      maxBuffer: 16 * 1024 * 1024,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const secrets = [connection.password, new URL(environment[CREDENTIAL_ENVIRONMENT]).password,
      environment[CREDENTIAL_ENVIRONMENT]];
    const detail = redact([
      result.error instanceof Error ? result.error.message : '',
      result.signal ? `signal ${result.signal}` : '',
      result.stderr,
      result.stdout,
    ].filter(Boolean).join('\n'), secrets).trim().slice(-2000);
    invariant(!result.error && !result.signal && result.status === 0,
      `${label} failed${detail ? `: ${detail}` : ''}`);
    return result.stdout.trim();
  };
}

function parseQueryJSON(raw, label) {
  if (isObject(raw)) return raw;
  invariant(typeof raw === 'string' && raw.trim().length > 0, `${label} returned no JSON`);
  const lines = raw.trim().split(/\r?\n/).filter(Boolean);
  let parsed;
  try { parsed = JSON.parse(lines.at(-1)); } catch { throw new Error(`NOT_READY: ${label} returned invalid JSON`); }
  invariant(isObject(parsed), `${label} result must be a JSON object`);
  return parsed;
}

export function verifyMigrationManifest(repoRoot, manifest) {
  invariant(isObject(manifest) && manifest.schemaVersion === 1 && manifest.kind === MANIFEST_KIND,
    'migration manifest type differs');
  sha256(manifest.manifestFingerprintSha256, 'migration manifest fingerprint');
  const { fingerprint: actualFingerprint } = signed(manifest, 'manifestFingerprintSha256');
  invariant(actualFingerprint === manifest.manifestFingerprintSha256, 'migration manifest fingerprint differs');
  invariant(manifest.hostedBaseline?.environment === 'hosted-production' &&
    manifest.hostedBaseline?.projectRef === HOSTED_PROJECT_REF, 'migration manifest hosted project differs');
  invariant(manifest.schemaFingerprintSha256 === EXPECTED_SCHEMA_FINGERPRINT,
    'migration manifest schema fingerprint differs from the reviewed catalog');
  invariant(manifest.catalog?.path === CATALOG_RELATIVE_PATH && manifest.catalog?.migrationDirectory === MIGRATION_DIRECTORY &&
    manifest.catalog?.entryCount === TOTAL_COUNT && manifest.catalog?.baselineEntryCount === BASELINE_COUNT &&
    manifest.catalog?.pendingEntryCount === PENDING_IDENTITIES.length, 'migration manifest catalog contract differs');
  invariant(manifest.counts?.total === TOTAL_COUNT && manifest.counts?.applied === BASELINE_COUNT &&
    manifest.counts?.pending === PENDING_IDENTITIES.length, 'migration manifest counts differ');
  const candidateSha = gitSha(manifest.candidate?.sha, 'migration manifest candidate SHA');
  const candidateTree = gitSha(manifest.candidate?.tree, 'migration manifest candidate tree');
  invariant(manifest.candidate?.branch === 'repair/vps-server-20260922', 'migration manifest candidate branch differs');
  invariant(Array.isArray(manifest.entries) && manifest.entries.length === TOTAL_COUNT, 'migration manifest entry count differs');

  const resolvedRoot = fs.realpathSync(repoRoot);
  invariant(fs.realpathSync(git(resolvedRoot, 'rev-parse', '--show-toplevel').toString('utf8').trim()) === resolvedRoot,
    'repo root must be the exact Git worktree root');
  invariant(git(resolvedRoot, 'cat-file', '-t', candidateSha).toString('utf8').trim() === 'commit',
    'migration manifest candidate commit is unavailable');
  invariant(git(resolvedRoot, 'rev-parse', `${candidateSha}^{tree}`).toString('utf8').trim() === candidateTree,
    'migration manifest candidate tree differs');
  const migrationDirectory = path.join(resolvedRoot, MIGRATION_DIRECTORY);
  const sourceNames = fs.readdirSync(migrationDirectory).filter(name => name.endsWith('.sql')).sort();
  const manifestNames = manifest.entries.map(row => row.stableIdentity).sort();
  invariant(JSON.stringify(sourceNames) === JSON.stringify(manifestNames), 'migration source file set differs from the manifest');
  const committedNames = git(resolvedRoot, 'ls-tree', '-r', '--name-only', candidateSha, '--', MIGRATION_DIRECTORY)
    .toString('utf8').trim().split(/\r?\n/).filter(name => name.endsWith('.sql'))
    .map(name => path.posix.basename(name)).sort();
  invariant(JSON.stringify(committedNames) === JSON.stringify(manifestNames),
    'candidate commit migration file set differs from the manifest');
  const catalogPath = path.join(resolvedRoot, CATALOG_RELATIVE_PATH);
  const catalogBytes = fs.readFileSync(catalogPath);
  invariant(Buffer.compare(catalogBytes, git(resolvedRoot, 'cat-file', 'blob',
    `${candidateSha}:${CATALOG_RELATIVE_PATH}`)) === 0, 'runtime migration catalog differs from the candidate commit');
  const catalog = readJSON(catalogPath, 'runtime migration catalog');
  invariant(Array.isArray(catalog) && catalog.length === TOTAL_COUNT, 'runtime migration catalog count differs');
  const catalogFingerprint=sha256Hex('frwhoop-migration-schema-v1\n'+catalog.map((row,index)=>
    `${index+1}\0${row.basename}\0${row.sha256}\n`).join(''));
  invariant(catalogFingerprint === EXPECTED_SCHEMA_FINGERPRINT,
    'committed catalog contents differ from the reviewed schema fingerprint');

  for (const [index, row] of manifest.entries.entries()) {
    invariant(isObject(row), `migration manifest entry ${index + 1} must be an object`);
    const identity = stableIdentity(row.stableIdentity, `migration manifest entry ${index + 1}`);
    invariant(row.filename === identity && row.ordinal === index + 1, `migration manifest entry order differs: ${identity}`);
    sha256(row.sha256, `migration manifest hash for ${identity}`);
    invariant(catalog[index]?.basename === identity && catalog[index]?.sha256 === row.sha256,
      `runtime catalog differs from migration manifest: ${identity}`);
    invariant(row.hostedStatus === (index < BASELINE_COUNT ? 'applied' : 'pending'),
      `hosted status differs at ${identity}`);
    invariant(row.upgradeBehavior?.execute === (index >= BASELINE_COUNT), `upgrade execution contract differs at ${identity}`);
    invariant(JSON.stringify(row.dependencies) === JSON.stringify(index === 0 ? [] : [manifest.entries[index - 1].stableIdentity]),
      `migration dependency differs at ${identity}`);
    const filename = path.join(migrationDirectory, identity);
    const stat = fs.lstatSync(filename);
    invariant(stat.isFile() && !stat.isSymbolicLink(), `migration source is not a regular file: ${identity}`);
    const bytes = fs.readFileSync(filename);
    invariant(bytes.length === row.sizeBytes, `migration source size differs: ${identity}`);
    invariant(sha256Hex(bytes) === row.sha256, `migration source hash differs: ${identity}`);
    invariant(Buffer.compare(bytes, git(resolvedRoot, 'cat-file', 'blob',
      `${candidateSha}:${MIGRATION_DIRECTORY}/${identity}`)) === 0,
    `migration source differs from the candidate commit: ${identity}`);
  }
  invariant(JSON.stringify(manifest.entries.slice(BASELINE_COUNT).map(row => row.stableIdentity)) === JSON.stringify(PENDING_IDENTITIES),
    'planned hosted migration identities or order differ');
  const verifier = path.join(resolvedRoot, VERIFY_RELATIVE_PATH);
  const verifierStat = fs.lstatSync(verifier);
  invariant(verifierStat.isFile() && !verifierStat.isSymbolicLink(), 'integrated schema verifier must be a regular file');
  const verifierBytes = fs.readFileSync(verifier);
  invariant(Buffer.compare(verifierBytes, git(resolvedRoot, 'cat-file', 'blob',
    `${candidateSha}:${VERIFY_RELATIVE_PATH}`)) === 0,
  'integrated schema verifier differs from the candidate commit');
  return {
    manifest,
    repoRoot: resolvedRoot,
    migrations: manifest.entries.slice(BASELINE_COUNT),
    verifierPath: verifier,
    verifierSha256: sha256Hex(verifierBytes),
    verifierSQL: verifierBytes.toString('utf8'),
  };
}

export function ledgerExportSQL() {
  return `-- frwhoop:hosted-ledger-export:read-only
\\set ON_ERROR_STOP on
begin transaction read only;
set local statement_timeout='${LEDGER_STATEMENT_TIMEOUT_SECONDS}s';
select jsonb_build_object(
  'serverTime',clock_timestamp(),
  'database',current_database(),
  'currentUser',current_user,
  'serverAddress',inet_server_addr(),
  'serverPort',inet_server_port(),
  'serverVersion',current_setting('server_version'),
  'serverVersionNum',current_setting('server_version_num'),
  'databaseOid',(select oid::text from pg_database where datname=current_database()),
  'nativeLedger',(
    select coalesce(jsonb_agg(jsonb_build_object('version',version,'name',to_jsonb(m)->>'name') order by version),'[]'::jsonb)
    from supabase_migrations.schema_migrations m
  ),
  'fullIdentityLedger',(
    select coalesce(jsonb_agg(jsonb_build_object('stableIdentity',basename,'sha256',sha256) order by basename),'[]'::jsonb)
    from supabase_migrations.scoring_source_identities
  )
)::text;
commit;
`;
}

function normalizeLedgerSnapshot(raw, binding, observedAt) {
  exactKeys(raw, [
    'serverTime', 'database', 'currentUser', 'serverAddress', 'serverPort', 'serverVersion',
    'serverVersionNum', 'databaseOid', 'nativeLedger', 'fullIdentityLedger',
  ], 'hosted ledger export');
  invariant(raw.database === binding.database, 'observed database differs from target binding');
  invariant(raw.currentUser === binding.expectedCurrentUser, 'observed current_user differs from target binding');
  nonempty(raw.serverTime, 'hosted server time');
  invariant(!Number.isNaN(Date.parse(raw.serverTime)), 'hosted server time is invalid');
  nonempty(raw.serverVersion, 'hosted server version');
  invariant(typeof raw.serverVersionNum === 'string' && /^\d+$/.test(raw.serverVersionNum), 'hosted server version number is invalid');
  invariant(typeof raw.databaseOid === 'string' && /^\d+$/.test(raw.databaseOid), 'hosted database OID is invalid');
  invariant(raw.serverAddress === null || (typeof raw.serverAddress === 'string' && raw.serverAddress.length > 0),
    'hosted server address is invalid');
  invariant(raw.serverPort === null || Number.isInteger(raw.serverPort), 'hosted server port is invalid');
  invariant(Array.isArray(raw.nativeLedger), 'hosted native ledger must be an array');
  invariant(Array.isArray(raw.fullIdentityLedger), 'hosted full-identity ledger must be an array');

  const nativeSeen = new Set();
  const nativeLedger = raw.nativeLedger.map((row, index) => {
    exactKeys(row, ['version', 'name'], `native ledger row ${index + 1}`);
    invariant(typeof row.version === 'string' && /^\d{14}$/.test(row.version), `native ledger version ${index + 1} is invalid`);
    invariant(row.name === null || typeof row.name === 'string', `native ledger name ${index + 1} is invalid`);
    invariant(!nativeSeen.has(row.version), `duplicate native migration version ${row.version}`);
    nativeSeen.add(row.version);
    return { version: row.version, name: row.name };
  }).sort((left, right) => left.version.localeCompare(right.version));

  const identitySeen = new Set();
  const fullIdentityLedger = raw.fullIdentityLedger.map((row, index) => {
    exactKeys(row, ['stableIdentity', 'sha256'], `full-identity ledger row ${index + 1}`);
    stableIdentity(row.stableIdentity, `full-identity ledger row ${index + 1}`);
    sha256(row.sha256, `full-identity ledger row ${index + 1} hash`);
    invariant(!identitySeen.has(row.stableIdentity), `duplicate full migration identity ${row.stableIdentity}`);
    identitySeen.add(row.stableIdentity);
    return { stableIdentity: row.stableIdentity, sha256: row.sha256 };
  }).sort((left, right) => left.stableIdentity.localeCompare(right.stableIdentity));

  const unsigned = {
    schemaVersion: 1,
    kind: LEDGER_KIND,
    environment: 'hosted-production',
    projectRef: binding.projectRef,
    targetBindingFingerprintSha256: binding.targetBindingFingerprintSha256,
    observedAt,
    serverTime: raw.serverTime,
    targetIdentity: {
      database: raw.database,
      currentUser: raw.currentUser,
      serverAddress: raw.serverAddress,
      serverPort: raw.serverPort,
      serverVersion: raw.serverVersion,
      serverVersionNum: raw.serverVersionNum,
      databaseOid: raw.databaseOid,
    },
    nativeLedger,
    fullIdentityLedger,
    nativeLedgerFingerprintSha256: fingerprint(nativeLedger),
    fullIdentityLedgerFingerprintSha256: fingerprint(fullIdentityLedger),
  };
  return { ...unsigned, ledgerExportFingerprintSha256: fingerprint(unsigned) };
}

export function exportHostedLedger(query, binding, observedAt = new Date().toISOString(), label = 'hosted ledger export') {
  verifyTargetBinding(binding);
  return normalizeLedgerSnapshot(parseQueryJSON(query(ledgerExportSQL(), label), label), binding, observedAt);
}

function expectedRows(manifest, pendingPrefix) {
  return manifest.entries.slice(0, BASELINE_COUNT + pendingPrefix)
    .map(row => ({ stableIdentity: row.stableIdentity, sha256: row.sha256 }))
    .sort((left, right) => left.stableIdentity.localeCompare(right.stableIdentity));
}

export function reconcileHostedLedger(snapshot, manifest, { requirePendingPrefix = undefined, expectedNativeFingerprint = undefined } = {}) {
  invariant(snapshot.kind === LEDGER_KIND && snapshot.projectRef === HOSTED_PROJECT_REF, 'hosted ledger export identity differs');
  const { fingerprint: snapshotFingerprint } = signed(snapshot, 'ledgerExportFingerprintSha256');
  invariant(snapshotFingerprint === snapshot.ledgerExportFingerprintSha256, 'hosted ledger export fingerprint differs');
  invariant(snapshot.nativeLedger.length === manifest.hostedBaseline.nativeLedgerRows,
    'native hosted migration ledger row count drifted');
  if (expectedNativeFingerprint !== undefined) {
    invariant(snapshot.nativeLedgerFingerprintSha256 === expectedNativeFingerprint, 'native hosted migration ledger drifted');
  }
  let prefix = -1;
  for (let candidate = 0; candidate <= PENDING_IDENTITIES.length; candidate += 1) {
    if (canonicalJSON(snapshot.fullIdentityLedger) === canonicalJSON(expectedRows(manifest, candidate))) {
      prefix = candidate;
      break;
    }
  }
  invariant(prefix >= 0, 'hosted full-identity ledger is not the reviewed baseline plus an exact pending prefix');
  if (requirePendingPrefix !== undefined) {
    invariant(prefix === requirePendingPrefix, `hosted pending prefix is ${prefix}, expected ${requirePendingPrefix}`);
  }
  return { pendingPrefix: prefix, remaining: PENDING_IDENTITIES.slice(prefix) };
}

export function createHostedMigrationPlan({
  repoRoot, manifest, binding, databaseClient, query, now = () => new Date().toISOString(),
}) {
  const verified = verifyMigrationManifest(repoRoot, manifest);
  verifyTargetBinding(binding);
  verifyDatabaseClient(databaseClient);
  const snapshot = exportHostedLedger(query, binding, now(), 'hosted ledger export before plan');
  reconcileHostedLedger(snapshot, manifest, { requirePendingPrefix: 0 });
  const plannedAt = now();
  const unsigned = {
    schemaVersion: 1,
    kind: PLAN_KIND,
    environment: 'hosted-production',
    projectRef: HOSTED_PROJECT_REF,
    plannedAt,
    targetBindingFingerprintSha256: binding.targetBindingFingerprintSha256,
    manifestFingerprintSha256: manifest.manifestFingerprintSha256,
    schemaFingerprintSha256: manifest.schemaFingerprintSha256,
    databaseSchemaFingerprintSha256: EXPECTED_DATABASE_SCHEMA_FINGERPRINT,
    candidate: manifest.candidate,
    verifier: { path: VERIFY_RELATIVE_PATH, sha256: verified.verifierSha256 },
    databaseClient,
    baseline: {
      ledgerExportFingerprintSha256: snapshot.ledgerExportFingerprintSha256,
      nativeLedgerFingerprintSha256: snapshot.nativeLedgerFingerprintSha256,
      fullIdentityLedgerFingerprintSha256: snapshot.fullIdentityLedgerFingerprintSha256,
      nativeLedgerRows: snapshot.nativeLedger.length,
      fullIdentityRows: snapshot.fullIdentityLedger.length,
      targetIdentity: snapshot.targetIdentity,
    },
    migrations: verified.migrations.map((row, index) => ({
      applyOrdinal: index + 1,
      manifestOrdinal: row.ordinal,
      stableIdentity: row.stableIdentity,
      sha256: row.sha256,
      sizeBytes: row.sizeBytes,
      sourceWorkstream: row.sourceWorkstream,
    })),
    executionContract: {
      exactOrder: true,
      perMigrationTransaction: true,
      ledgerReceiptInSameTransaction: true,
      mutateNativeTimestampLedger: false,
      preserveAppliedHistory: true,
      replayOnUncertainCommit: false,
      stopOnLedgerDrift: true,
      postApplyIntegratedSchemaVerification: true,
      psqlConnectTimeoutSeconds: PSQL_CONNECT_TIMEOUT_SECONDS,
      psqlQueryTimeoutMilliseconds: PSQL_QUERY_TIMEOUT_MILLISECONDS,
      ledgerStatementTimeoutSeconds: LEDGER_STATEMENT_TIMEOUT_SECONDS,
      migrationStatementTimeoutSeconds: MIGRATION_STATEMENT_TIMEOUT_SECONDS,
      postverifyStatementTimeoutSeconds: POSTVERIFY_STATEMENT_TIMEOUT_SECONDS,
      expectedDatabaseSchemaFingerprintSha256: EXPECTED_DATABASE_SCHEMA_FINGERPRINT,
    },
  };
  return {
    plan: { ...unsigned, planFingerprintSha256: fingerprint(unsigned) },
    snapshot,
  };
}

export function verifyHostedMigrationPlan(plan, manifest, binding, verifierSha256, databaseClient) {
  exactKeys(plan, [
    'schemaVersion', 'kind', 'environment', 'projectRef', 'plannedAt', 'targetBindingFingerprintSha256',
    'manifestFingerprintSha256', 'schemaFingerprintSha256', 'databaseSchemaFingerprintSha256', 'candidate',
    'verifier', 'databaseClient', 'baseline', 'migrations', 'executionContract', 'planFingerprintSha256',
  ], 'hosted migration plan');
  invariant(plan.schemaVersion === 1 && plan.kind === PLAN_KIND && plan.environment === 'hosted-production',
    'hosted migration plan type differs');
  invariant(plan.projectRef === HOSTED_PROJECT_REF, `project ref must be ${HOSTED_PROJECT_REF}`);
  invariant(plan.targetBindingFingerprintSha256 === binding.targetBindingFingerprintSha256,
    'hosted migration plan target binding differs');
  invariant(plan.manifestFingerprintSha256 === manifest.manifestFingerprintSha256 &&
    plan.schemaFingerprintSha256 === manifest.schemaFingerprintSha256,
  'hosted migration plan manifest differs');
  invariant(plan.databaseSchemaFingerprintSha256 === EXPECTED_DATABASE_SCHEMA_FINGERPRINT,
    'hosted migration plan database schema fingerprint differs');
  invariant(canonicalJSON(plan.candidate) === canonicalJSON(manifest.candidate), 'hosted migration plan candidate differs');
  invariant(plan.verifier?.path === VERIFY_RELATIVE_PATH && plan.verifier.sha256 === verifierSha256,
    'hosted migration plan verifier differs');
  verifyDatabaseClient(databaseClient);
  verifyDatabaseClient(plan.databaseClient);
  invariant(canonicalJSON(plan.databaseClient) === canonicalJSON(databaseClient),
    'hosted migration plan database client differs');
  invariant(Array.isArray(plan.migrations) && plan.migrations.length === PENDING_IDENTITIES.length,
    `hosted migration plan must contain exactly ${PENDING_IDENTITIES.length} migrations`);
  for (const [index, row] of plan.migrations.entries()) {
    invariant(row.applyOrdinal === index + 1 && row.manifestOrdinal === BASELINE_COUNT + index + 1 &&
      row.stableIdentity === PENDING_IDENTITIES[index] && row.sha256 === manifest.entries[BASELINE_COUNT + index].sha256 &&
      row.sizeBytes === manifest.entries[BASELINE_COUNT + index].sizeBytes,
    `hosted migration plan order or source differs at ordinal ${index + 1}`);
  }
  invariant(plan.executionContract?.exactOrder === true && plan.executionContract?.perMigrationTransaction === true &&
    plan.executionContract?.ledgerReceiptInSameTransaction === true &&
    plan.executionContract?.mutateNativeTimestampLedger === false && plan.executionContract?.preserveAppliedHistory === true &&
    plan.executionContract?.replayOnUncertainCommit === false && plan.executionContract?.stopOnLedgerDrift === true &&
    plan.executionContract?.postApplyIntegratedSchemaVerification === true &&
    plan.executionContract?.psqlConnectTimeoutSeconds === PSQL_CONNECT_TIMEOUT_SECONDS &&
    plan.executionContract?.psqlQueryTimeoutMilliseconds === PSQL_QUERY_TIMEOUT_MILLISECONDS &&
    plan.executionContract?.ledgerStatementTimeoutSeconds === LEDGER_STATEMENT_TIMEOUT_SECONDS &&
    plan.executionContract?.migrationStatementTimeoutSeconds === MIGRATION_STATEMENT_TIMEOUT_SECONDS &&
    plan.executionContract?.postverifyStatementTimeoutSeconds === POSTVERIFY_STATEMENT_TIMEOUT_SECONDS &&
    plan.executionContract?.expectedDatabaseSchemaFingerprintSha256 === EXPECTED_DATABASE_SCHEMA_FINGERPRINT,
  'hosted migration execution contract differs');
  sha256(plan.baseline?.nativeLedgerFingerprintSha256, 'plan native ledger fingerprint');
  invariant(plan.baseline.nativeLedgerRows === manifest.hostedBaseline.nativeLedgerRows &&
    plan.baseline.fullIdentityRows === BASELINE_COUNT, 'hosted migration plan baseline counts differ');
  const { fingerprint: actual } = signed(plan, 'planFingerprintSha256');
  sha256(plan.planFingerprintSha256, 'hosted migration plan fingerprint');
  invariant(actual === plan.planFingerprintSha256, 'hosted migration plan fingerprint differs');
  return plan;
}

function stripReviewedTransaction(bytes, identity) {
  const text = bytes.toString('utf8');
  // Preserve PR22's exact immutable source files, which relied on the migration
  // executor's transaction. Only these byte identities may omit an outer block.
  const executorWrapped = {
    '20260922010000_object_copy_intents.sql': '5955c91bebaf706ab0cfc67f3c9a09e67a7438226bd04d66c4d4dd42a12b6eb4',
    '20260922020000_async_object_verification.sql': 'dc8ce2caf80bf34b83027d4651386609bb7f63c6045b92c37e1e9c64dbf38a0d',
  };
  if (Object.hasOwn(executorWrapped, identity)) {
    invariant(sha256Hex(bytes) === executorWrapped[identity],
      `executor-wrapped migration bytes differ: ${identity}`);
    return text.trim();
  }
  // Forward migrations may introduce themselves with comments. No executable
  // statement may precede BEGIN; the full committed bytes are verified upstream.
  const executable = text.replace(/^(?:\s|--[^\n]*(?:\n|$)|\/\*[\s\S]*?\*\/)*/, '');
  const match = executable.match(/^begin\s*;([\s\S]*)commit\s*;\s*$/i);
  invariant(match, `migration is not one reviewed outer transaction: ${identity}`);
  invariant(!/(^|\n)\s*(begin|commit|rollback)\s*;/i.test(match[1]),
    `migration contains nested transaction control: ${identity}`);
  return match[1].trim();
}

function sqlLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

export function migrationApplySQL({ migrationBytes, migration, expectedNativeLedger, expectedFullIdentityLedger }) {
  const body = stripReviewedTransaction(migrationBytes, migration.stableIdentity);
  const expectedNative = canonicalJSON(expectedNativeLedger);
  const expectedFull = canonicalJSON(expectedFullIdentityLedger);
  return `-- frwhoop:hosted-apply:${migration.applyOrdinal}:${migration.stableIdentity}
\\set ON_ERROR_STOP on
begin;
set local statement_timeout='${MIGRATION_STATEMENT_TIMEOUT_SECONDS}s';
select pg_advisory_xact_lock(hashtextextended(${sqlLiteral(`frwhoop-hosted-migrations:${HOSTED_PROJECT_REF}`)},0));
lock table supabase_migrations.schema_migrations in share mode;
lock table supabase_migrations.scoring_source_identities in share row exclusive mode;
do $frwhoop_precondition$
declare observed_native jsonb; observed_full jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('version',version,'name',to_jsonb(m)->>'name') order by version),'[]'::jsonb)
    into observed_native from supabase_migrations.schema_migrations m;
  select coalesce(jsonb_agg(jsonb_build_object('stableIdentity',basename,'sha256',sha256) order by basename),'[]'::jsonb)
    into observed_full from supabase_migrations.scoring_source_identities;
  if observed_native is distinct from ${sqlLiteral(expectedNative)}::jsonb then
    raise exception 'frwhoop_native_ledger_drift';
  end if;
  if observed_full is distinct from ${sqlLiteral(expectedFull)}::jsonb then
    raise exception 'frwhoop_full_identity_ledger_drift';
  end if;
end
$frwhoop_precondition$;

${body}

insert into supabase_migrations.scoring_source_identities(basename,sha256)
values (${sqlLiteral(migration.stableIdentity)},${sqlLiteral(migration.sha256)});
commit;
select jsonb_build_object('status','APPLIED','stableIdentity',${sqlLiteral(migration.stableIdentity)},
  'sha256',${sqlLiteral(migration.sha256)})::text;
`;
}

function stateRecord(plan, status, appliedPrefix, receipts, now, detail = null) {
  const unsigned = {
    schemaVersion: 1,
    kind: STATE_KIND,
    projectRef: HOSTED_PROJECT_REF,
    planFingerprintSha256: plan.planFingerprintSha256,
    status,
    updatedAt: now,
    appliedPrefix,
    remaining: PENDING_IDENTITIES.slice(appliedPrefix),
    receipts,
    detail,
  };
  return { ...unsigned, stateFingerprintSha256: fingerprint(unsigned) };
}

function verifyState(state, plan) {
  invariant(state?.kind === STATE_KIND && state.planFingerprintSha256 === plan.planFingerprintSha256,
    'existing hosted migration state belongs to a different plan');
  const { fingerprint: actual } = signed(state, 'stateFingerprintSha256');
  invariant(actual === state.stateFingerprintSha256, 'existing hosted migration state fingerprint differs');
  invariant(Number.isInteger(state.appliedPrefix) && state.appliedPrefix >= 0 && state.appliedPrefix <= PENDING_IDENTITIES.length,
    'existing hosted migration state applied prefix is invalid');
  invariant(Array.isArray(state.receipts), 'existing hosted migration receipts are invalid');
  return state;
}

function postverifySQL(verifiedSQL) {
  invariant(typeof verifiedSQL === 'string' && verifiedSQL.length > 0,
    'captured integrated schema verifier is missing');
  return `-- frwhoop:integrated-schema-verification:read-only\nbegin transaction read only;\nset local statement_timeout='${POSTVERIFY_STATEMENT_TIMEOUT_SECONDS}s';\n${verifiedSQL}\ncommit;\n`;
}

function validatePostverify(raw) {
  const result = parseQueryJSON(raw, 'integrated schema verification');
  invariant(result.status === 'PASS', 'integrated schema verification did not pass');
  sha256(result.schema_fingerprint_sha256, 'observed integrated schema fingerprint');
  invariant(result.schema_fingerprint_sha256 === EXPECTED_DATABASE_SCHEMA_FINGERPRINT,
    'integrated database schema fingerprint differs from the disposable-database release fingerprint');
  invariant(result.compute_families === 27 && result.compute_metrics === 80,
    'integrated compute ownership registry differs');
  invariant(result.selected_functions === 18 && result.selected_triggers === 11 &&
    result.selected_policies === 24,
  'integrated function, trigger, queue, grant, or RLS verification counts differ');
  return result;
}

function loadExistingState(evidenceDir, plan, now) {
  const filename = path.join(evidenceDir, 'hosted-migration-state.json');
  if (!fs.existsSync(filename)) return stateRecord(plan, 'READY_TO_APPLY', 0, [], now, null);
  return verifyState(readJSON(filename, 'hosted migration state'), plan);
}

function writeState(evidenceDir, state) {
  atomicWrite(path.join(evidenceDir, 'hosted-migration-state.json'), state);
}

function writeSnapshot(evidenceDir, basename, snapshot, exclusive = true) {
  atomicWrite(path.join(evidenceDir, basename), snapshot, { exclusive });
}

function receiptFilename(receipt) {
  const ordinal = String(receipt.applyOrdinal).padStart(2, '0');
  const base = `${ordinal}-${receipt.stableIdentity}`;
  return receipt.status === 'APPLIED_AND_RECONCILED'
    ? `${base}.json`
    : `${base}-${receipt.status.toLowerCase().replaceAll('_', '-')}-${fingerprint(receipt).slice(0, 12)}.json`;
}

export function applyHostedMigrationPlan({
  repoRoot, manifest, binding, databaseClient, plan, authorizedPlanFingerprint, evidenceDir, query,
  now = () => new Date().toISOString(),
}) {
  const verified = verifyMigrationManifest(repoRoot, manifest);
  verifyTargetBinding(binding);
  verifyHostedMigrationPlan(plan, manifest, binding, verified.verifierSha256, databaseClient);
  invariant(authorizedPlanFingerprint === plan.planFingerprintSha256,
    'apply requires the exact reviewed plan fingerprint');
  const resolvedEvidence = path.resolve(evidenceDir);
  fs.mkdirSync(resolvedEvidence, { recursive: true, mode: 0o700 });
  let state = loadExistingState(resolvedEvidence, plan, now());
  const before = exportHostedLedger(query, binding, now(), 'hosted ledger export before apply');
  const beforeReconciliation = reconcileHostedLedger(before, manifest, {
    expectedNativeFingerprint: plan.baseline.nativeLedgerFingerprintSha256,
  });
  if (beforeReconciliation.pendingPrefix !== state.appliedPrefix) {
    const recoverableInterruptedCommit = beforeReconciliation.pendingPrefix === state.appliedPrefix + 1 &&
      ['APPLYING', 'BLOCKED_LEDGER_DRIFT'].includes(state.status);
    invariant(recoverableInterruptedCommit,
      'hosted ledger prefix differs from interruption-safe local state');
    const recoveredMigration = plan.migrations[state.appliedPrefix];
    const recoveredReceipt = {
      applyOrdinal: recoveredMigration.applyOrdinal,
      stableIdentity: recoveredMigration.stableIdentity,
      sha256: recoveredMigration.sha256,
      status: 'RECOVERED_ATOMIC_REMOTE_COMMIT',
      startedAt: state.updatedAt,
      observedAt: now(),
      ledgerExportFingerprintSha256: before.ledgerExportFingerprintSha256,
    };
    const recoveredReceipts = [...state.receipts, recoveredReceipt];
    atomicWrite(path.join(resolvedEvidence, 'receipts', receiptFilename(recoveredReceipt)), recoveredReceipt,
      { exclusive: true });
    state = stateRecord(plan, 'RESUMED_AFTER_ATOMIC_REMOTE_COMMIT', beforeReconciliation.pendingPrefix,
      recoveredReceipts, now(), 'The committed full-identity receipt was reconciled before any later migration.');
  }
  writeSnapshot(resolvedEvidence,
    `ledger-before-apply-${beforeReconciliation.pendingPrefix}-${before.ledgerExportFingerprintSha256}.json`, before);
  writeState(resolvedEvidence, state);

  const receipts = [...state.receipts];
  let snapshot = before;
  let prefix = beforeReconciliation.pendingPrefix;
  for (let index = prefix; index < plan.migrations.length; index += 1) {
    const migration = plan.migrations[index];
    const beforeStep = reconcileHostedLedger(snapshot, manifest, {
      requirePendingPrefix: index,
      expectedNativeFingerprint: plan.baseline.nativeLedgerFingerprintSha256,
    });
    void beforeStep;
    const filename = path.join(verified.repoRoot, MIGRATION_DIRECTORY, migration.stableIdentity);
    const bytes = fs.readFileSync(filename);
    invariant(bytes.length === migration.sizeBytes && sha256Hex(bytes) === migration.sha256,
      `migration source changed after plan: ${migration.stableIdentity}`);
    const sql = migrationApplySQL({
      migrationBytes: bytes,
      migration,
      expectedNativeLedger: snapshot.nativeLedger,
      expectedFullIdentityLedger: snapshot.fullIdentityLedger,
    });
    const startedAt = now();
    state = stateRecord(plan, 'APPLYING', index, receipts, startedAt, migration.stableIdentity);
    writeState(resolvedEvidence, state);
    let applyError = null;
    try {
      const result = parseQueryJSON(query(sql, `apply ${migration.stableIdentity}`), `apply ${migration.stableIdentity}`);
      invariant(result.status === 'APPLIED' && result.stableIdentity === migration.stableIdentity && result.sha256 === migration.sha256,
        `apply receipt differs for ${migration.stableIdentity}`);
    } catch (error) {
      applyError = error;
    }

    try {
      snapshot = exportHostedLedger(query, binding, now(),
        `hosted ledger export after ${applyError ? 'failed ' : ''}${migration.stableIdentity}`);
      const reconciliation = reconcileHostedLedger(snapshot, manifest, {
        expectedNativeFingerprint: plan.baseline.nativeLedgerFingerprintSha256,
      });
      if (applyError) {
        const committed = reconciliation.pendingPrefix === index + 1;
        const rolledBack = reconciliation.pendingPrefix === index;
        invariant(committed || rolledBack, `hosted ledger drifted after failed ${migration.stableIdentity}`);
        const receipt = {
          applyOrdinal: index + 1,
          stableIdentity: migration.stableIdentity,
          sha256: migration.sha256,
          status: committed ? 'COMMITTED_RESPONSE_UNKNOWN' : 'ROLLED_BACK',
          startedAt,
          observedAt: now(),
          ledgerExportFingerprintSha256: snapshot.ledgerExportFingerprintSha256,
        };
        receipts.push(receipt);
        atomicWrite(path.join(resolvedEvidence, 'receipts', receiptFilename(receipt)), receipt, { exclusive: true });
        state = stateRecord(plan, committed ? 'STOPPED_AFTER_UNCERTAIN_RESPONSE' : 'STOPPED_AFTER_ROLLBACK',
          committed ? index + 1 : index, receipts, now(),
          applyError instanceof Error ? applyError.message : 'apply failed');
        writeState(resolvedEvidence, state);
        throw applyError;
      }
      invariant(reconciliation.pendingPrefix === index + 1,
        `hosted ledger did not record ${migration.stableIdentity} after a successful response`);
    } catch (reconciliationError) {
      if (applyError && reconciliationError === applyError) throw applyError;
      state = stateRecord(plan, 'BLOCKED_LEDGER_DRIFT', index, receipts, now(),
        reconciliationError instanceof Error ? reconciliationError.message : 'ledger reconciliation failed');
      writeState(resolvedEvidence, state);
      throw reconciliationError;
    }

    const receipt = {
      applyOrdinal: index + 1,
      stableIdentity: migration.stableIdentity,
      sha256: migration.sha256,
      status: 'APPLIED_AND_RECONCILED',
      startedAt,
      observedAt: now(),
      ledgerExportFingerprintSha256: snapshot.ledgerExportFingerprintSha256,
    };
    receipts.push(receipt);
    atomicWrite(path.join(resolvedEvidence, 'receipts', receiptFilename(receipt)), receipt, { exclusive: true });
    prefix = index + 1;
    state = stateRecord(plan, prefix === PENDING_IDENTITIES.length ? 'APPLIED_PENDING_POSTVERIFY' : 'APPLYING',
      prefix, receipts, now(), null);
    writeState(resolvedEvidence, state);
  }

  const finalSnapshot = snapshot;
  reconcileHostedLedger(finalSnapshot, manifest, {
    requirePendingPrefix: PENDING_IDENTITIES.length,
    expectedNativeFingerprint: plan.baseline.nativeLedgerFingerprintSha256,
  });
  writeSnapshot(resolvedEvidence, `post-apply-hosted-ledger-${finalSnapshot.ledgerExportFingerprintSha256}.json`, finalSnapshot);
  let verification;
  try {
    verification = validatePostverify(query(postverifySQL(verified.verifierSQL), 'integrated schema verification'));
    atomicWrite(path.join(resolvedEvidence, `integrated-schema-verification-${fingerprint(verification)}.json`), verification,
      { exclusive: true });
  } catch (error) {
    state = stateRecord(plan, 'POSTVERIFY_FAILED', PENDING_IDENTITIES.length, receipts, now(),
      error instanceof Error ? error.message : 'postverify failed');
    writeState(resolvedEvidence, state);
    throw error;
  }
  state = stateRecord(plan, 'PASS', PENDING_IDENTITIES.length, receipts, now(), null);
  writeState(resolvedEvidence, state);
  return { status: 'PASS', state, ledger: finalSnapshot, verification };
}

export function verifyHostedMigrationResult({
  repoRoot, manifest, binding, databaseClient, plan, evidenceDir, query, now = () => new Date().toISOString(),
}) {
  const verified = verifyMigrationManifest(repoRoot, manifest);
  verifyTargetBinding(binding);
  verifyHostedMigrationPlan(plan, manifest, binding, verified.verifierSha256, databaseClient);
  const snapshot = exportHostedLedger(query, binding, now(), 'hosted ledger export during verification');
  reconcileHostedLedger(snapshot, manifest, {
    requirePendingPrefix: PENDING_IDENTITIES.length,
    expectedNativeFingerprint: plan.baseline.nativeLedgerFingerprintSha256,
  });
  const verification = validatePostverify(query(postverifySQL(verified.verifierSQL), 'integrated schema verification'));
  const receipt = {
    schemaVersion: 1,
    kind: 'frwhoop-hosted-migration-verification',
    projectRef: HOSTED_PROJECT_REF,
    planFingerprintSha256: plan.planFingerprintSha256,
    verifiedAt: now(),
    ledgerExportFingerprintSha256: snapshot.ledgerExportFingerprintSha256,
    databaseClient,
    verification,
    status: 'PASS',
  };
  const result = { ...receipt, verificationReceiptFingerprintSha256: fingerprint(receipt) };
  if (evidenceDir) atomicWrite(path.join(path.resolve(evidenceDir),
    `hosted-migration-verification-${result.verificationReceiptFingerprintSha256}.json`), result, { exclusive: true });
  return result;
}

function parseFlags(argv, allowed) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    invariant(allowed.has(key) && value !== undefined && !values.has(key), 'hosted migration command arguments are invalid');
    values.set(key, value);
  }
  invariant(values.size === allowed.size, 'hosted migration command arguments are incomplete');
  return Object.fromEntries([...values].map(([key, value]) => [key.slice(2).replaceAll('-', '_'), value]));
}

function integer(value, label) {
  invariant(typeof value === 'string' && /^\d+$/.test(value), `${label} must be an integer`);
  return Number(value);
}

function cli(argv) {
  const [mode, ...rest] = argv;
  if (mode === 'bind-target') {
    const pinnedRoot = rest.includes('--ssl-root-cert') || rest.includes('--ssl-root-cert-sha256');
    const args = parseFlags(rest, new Set(['--project-ref', '--host', '--port', '--database', '--user', '--expected-current-user', '--output',
      ...(pinnedRoot ? ['--ssl-root-cert', '--ssl-root-cert-sha256'] : [])]));
    const binding = createTargetBinding({
      projectRef: args.project_ref,
      host: args.host,
      port: integer(args.port, 'target port'),
      database: args.database,
      user: args.user,
      expectedCurrentUser: args.expected_current_user,
      sslRootCert: args.ssl_root_cert,
      sslRootCertSha256: args.ssl_root_cert_sha256,
    });
    atomicWrite(args.output, binding, { exclusive: true });
    process.stdout.write(`${JSON.stringify({ status: 'TARGET_BOUND', projectRef: binding.projectRef,
      targetBindingFingerprintSha256: binding.targetBindingFingerprintSha256 })}\n`);
    return;
  }
  if (mode === 'plan') {
    const args = parseFlags(rest, new Set([
      '--repo-root', '--manifest', '--project-ref', '--target-binding', '--evidence-dir', '--psql-path',
    ]));
    invariant(args.project_ref === HOSTED_PROJECT_REF, `project ref must be ${HOSTED_PROJECT_REF}`);
    const manifest = readJSON(path.resolve(args.manifest), 'migration manifest');
    const binding = verifyTargetBinding(readJSON(path.resolve(args.target_binding), 'hosted target binding'), args.project_ref);
    const databaseClient = inspectPsqlExecutable(args.psql_path);
    const query = createPsqlRunner(binding, databaseClient);
    const result = createHostedMigrationPlan({
      repoRoot: path.resolve(args.repo_root), manifest, binding, databaseClient, query,
    });
    const evidence = path.resolve(args.evidence_dir);
    fs.mkdirSync(evidence, { recursive: true, mode: 0o700 });
    atomicWrite(path.join(evidence, 'preflight-hosted-ledger.json'), result.snapshot, { exclusive: true });
    atomicWrite(path.join(evidence, 'hosted-migration-plan.json'), result.plan, { exclusive: true });
    const state = stateRecord(result.plan, 'PLANNED', 0, [], new Date().toISOString(), null);
    writeState(evidence, state);
    process.stdout.write(`${JSON.stringify({ status: 'PLAN_READY', projectRef: HOSTED_PROJECT_REF,
      planFingerprintSha256: result.plan.planFingerprintSha256, pending: result.plan.migrations.length })}\n`);
    return;
  }
  if (mode === 'apply') {
    const args = parseFlags(rest, new Set([
      '--repo-root', '--manifest', '--project-ref', '--target-binding', '--plan', '--evidence-dir',
      '--apply-plan-fingerprint', '--psql-path',
    ]));
    invariant(args.project_ref === HOSTED_PROJECT_REF, `project ref must be ${HOSTED_PROJECT_REF}`);
    const manifest = readJSON(path.resolve(args.manifest), 'migration manifest');
    const binding = verifyTargetBinding(readJSON(path.resolve(args.target_binding), 'hosted target binding'), args.project_ref);
    const plan = readJSON(path.resolve(args.plan), 'hosted migration plan');
    const databaseClient = inspectPsqlExecutable(args.psql_path, spawnSync, plan.databaseClient);
    const result = applyHostedMigrationPlan({
      repoRoot: path.resolve(args.repo_root), manifest, binding, databaseClient, plan,
      authorizedPlanFingerprint: args.apply_plan_fingerprint,
      evidenceDir: path.resolve(args.evidence_dir), query: createPsqlRunner(binding, databaseClient),
    });
    process.stdout.write(`${JSON.stringify({ status: result.status, projectRef: HOSTED_PROJECT_REF,
      planFingerprintSha256: plan.planFingerprintSha256, applied: result.state.appliedPrefix })}\n`);
    return;
  }
  if (mode === 'verify') {
    const args = parseFlags(rest, new Set([
      '--repo-root', '--manifest', '--project-ref', '--target-binding', '--plan', '--evidence-dir', '--psql-path',
    ]));
    invariant(args.project_ref === HOSTED_PROJECT_REF, `project ref must be ${HOSTED_PROJECT_REF}`);
    const manifest = readJSON(path.resolve(args.manifest), 'migration manifest');
    const binding = verifyTargetBinding(readJSON(path.resolve(args.target_binding), 'hosted target binding'), args.project_ref);
    const plan = readJSON(path.resolve(args.plan), 'hosted migration plan');
    const databaseClient = inspectPsqlExecutable(args.psql_path, spawnSync, plan.databaseClient);
    const result = verifyHostedMigrationResult({
      repoRoot: path.resolve(args.repo_root), manifest, binding, databaseClient, plan,
      evidenceDir: path.resolve(args.evidence_dir), query: createPsqlRunner(binding, databaseClient),
    });
    process.stdout.write(`${JSON.stringify({ status: result.status, projectRef: HOSTED_PROJECT_REF,
      planFingerprintSha256: plan.planFingerprintSha256 })}\n`);
    return;
  }
  throw new Error('NOT_READY: usage: hosted-migration-release.mjs bind-target|plan|apply|verify [exact options]');
}

if (process.argv[1] && fs.existsSync(process.argv[1]) && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  try { cli(process.argv.slice(2)); } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : 'NOT_READY: unknown hosted migration error'}\n`);
    process.exitCode = 1;
  }
}
