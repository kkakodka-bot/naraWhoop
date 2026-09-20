// Port of the retired Node receiver — hand-rolled SigV4 for B2's S3-compatible API, path style.
// The functions need presignPut (object lane), head (completion check), and putObject (inline
// archive). List/delete/discover stay in the Node backend's ops scripts.
import { createHmac, createHash } from 'node:crypto';

export function sha256Hex(data: string | Uint8Array): string {
  return createHash('sha256').update(data as any).digest('hex');
}

function hmac(key: string | Uint8Array, data: string): Uint8Array {
  return createHmac('sha256', key as any).update(data).digest();
}

function amzDate(d: Date): string {
  return d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

function encodeRfc3986(s: string): string {
  return encodeURIComponent(s).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

function canonicalQuery(params: Record<string, string>): string {
  return Object.keys(params)
    .sort()
    .map((k) => `${encodeRfc3986(k)}=${encodeRfc3986(String(params[k]))}`)
    .join('&');
}

function signingKey(secret: string, dateStamp: string, region: string, service: string): Uint8Array {
  const kDate = hmac(`AWS4${secret}`, dateStamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, service);
  return hmac(kService, 'aws4_request');
}

function endpointHost(endpoint: string): string {
  return String(endpoint).replace(/^https?:\/\//, '').replace(/\/$/, '');
}

function requestHost(endpoint: string, bucket: string, style: string): string {
  const host = endpointHost(endpoint);
  return style === 'virtual' ? `${bucket}.${host}` : host;
}

function endpointScheme(endpoint: string): string {
  if (!endpoint.startsWith('http://')) return 'https';
  const host = new URL(endpoint).hostname;
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(host)) throw new Error('insecure_object_endpoint');
  return 'http'; // Disposable local HTTP fixture only; remote storage always uses TLS.
}

function canonicalUri(bucket: string, key: string, style: string): string {
  const encodedKey = key ? String(key).split('/').map(encodeRfc3986).join('/') : '';
  if (style === 'virtual') return encodedKey ? `/${encodedKey}` : '/';
  return encodedKey ? `/${encodeRfc3986(bucket)}/${encodedKey}` : `/${encodeRfc3986(bucket)}`;
}

/** Object URL. Path-style for B2; virtual-hosted for AWS. */
export function objectUrl(endpoint: string, bucket: string, key: string, style = 'path'): string {
  const host = requestHost(endpoint, bucket, style);
  const uri = canonicalUri(bucket, key, style);
  return `${endpointScheme(endpoint)}://${host}${uri}`;
}

export function presign({
  method,
  endpoint,
  bucket,
  key,
  region,
  accessKeyId,
  secretAccessKey,
  expiresSec,
  now = new Date(),
  headers = {},
  style = 'path',
}: {
  method: string;
  endpoint: string;
  bucket: string;
  key: string;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  expiresSec: number;
  now?: Date;
  headers?: Record<string, string>;
  style?: string;
}) {
  const host = requestHost(endpoint, bucket, style);
  const date = amzDate(now);
  const dateStamp = date.slice(0, 8);
  const credentialScope = `${dateStamp}/${region}/s3/aws4_request`;
  const uri = canonicalUri(bucket, key, style);
  const query: Record<string, string> = {
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${accessKeyId}/${credentialScope}`,
    'X-Amz-Date': date,
    'X-Amz-Expires': String(expiresSec),
    'X-Amz-SignedHeaders': 'host',
  };
  const canonicalHeaders = `host:${host}\n`;
  const canonicalRequest = [
    method.toUpperCase(),
    uri,
    canonicalQuery(query),
    canonicalHeaders,
    'host',
    'UNSIGNED-PAYLOAD',
  ].join('\n');
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    date,
    credentialScope,
    sha256Hex(canonicalRequest),
  ].join('\n');
  const sig = createHmac('sha256', signingKey(secretAccessKey, dateStamp, region, 's3') as any)
    .update(stringToSign)
    .digest('hex');
  const url = `${endpointScheme(endpoint)}://${host}${uri}?${canonicalQuery(query)}&X-Amz-Signature=${sig}`;
  return { url, expiresAt: new Date(now.getTime() + expiresSec * 1000).toISOString(), headers };
}

function signedRequest({
  method,
  endpoint,
  bucket,
  key,
  region,
  accessKeyId,
  secretAccessKey,
  now,
  query = {},
  extraHeaders = {},
  payloadHash = 'UNSIGNED-PAYLOAD',
  style = 'path',
}: {
  method: string;
  endpoint: string;
  bucket: string;
  key: string;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  now: Date;
  query?: Record<string, string>;
  extraHeaders?: Record<string, unknown>;
  payloadHash?: string;
  style?: string;
}) {
  const host = requestHost(endpoint, bucket, style);
  const date = amzDate(now);
  const dateStamp = date.slice(0, 8);
  const uri = canonicalUri(bucket, key, style);
  const q = canonicalQuery(query);
  const headers: Record<string, string> = {
    host,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': date,
  };
  for (const [name, value] of Object.entries(extraHeaders)) {
    if (value == null) continue;
    headers[String(name).toLowerCase()] = String(value);
  }
  const signed = Object.keys(headers).sort();
  const canonicalHeaders = signed.map((h) => `${h}:${headers[h]}\n`).join('');
  const canonicalRequest = [method, uri, q, canonicalHeaders, signed.join(';'), payloadHash].join('\n');
  const credentialScope = `${dateStamp}/${region}/s3/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', date, credentialScope, sha256Hex(canonicalRequest)].join('\n');
  const sig = createHmac('sha256', signingKey(secretAccessKey, dateStamp, region, 's3') as any)
    .update(stringToSign)
    .digest('hex');
  headers.authorization = `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${credentialScope}, SignedHeaders=${signed.join(';')}, Signature=${sig}`;
  const url = `${endpointScheme(endpoint)}://${host}${uri}${q ? `?${q}` : ''}`;
  return { url, headers };
}

function asBytes(body: unknown): Uint8Array {
  if (body == null) return new Uint8Array(0);
  if (body instanceof Uint8Array) return body;
  if (typeof body === 'string') return new TextEncoder().encode(body);
  return new Uint8Array(body as ArrayBuffer);
}

export interface S3Config {
  endpoint: string;
  bucket: string;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  style?: string;
}


/** S3 ListObjectsV2 parser (B2 returns XML). Mirrors the retired Node receiver */
function parseListObjectsV2(xml: string): { keys: string[]; truncated: boolean; token: string | null } {
  const keys: string[] = [];
  const re = /<Key>([^<]+)<\/Key>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml))) keys.push(m[1]);
  const tag = (name: string) => {
    const hit = new RegExp(`<${name}>([^<]+)</${name}>`).exec(xml);
    return hit ? hit[1] : null;
  };
  return {
    keys,
    truncated: /<IsTruncated>\s*true\s*<\/IsTruncated>/i.test(xml),
    token: tag('NextContinuationToken'),
  };
}

