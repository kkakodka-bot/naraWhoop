// Edge-function config. Mirrors the names the retired Node receiver resolves, sourced from the
// function environment (platform-injected SUPABASE_* plus `supabase secrets` for B2).
// Server-only: these values must never ship in a client bundle.

export interface PushFunctionConfig {
  supabaseUrl: string;
  supabaseAnonKey: string;
  supabaseServiceRoleKey: string;
  b2KeyId: string;
  b2ApplicationKey: string;
  b2Bucket: string;
  b2S3Endpoint: string;
  b2Region: string;
  rawStore: string;
  enrollmentPepper: string;
  enrollmentRetryWindowSeconds: number;
  allowLegacyFleetUploads: boolean;
}

export function pushConfig(env: Record<string, string | undefined> = Deno.env.toObject()): PushFunctionConfig {
  const pick = (...names: string[]) => {
    for (const name of names) {
      const v = env[name];
      if (v != null && String(v).trim() !== '') return String(v).trim();
    }
    return '';
  };
  const withHttps = (endpoint: string) => {
    const v = endpoint.trim();
    if (!v) return '';
    return /^https?:\/\//i.test(v) ? v.replace(/\/$/, '') : `https://${v.replace(/\/$/, '')}`;
  };
  const b2KeyId = pick('B2_KEY_ID', 'KEY_ID');
  const b2Ready = Boolean(b2KeyId && pick('B2_APPLICATION_KEY', 'APPLICATION_KEY'));
  const retryWindowCandidate = Number(pick('NOOP_ENROLLMENT_RETRY_WINDOW_SECONDS') || 300);
  const enrollmentRetryWindowSeconds = Number.isFinite(retryWindowCandidate)
    ? Math.max(1, Math.min(900, Math.trunc(retryWindowCandidate)))
    : 300;
  return {
    supabaseUrl: pick('SUPABASE_URL', 'PROJECT_URL').replace(/\/$/, ''),
    supabaseAnonKey: pick('SUPABASE_ANON_KEY', 'ANNON_KEY'),
    supabaseServiceRoleKey: pick('SUPABASE_SERVICE_ROLE_KEY', 'SERVICE_ROLE_KEY'),
    b2KeyId,
    b2ApplicationKey: pick('B2_APPLICATION_KEY', 'APPLICATION_KEY'),
    b2Bucket: pick('B2_BUCKET', 'BUCKET_NAME') || 'FRWHOOP',
    b2S3Endpoint: withHttps(pick('B2_S3_ENDPOINT')),
    b2Region: pick('B2_REGION', 'B2_S3_REGION') || 'us-west-004',
    rawStore: (pick('RAW_STORE') || (b2Ready ? 'b2' : 'none')).toLowerCase(),
    enrollmentPepper: pick('NOOP_ENROLLMENT_PEPPER'),
    enrollmentRetryWindowSeconds,
    allowLegacyFleetUploads: pick('NOOP_ALLOW_LEGACY_FLEET_UPLOADS').toLowerCase() === 'true',
  };
}

/** Deterministic receiver id, ported from the retired Node receiver defaultReceiverStateId. */
export function defaultReceiverStateId(cfg: { localUserId?: string; supabaseUrl?: string }): string {
  const seed = `${cfg?.localUserId || ''}|${cfg?.supabaseUrl || ''}|frwhoop-push`;
  let hash = 0;
  for (let i = 0; i < seed.length; i += 1) hash = ((hash << 5) - hash + seed.charCodeAt(i)) | 0;
  const hex = Math.abs(hash).toString(16).padStart(8, '0');
  return `${hex.slice(0, 8)}-0000-4000-8000-${hex.padStart(12, '0').slice(0, 12)}`;
}
