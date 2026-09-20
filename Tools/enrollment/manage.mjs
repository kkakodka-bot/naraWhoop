#!/usr/bin/env node

import { createHash, createHmac, randomBytes, randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const CODE_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const CODE_PREFIX = 'NARA';
const DEFAULT_EXPIRY_HOURS = 168;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function normalizeEnrollmentCode(value) {
  const compact = String(value || '')
    .toUpperCase()
    .replace(/[\t\n\v\f\r -]/g, '')
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1');
  if (!compact.startsWith(CODE_PREFIX)) throw new Error('invalid enrollment code');
  const payload = compact.slice(CODE_PREFIX.length);
  if (payload.length !== 20 || [...payload].some((character) => !CODE_ALPHABET.includes(character))) {
    throw new Error('invalid enrollment code');
  }
  return `${CODE_PREFIX}${payload}`;
}

export function generateEnrollmentCode(random = randomBytes) {
  const bytes = random(20);
  if (!(bytes instanceof Uint8Array) || bytes.length !== 20) {
    throw new Error('enrollment RNG must return 20 bytes');
  }
  const payload = [...bytes].map((byte) => CODE_ALPHABET[byte & 31]).join('');
  const groups = payload.match(/.{4}/g);
  return `${CODE_PREFIX}-${groups.join('-')}`;
}

function validateEnrollmentPepper(pepper) {
  if (typeof pepper !== 'string' || Buffer.byteLength(pepper, 'utf8') < 32) {
    throw new Error('NOOP_ENROLLMENT_PEPPER must contain at least 32 bytes');
  }
  if (pepper !== pepper.trim()) {
    throw new Error('NOOP_ENROLLMENT_PEPPER must not contain leading or trailing whitespace');
  }
}

export function hashEnrollmentCode(code, pepper) {
  validateEnrollmentPepper(pepper);
  return createHmac('sha256', pepper).update(normalizeEnrollmentCode(code), 'utf8').digest('hex');
}

export function hashOpaqueToken(token) {
  return createHash('sha256').update(String(token || ''), 'utf8').digest('hex');
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = {};
  for (let index = 0; index < rest.length; index += 1) {
    const item = rest[index];
    if (!item.startsWith('--')) throw new Error(`unexpected argument: ${item}`);
    const name = item.slice(2);
    const value = rest[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`missing value for --${name}`);
    options[name] = value;
    index += 1;
  }
  return { command, options };
}

function requiredOption(options, name) {
  const value = String(options[name] || '').trim();
  if (!value) throw new Error(`--${name} is required`);
  return value;
}

function boundedLabel(value, fallback, flag = 'label') {
  const label = String(value || fallback || '').trim();
  if (!label) throw new Error(`--${flag} is required`);
  if (label.length > 120) throw new Error(`--${flag} must be at most 120 characters`);
  return label;
}

function optionalEmail(value) {
  if (value == null) return undefined;
  const email = String(value).trim();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error('--email must be a valid email address');
  }
  return email;
}

function uuid(value, flag) {
  const candidate = String(value || '').trim().toLowerCase();
  if (!UUID_RE.test(candidate)) throw new Error(`--${flag} must be a UUID`);
  return candidate;
}

function expiry(options) {
  const hours = Number(options['expires-hours'] || DEFAULT_EXPIRY_HOURS);
  if (!Number.isFinite(hours) || hours < 1 || hours > 720) {
    throw new Error('--expires-hours must be between 1 and 720');
  }
  return new Date(Date.now() + hours * 60 * 60 * 1000).toISOString();
}

function configFromEnv(env = process.env) {
  const url = String(env.SUPABASE_URL || env.PROJECT_URL || '').replace(/\/$/, '');
  const serviceRoleKey = String(env.SUPABASE_SERVICE_ROLE_KEY || env.SERVICE_ROLE_KEY || '').trim();
  const pepper = String(env.NOOP_ENROLLMENT_PEPPER || '');
  if (!url || !serviceRoleKey) {
    throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
  }
  return { url, serviceRoleKey, pepper };
}