export function createS3({
  endpoint,
  bucket,
  region,
  accessKeyId,
  secretAccessKey,
  fetchImpl = fetch,
  style = 'path',
}: S3Config & { fetchImpl?: typeof fetch }) {
  const base = { endpoint, bucket, region, accessKeyId, secretAccessKey, style };

  return {
    bucket,
    region,
    endpoint,
    style,
    presignPut(key: string, expiresSec: number, now?: Date) {
      return presign({ method: 'PUT', ...base, key, expiresSec, now });
    },
    presignGet(key: string, expiresSec: number, now?: Date) {
      return presign({ method: 'GET', ...base, key, expiresSec, now });
    },
    async head(key: string) {
      const { url, headers } = signedRequest({
        method: 'HEAD', ...base, key, now: new Date(),
      });
      const res = await fetchImpl(url, { method: 'HEAD', headers });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error('object head failed');
      const len = res.headers.get('content-length');
      return { exists: true, contentLength: len == null ? null : Number(len) };
    },
    async getObject(key: string) {
      const { url, headers } = signedRequest({
        method: 'GET', ...base, key, now: new Date(),
      });
      const res = await fetchImpl(url, { method: 'GET', headers });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error('object get failed');
      return {
        body: new Uint8Array(await res.arrayBuffer()),
        contentType: res.headers.get('content-type'),
        contentLength: Number(res.headers.get('content-length') || 0),
      };
    },
    async getObjectStream(key: string) {
      const { url, headers } = signedRequest({ method: 'GET', ...base, key, now: new Date() });
      const res = await fetchImpl(url, { method: 'GET', headers, signal: AbortSignal.timeout(120_000) });
      if (res.status === 404) { await res.body?.cancel(); return null; }
      if (!res.ok) { await res.body?.cancel(); throw new Error('object get failed'); }
      return res;
    },
    async copyObject(sourceKey: string, destinationKey: string) {
      const { url, headers } = signedRequest({
        method: 'PUT', ...base, key: destinationKey, now: new Date(),
        extraHeaders: { 'x-amz-copy-source': canonicalUri(bucket, sourceKey, 'path') },
      });
      const res = await fetchImpl(url, { method: 'PUT', headers, signal: AbortSignal.timeout(120_000) });
      const xml = await res.text();
      // S3 can return an Error XML envelope even with HTTP 200.
      if (!res.ok || !/<CopyObjectResult[\s>]/.test(xml) || /<Error[\s>]/.test(xml)) throw new Error('object copy failed');
    },
    async putObject(key: string, body: unknown, { contentType = 'application/octet-stream' }: { contentType?: string } = {}) {
      const buf = asBytes(body);
      const payloadHash = sha256Hex(buf);
      const { url, headers } = signedRequest({
        method: 'PUT',
        ...base,
        key,
        now: new Date(),
        payloadHash,
        extraHeaders: {
          'content-type': contentType,
          'content-length': String(buf.length),
        },
      });
      const res = await fetchImpl(url, { method: 'PUT', headers, body: buf as unknown as BodyInit });
      if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw new Error(`object put failed (${res.status}) ${text.slice(0, 180)}`);
      }
      await res.body?.cancel();
      return { etag: res.headers.get('etag'), bytes: buf.length };
    },

    async deleteObject(key: string) {
      const { url, headers } = signedRequest({
        method: 'DELETE', ...base, key, now: new Date(),
      });
      const res = await fetchImpl(url, { method: 'DELETE', headers });
      await res.body?.cancel();
      if (res.status === 404) return { deleted: true, missing: true };
      if (!res.ok) throw new Error('object delete failed');
      return { deleted: true, missing: false };
    },

    async listPrefix(prefix: string) {
      const keys: string[] = [];
      let token: string | null = null;
      for (let page = 0; page < 1000; page += 1) {
        const query: Record<string, string> = { 'list-type': '2', prefix, 'max-keys': '1000' };
        if (token) query['continuation-token'] = token;
        const { url, headers } = signedRequest({
          method: 'GET', ...base, key: '', now: new Date(), query,
        });
        const res = await fetchImpl(url, { method: 'GET', headers });
        if (!res.ok) throw new Error('prefix list failed');
        const parsed = parseListObjectsV2(await res.text());
        keys.push(...parsed.keys);
        if (!parsed.truncated || !parsed.token) return keys;
        token = parsed.token;
      }
      return keys;
    },
  };
}

export type S3Store = ReturnType<typeof createS3>;
