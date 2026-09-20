#!/usr/bin/env node
// Phase 5 — PUT a tiny derived fixture with B2 credentials (same bucket as raw lane).
// Usage: source /opt/frwhoop/b2.env && node b2-derived-smoke.mjs
import { createHash, createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

function loadEnv(path) {
  try {
    for (const line of readFileSync(path, 'utf8').split('\n')) {
      const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
      if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
    }
  } catch { /* optional */ }
}

loadEnv('/opt/frwhoop/b2.env');

const keyId = process.env.B2_KEY_ID || process.env.KEY_ID;
const secret = process.env.B2_APPLICATION_KEY || process.env.APPLICATION_KEY;
const bucket = process.env.B2_BUCKET || process.env.B2_BUCKET_NAME || process.env.BUCKET_NAME || 'FRWHOOP';
const endpoint = (process.env.B2_S3_ENDPOINT || 's3.us-west-004.backblazeb2.com').replace(/^https?:\/\//, '');
const region = process.env.B2_REGION || 'us-west-004';
const userId = process.env.SMOKE_USER_ID || '00000000-0000-4000-8000-00000000f099';
const day = process.env.SMOKE_DAY || '2026-01-01';

if (!keyId || !secret) {
  console.error('B2_KEY_ID and B2_APPLICATION_KEY required');
  process.exit(2);
}

const objectKey = `v3/derived/users/${userId}/days/${day}/frwhoop-server-1.json.zst`;
const json = JSON.stringify({
  algorithm_version: 'frwhoop-server-1',
  user_id: userId,
  device_id: null,
  day,
  computed_at: new Date().toISOString(),
  daily: { day },
  nights: [],
});
const zstd = spawnSync('zstd', ['-q', '-c'], { input: Buffer.from(json, 'utf8') });
if (zstd.status !== 0) {
  console.error('zstd CLI required for derived smoke');
  process.exit(2);
}
const body = zstd.stdout;
const sha256 = createHash('sha256').update(body).digest('hex');

function sha256Hex(data) {
  return createHash('sha256').update(data).digest('hex');
}
function hmac(key, data) {
  return createHmac('sha256', key).update(data).digest();
}
function signingKey(sec, dateStamp) {
  const kDate = hmac(`AWS4${sec}`, dateStamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, 's3');
  return hmac(kService, 'aws4_request');
}
function amzDate(d = new Date()) {
  return d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

const now = new Date();
const date = amzDate(now);
const dateStamp = date.slice(0, 8);
const host = endpoint;
const uri = `/${encodeURIComponent(bucket)}/${objectKey.split('/').map(encodeURIComponent).join('/')}`;
const payloadHash = sha256Hex(body);
const headers = {
  host,
  'x-amz-content-sha256': payloadHash,
  'x-amz-date': date,
  'content-type': 'application/json',
  'content-length': String(body.length),
};
const signed = Object.keys(headers).sort();
const canonicalHeaders = signed.map((h) => `${h}:${headers[h]}\n`).join('');
const canonicalRequest = ['PUT', uri, '', canonicalHeaders, signed.join(';'), payloadHash].join('\n');
const credentialScope = `${dateStamp}/${region}/s3/aws4_request`;
const stringToSign = ['AWS4-HMAC-SHA256', date, credentialScope, sha256Hex(canonicalRequest)].join('\n');
const sig = createHmac('sha256', signingKey(secret, dateStamp)).update(stringToSign).digest('hex');
headers.authorization = `AWS4-HMAC-SHA256 Credential=${keyId}/${credentialScope}, SignedHeaders=${signed.join(';')}, Signature=${sig}`;

const putUrl = `https://${host}${uri}`;
const putRes = await fetch(putUrl, { method: 'PUT', headers, body });
if (!putRes.ok) {
  console.error('PUT failed', putRes.status, await putRes.text());
  process.exit(1);
}
const headRes = await fetch(putUrl, { method: 'HEAD', headers: { host, authorization: headers.authorization, 'x-amz-date': date, 'x-amz-content-sha256': 'UNSIGNED-PAYLOAD' } });
console.log('derived smoke ok', { objectKey, bytes: body.length, sha256: sha256.slice(0, 12), head: headRes.status });
