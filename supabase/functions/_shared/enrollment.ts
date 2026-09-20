import { createHmac } from 'node:crypto';
import { isUuid } from './keys.ts';
import { INGEST_TOKEN_PREFIX, hashIngestToken } from './tokens.ts';
import type { SupabaseRest } from './rest.ts';

const ENROLLMENT_CODE_RE = /^NARA[0-9A-HJKMNP-TV-Z]{20}$/;
const ALLOWED_PLATFORMS = new Set(['ios', 'macos', 'android']);
function hasControlCharacter(value: string): boolean {
  return [...value].some((character) => {
    const code = character.charCodeAt(0);
    return code < 0x20 || code === 0x7f;
  });
}

export class EnrollmentError extends Error {
  status: number;
  code: string;

  constructor(code: string, status = 400) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

/**
 * Canonical enrollment-code representation shared with ops tooling:
 * ASCII whitespace and hyphens removed, then ASCII uppercased.
 * The display form is NARA-XXXX-XXXX-XXXX-XXXX-XXXX; the canonical form is NARA + 20 symbols.
 */
export function normalizeEnrollmentCode(value: unknown): string {
  if (typeof value !== 'string' || value.length > 128) {
    throw new EnrollmentError('malformed_enrollment_code', 400);
  }
  const canonical = value
    .replace(/[\t\n\v\f\r -]/g, '')
    .toUpperCase()
    .replace(/[IL]/g, '1')
    .replace(/O/g, '0');
  if (!ENROLLMENT_CODE_RE.test(canonical)) {
    throw new EnrollmentError('malformed_enrollment_code', 400);
  }
  return canonical;
}

/** HMAC-SHA256 over the canonical code. The pepper is an Edge/ops secret, never a DB value. */
export function hashEnrollmentCode(value: unknown, pepper: string): string {
  if (typeof pepper !== 'string' || new TextEncoder().encode(pepper).length < 32) {
    throw new EnrollmentError('enrollment_not_configured', 503);
  }
  return createHmac('sha256', pepper).update(normalizeEnrollmentCode(value), 'utf8').digest('hex');
}

/**
 * Derive the installation credential deterministically for a code/source pair. This makes the
 * bounded same-source redemption retry idempotent even when duplicate HTTP responses arrive out
 * of order. Domain separation prevents the stored code HMAC from also being the upload secret.
 */
export function deriveInstallationToken(value: unknown, sourceId: string, pepper: string): string {
  if (typeof pepper !== 'string' || new TextEncoder().encode(pepper).length < 32) {
    throw new EnrollmentError('enrollment_not_configured', 503);
  }
  const normalizedSourceId = String(sourceId || '').toLowerCase();
  if (!isUuid(normalizedSourceId)) throw new EnrollmentError('invalid_source_id', 400);
  const digest = createHmac('sha256', pepper)
    .update('noop-installation-token-v1\0', 'utf8')
    .update(normalizeEnrollmentCode(value), 'utf8')
    .update('\0', 'utf8')
    .update(normalizedSourceId, 'utf8')
    .digest('base64url');
  return `${INGEST_TOKEN_PREFIX}${digest}`;
}

export function validateEnrollmentRequest(body: any) {
  const code = normalizeEnrollmentCode(body?.code);
  const sourceId = typeof body?.sourceId === 'string' ? body.sourceId.toLowerCase() : '';
  const platform = typeof body?.platform === 'string' ? body.platform.toLowerCase() : '';
  const appVersion = typeof body?.appVersion === 'string' ? body.appVersion.trim() : '';

  if (!isUuid(sourceId)) throw new EnrollmentError('invalid_source_id', 400);
  if (!ALLOWED_PLATFORMS.has(platform)) throw new EnrollmentError('invalid_platform', 400);
  if (!appVersion || appVersion.length > 64 || hasControlCharacter(appVersion)) {
    throw new EnrollmentError('invalid_app_version', 400);
  }
  return { code, sourceId, platform, appVersion };
}

function rpcEnrollmentError(err: unknown): EnrollmentError {
  const message = String((err as any)?.message || '');
  const mappings: Array<[string, number]> = [
    ['enrollment_code_expired', 410],
    ['enrollment_code_revoked', 410],
    ['enrollment_code_already_used', 409],
    ['enrollment_retry_window_elapsed', 409],
    ['enrollment_retry_unavailable', 409],
    ['enrollment_source_already_bound', 409],
    ['enrollment_code_invalid', 404],
    ['enrollment_service_role_required', 503],
  ];
  for (const [code, status] of mappings) {
    if (message.includes(code)) return new EnrollmentError(code, status);
  }
  return new EnrollmentError('enrollment_failed', 500);
}

export function createEnrollmentService({
  rest,
  pepper,
  retryWindowSeconds = 300,
}: {
  rest: SupabaseRest;
  pepper: string;
  retryWindowSeconds?: number;
}) {
  const boundedRetryWindow = Math.max(1, Math.min(900, Math.trunc(retryWindowSeconds || 300)));
  const pepperBytes = typeof pepper === 'string' ? new TextEncoder().encode(pepper).length : 0;

  return {
    get configured() {
      return Boolean(rest?.configured && pepperBytes >= 32);
    },

    async redeem(body: unknown) {
      if (!rest?.configured || pepperBytes < 32) {
        throw new EnrollmentError('enrollment_not_configured', 503);
      }
      const request = validateEnrollmentRequest(body);
      const uploadToken = deriveInstallationToken(request.code, request.sourceId, pepper);
      const codeHash = hashEnrollmentCode(request.code, pepper);
      const tokenHash = hashIngestToken(uploadToken);

      let rows: any;
      try {
        rows = await rest.rpc('redeem_noop_enrollment', {
          p_code_hash: codeHash,
          p_source_id: request.sourceId,
          p_platform: request.platform,
          p_app_version: request.appVersion,
          p_token_hash: tokenHash,
          p_retry_window_seconds: boundedRetryWindow,
        });
      } catch (err) {
        throw rpcEnrollmentError(err);
      }

      const row = Array.isArray(rows) ? rows[0] : rows;
      const userId = typeof row?.user_id === 'string' ? row.user_id.toLowerCase() : '';
      const tokenId = typeof row?.token_id === 'string' ? row.token_id.toLowerCase() : '';
      if (!isUuid(userId) || !isUuid(tokenId)) {
        throw new EnrollmentError('enrollment_failed', 500);
      }

      return {
        type: 'enrollment',
        protocolVersion: '1.1',
        userId,
        sourceId: request.sourceId,
        tokenId,
        uploadToken,
      };
    },
  };
}