function createAdminClient({ url, serviceRoleKey, fetchImpl = fetch }) {
  const headers = {
    apikey: serviceRoleKey,
    authorization: `Bearer ${serviceRoleKey}`,
    'content-type': 'application/json',
  };

  async function request(path, { method = 'GET', body, prefer } = {}) {
    const response = await fetchImpl(`${url}${path}`, {
      method,
      headers: prefer ? { ...headers, prefer } : headers,
      body: body == null ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    let parsed = null;
    if (text) {
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = null;
      }
    }
    if (!response.ok) {
      const message = parsed?.message || parsed?.msg || parsed?.hint || `HTTP ${response.status}`;
      throw new Error(`${method} ${path.split('?')[0]} failed: ${String(message).slice(0, 180)}`);
    }
    return parsed;
  }

  return {
    async createTester({ label, email }) {
      const generatedAlias = `tester-${randomUUID()}@users.invalid`;
      const result = await request('/auth/v1/admin/users', {
        method: 'POST',
        body: {
          email: email || generatedAlias,
          password: randomBytes(32).toString('base64url'),
          email_confirm: true,
          user_metadata: { tester_label: label },
          app_metadata: { noop_tester: true },
        },
      });
      const user = result?.user || result;
      if (!user?.id || !UUID_RE.test(user.id)) throw new Error('Auth Admin returned no user id');
      return { id: user.id, email: user.email || email || generatedAlias };
    },

    async requireTester(userId) {
      const result = await request(`/auth/v1/admin/users/${encodeURIComponent(userId)}`);
      const user = result?.user || result;
      if (user?.id !== userId) throw new Error('Auth Admin returned a different user');
      return user;
    },

    async insertEnrollmentCode({ userId, codeHash, label, expiresAt }) {
      const result = await request('/rest/v1/noop_enrollment_codes?select=id,user_id,expires_at', {
        method: 'POST',
        prefer: 'return=representation',
        body: { user_id: userId, code_hash: codeHash, label, expires_at: expiresAt },
      });
      const row = Array.isArray(result) ? result[0] : result;
      if (!row?.id || row.user_id !== userId) throw new Error('enrollment code insert returned no row');
      return row;
    },

    async createFleetToken({ label }) {
      const token = `noop_${randomBytes(32).toString('base64url')}`;
      const result = await request('/rest/v1/noop_ingest_tokens?select=id,label,created_at,token_kind', {
        method: 'POST',
        prefer: 'return=representation',
        body: {
          user_id: null,
          token_hash: hashOpaqueToken(token),
          label,
          token_kind: 'fleet',
          source_id: null,
        },
      });
      const row = Array.isArray(result) ? result[0] : result;
      if (!row?.id || row.token_kind !== 'fleet') throw new Error('fleet token insert returned no row');
      return { token, row };
    },

    async markFleetToken({ token }) {
      const query = new URLSearchParams({
        token_hash: `eq.${hashOpaqueToken(token)}`,
        revoked_at: 'is.null',
        select: 'id,label,created_at,token_kind',
      });
      const result = await request(`/rest/v1/noop_ingest_tokens?${query}`, {
        method: 'PATCH',
        prefer: 'return=representation',
        body: { token_kind: 'fleet', user_id: null, source_id: null, expires_at: null },
      });
      const row = Array.isArray(result) ? result[0] : result;
      if (!row?.id || row.token_kind !== 'fleet') throw new Error('active token not found');
      return row;
    },

    async revokeToken(tokenId) {
      const query = new URLSearchParams({ id: `eq.${tokenId}`, revoked_at: 'is.null', select: 'id,revoked_at' });
      const result = await request(`/rest/v1/noop_ingest_tokens?${query}`, {
        method: 'PATCH',
        prefer: 'return=representation',
        body: { revoked_at: new Date().toISOString() },
      });
      const row = Array.isArray(result) ? result[0] : result;
      if (!row?.id) throw new Error('active token not found');
      return row;
    },
  };
}

async function issueCode({ client, config, userId, label, expiresAt }) {
  await client.requireTester(userId);
  const code = generateEnrollmentCode();
  const row = await client.insertEnrollmentCode({
    userId,
    codeHash: hashEnrollmentCode(code, config.pepper),
    label,
    expiresAt,
  });
  return {
    userId,
    enrollmentCode: code,
    codeId: row.id,
    expiresAt: row.expires_at || expiresAt,
  };
}

function printUsage() {
  console.error(`Usage:
  node Tools/enrollment/manage.mjs create-tester --label <name> [--email <address>] [--expires-hours 168]
  node Tools/enrollment/manage.mjs issue-code --user-id <uuid> --label <installation> [--expires-hours 168]
  node Tools/enrollment/manage.mjs create-fleet-token --label <build-or-cohort>
  NOOP_FLEET_TOKEN=<existing-noop-token> node Tools/enrollment/manage.mjs mark-fleet-token
  node Tools/enrollment/manage.mjs revoke-token --token-id <uuid>

Server-only environment:
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, NOOP_ENROLLMENT_PEPPER`);
}

export async function main(argv = process.argv.slice(2), env = process.env) {
  const { command, options } = parseArgs(argv);
  if (!command || command === 'help') {
    printUsage();
    return command ? 0 : 2;
  }
  const config = configFromEnv(env);
  const client = createAdminClient(config);

  if (command === 'create-tester') {
    validateEnrollmentPepper(config.pepper);
    const label = boundedLabel(options.label);
    const codeLabel = boundedLabel(options['code-label'], 'first installation', 'code-label');
    const email = optionalEmail(options.email);
    const expiresAt = expiry(options);
    const tester = await client.createTester({ label, email });
    const result = await issueCode({
      client,
      config,
      userId: tester.id,
      label: codeLabel,
      expiresAt,
    });
    console.log(JSON.stringify({ ...result, testerEmail: tester.email }, null, 2));
    return 0;
  }

  if (command === 'issue-code') {
    validateEnrollmentPepper(config.pepper);
    const result = await issueCode({
      client,
      config,
      userId: uuid(requiredOption(options, 'user-id'), 'user-id'),
      label: boundedLabel(options.label),
      expiresAt: expiry(options),
    });
    console.log(JSON.stringify(result, null, 2));
    return 0;
  }

  if (command === 'create-fleet-token') {
    const result = await client.createFleetToken({ label: boundedLabel(options.label) });
    console.log(JSON.stringify({ fleetToken: result.token, tokenId: result.row.id }, null, 2));
    return 0;
  }

  if (command === 'mark-fleet-token') {
    const token = String(options.token || env.NOOP_FLEET_TOKEN || '').trim();
    if (!token) throw new Error('NOOP_FLEET_TOKEN or --token is required');
    const row = await client.markFleetToken({ token });
    console.log(JSON.stringify({ tokenId: row.id, tokenKind: row.token_kind }, null, 2));
    return 0;
  }

  if (command === 'revoke-token') {
    const row = await client.revokeToken(uuid(requiredOption(options, 'token-id'), 'token-id'));
    console.log(JSON.stringify({ tokenId: row.id, revokedAt: row.revoked_at }, null, 2));
    return 0;
  }

  throw new Error(`unknown command: ${command}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().then((status) => {
    process.exitCode = status;
  }).catch((error) => {
    console.error(`Enrollment admin failed: ${error.message}`);
    process.exitCode = 1;
  });
}
