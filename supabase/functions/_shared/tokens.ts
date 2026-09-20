// Port of the retired Node receiver + resolvePushUser.js, narrowed to the edge context:
// a bearer is either a Supabase Auth JWT (validated against auth/v1/user) or an opaque `noop_`
// ingest token (SHA-256 lookup in noop_ingest_tokens). There is no dev-user or device-token
// fallback here — the functions are always production.
import { createHash } from 'node:crypto';
import { isUuid } from './keys.ts';
import type { SupabaseRest } from './rest.ts';

export const INGEST_TOKEN_PREFIX = 'noop_';
export const FLEET_TOKEN_HEADER = 'x-noop-fleet-token';

export type TokenKind = 'legacy_upload' | 'fleet' | 'installation';
export type UploadAuthMode = 'installation' | 'legacy_fleet';

export class IdentityError extends Error {
  status: number;
  code: string;
  constructor(message: string, status = 401) {
    super(message);
    this.status = status;
    this.code = 'unauthorized';
  }
}

export function looksLikeJwt(token: unknown): boolean {
  const parts = String(token || '').split('.');
  return parts.length === 3 && parts.every((part) => part.length > 0);
}

export function hashIngestToken(token: unknown): string {
  return createHash('sha256').update(String(token || ''), 'utf8').digest('hex');
}

export function bearerToken(headers: Headers): string {
  const auth = headers.get('authorization') || '';
  if (auth.startsWith('Bearer ')) return auth.slice(7).trim();
  return '';
}

export function fleetToken(headers: Headers): string {
  const value = (headers.get(FLEET_TOKEN_HEADER) || '').trim();
  if (value.startsWith('Bearer ')) return value.slice(7).trim();
  return value;
}

export async function lookupAuthUser({ accessToken, supabaseUrl, anonKey, fetchImpl = fetch }: {
  accessToken: string;
  supabaseUrl: string;
  anonKey: string;
  fetchImpl?: typeof fetch;
}) {
  if (!accessToken || !supabaseUrl || !anonKey) return null;
  const res = await fetchImpl(`${supabaseUrl}/auth/v1/user`, {
    headers: {
      apikey: anonKey,
      authorization: `Bearer ${accessToken}`,
    },
  });
  if (!res.ok) return null;
  const u = await res.json().catch(() => null);
  if (u?.id && isUuid(u.id)) return { id: u.id as string, email: u.email || null, source: 'jwt' };
  return null;
}

function tokenKind(row: any): TokenKind {
  const value = String(row?.token_kind || 'legacy_upload');
  if (value === 'fleet' || value === 'installation') return value;
  return 'legacy_upload';
}

function tokenExpired(row: any, now: Date): boolean {
  if (!row?.expires_at) return false;
  const expires = Date.parse(String(row.expires_at));
  return !Number.isFinite(expires) || expires <= now.getTime();
}

export async function lookupOpaqueToken({
  token,
  rest,
  now = () => new Date(),
}: {
  token: string;
  rest: SupabaseRest;
  now?: () => Date;
}) {
  if (!token.startsWith(INGEST_TOKEN_PREFIX) || token.length <= INGEST_TOKEN_PREFIX.length) return null;
  const tokenHash = hashIngestToken(token);
  const rows = await rest.select(
    'noop_ingest_tokens',
    `token_hash=eq.${tokenHash}&revoked_at=is.null&select=id,user_id,label,token_kind,source_id,expires_at,enrollment_code_id,created_at,last_used_at,revoked_at`,
  );
  const row = rows?.[0];
  if (!row?.id || tokenExpired(row, now())) return null;
  try {
    await rest.patch('noop_ingest_tokens', { last_used_at: now().toISOString() }, `id=eq.${row.id}`);
  } catch {
    // Authentication remains valid if the best-effort usage timestamp cannot be written.
  }
  return {
    ...row,
    token_kind: tokenKind(row),
  };
}

export async function resolveJwtUser({ headers, supabaseUrl, anonKey, fetchImpl = fetch }: {
  headers: Headers;
  supabaseUrl: string;
  anonKey: string;
  fetchImpl?: typeof fetch;
}) {
  const token = bearerToken(headers);
  if (!token || !looksLikeJwt(token)) throw new IdentityError('authentication required');
  const user = await lookupAuthUser({ accessToken: token, supabaseUrl, anonKey, fetchImpl });
  if (!user) throw new IdentityError('authentication required');
  return user;
}

/**
 * Resolve the FRWHOOP user for NOOP push. Order with an Authorization: Bearer:
 *   1. JWT-shaped bearer validated against Supabase Auth → source `jwt`
 *   2. If JWT-shaped and validation failed → fail closed (401)
 *   3. Opaque ingest token (SHA-256 hash lookup) → source `ingest_token`
 * No bearer at all → 401. (The Node backend's device-token/dev-user fallbacks are dev-only and
 * deliberately absent here.)
 */
export async function resolvePushUser({ headers, rest, supabaseUrl, anonKey, fetchImpl = fetch }: {
  headers: Headers;
  rest: SupabaseRest;
  supabaseUrl: string;
  anonKey: string;
  fetchImpl?: typeof fetch;
}) {
  const token = bearerToken(headers);
  if (!token) throw new IdentityError('authentication required');

  if (looksLikeJwt(token)) {
    const jwtUser = await lookupAuthUser({ accessToken: token, supabaseUrl, anonKey, fetchImpl });
    if (jwtUser) return jwtUser;
    throw new IdentityError('authentication required');
  }

  const row = await lookupOpaqueToken({ token, rest });
  if (!row?.user_id || row.token_kind === 'fleet') throw new IdentityError('authentication required');
  return {
    id: row.user_id as string,
    email: null,
    source: 'ingest_token',
    tokenId: row.id,
    tokenKind: row.token_kind as TokenKind,
    sourceId: row.source_id || null,
  };
}

/** Validate the lower-trust build/fleet credential. It must be explicitly classified as fleet. */
export async function resolveFleetAuthorization({
  headers,
  rest,
  fromAuthorization = false,
}: {
  headers: Headers;
  rest: SupabaseRest;
  fromAuthorization?: boolean;
}) {
  const token = fromAuthorization ? bearerToken(headers) : fleetToken(headers);
  if (!token || looksLikeJwt(token)) throw new IdentityError('fleet authorization required');
  const row = await lookupOpaqueToken({ token, rest });
  if (!row || row.token_kind !== 'fleet') {
    throw new IdentityError('fleet authorization required');
  }
  return { tokenId: row.id as string, tokenKind: row.token_kind as TokenKind };
}

/**
 * Upload identity is fail-closed: a personal installation token in Authorization plus a separate
 * fleet/build credential. The optional legacy path applies only when no identity header is present
 * and is explicitly enabled by the server environment.
 */
export async function resolveUploadIdentity({
  headers,
  rest,
  allowLegacyFleetUploads = false,
}: {
  headers: Headers;
  rest: SupabaseRest;
  allowLegacyFleetUploads?: boolean;
}) {
  const token = bearerToken(headers);
  if (!token || looksLikeJwt(token)) throw new IdentityError('installation authorization required');
  const identity = await lookupOpaqueToken({ token, rest });
  if (!identity) throw new IdentityError('installation authorization required');

  if (identity.token_kind === 'installation') {
    if (!identity.user_id || !isUuid(identity.user_id) || !identity.source_id || !isUuid(identity.source_id)) {
      throw new IdentityError('installation authorization required');
    }
    await resolveFleetAuthorization({ headers, rest });
    const installations = await rest.select(
      'noop_app_installations',
      `user_id=eq.${identity.user_id}&source_id=eq.${identity.source_id}&revoked_at=is.null&select=user_id,source_id`,
    );
    if (!installations?.[0]) throw new IdentityError('installation authorization required');
    try {
      await rest.patch(
        'noop_app_installations',
        { last_seen_at: new Date().toISOString() },
        `source_id=eq.${identity.source_id}&user_id=eq.${identity.user_id}`,
      );
    } catch {
      // A telemetry timestamp cannot make an otherwise valid upload identity unavailable.
    }
    return {
      id: identity.user_id as string,
      email: null,
      source: 'installation_token',
      sourceId: identity.source_id as string,
      tokenId: identity.id as string,
      authMode: 'installation' as UploadAuthMode,
    };
  }

  // Presence of a malformed/wrong-kind fleet header must never make an invalid installation token
  // fall through to the rollout path.
  if (fleetToken(headers)) throw new IdentityError('installation authorization required');
  if (!allowLegacyFleetUploads || identity.token_kind !== 'legacy_upload' || !isUuid(identity.user_id)) {
    throw new IdentityError('installation authorization required');
  }
  return {
    id: identity.user_id as string,
    email: null,
    source: 'legacy_ingest_token',
    sourceId: null,
    tokenId: identity.id as string,
    authMode: 'legacy_fleet' as UploadAuthMode,
  };
}

/** Public shape of an ingest-token row (never the hash). Mirrors the retired Node receiver */
export function publicIngestTokenRow(row: any): Record<string, unknown> | null {
  if (!row) return null;
  return {
    id: row.id,
    label: row.label || '',
    tokenKind: tokenKind(row),
    sourceId: row.source_id || null,
    expiresAt: row.expires_at || null,
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at || null,
    revokedAt: row.revoked_at || null,
  };
}

/**
 * Mint / list / revoke opaque `noop_` ingest tokens over the service-role REST client.
 * Port of the retired Node receiver createIngestTokenStore — the Edge half of the
 * token lifecycle that Phase 1 of the backend retirement adds (POST/GET/DELETE /tokens).
 */
/** Base64url (RFC 4648 §5) from raw bytes — mirrors Node Buffer.toString('base64url'). */
function bytesToBase64Url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function generateIngestToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `${INGEST_TOKEN_PREFIX}${bytesToBase64Url(bytes)}`;
}

export function createIngestTokenStore({ rest }: { rest: SupabaseRest }) {
  return {
    configured: rest.configured,
    async mint({ userId, label = '' }: { userId: string; label?: string }) {
      const token = generateIngestToken();
      const tokenHash = hashIngestToken(token);
      const rows = await rest.upsert('noop_ingest_tokens', {
        user_id: userId,
        token_hash: tokenHash,
        label: String(label || '').slice(0, 120),
        token_kind: 'legacy_upload',
      });
      const row = Array.isArray(rows) ? rows[0] : rows;
      return { token, row: publicIngestTokenRow(row) };
    },
    async list({ userId }: { userId: string }) {
      const rows = await rest.select(
        'noop_ingest_tokens',
        `user_id=eq.${userId}&order=created_at.desc&select=id,label,token_kind,source_id,expires_at,created_at,last_used_at,revoked_at`,
      );
      return (rows || []).map(publicIngestTokenRow);
    },
    async revoke({ userId, id }: { userId: string; id: string }) {
      const rows = await rest.patch(
        'noop_ingest_tokens',
        { revoked_at: new Date().toISOString() },
        `id=eq.${id}&user_id=eq.${userId}&revoked_at=is.null&select=id,label,token_kind,source_id,expires_at,created_at,last_used_at,revoked_at`,
      );
      const row = Array.isArray(rows) ? rows[0] : rows;
      return publicIngestTokenRow(row);
    },
  };
}
