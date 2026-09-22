#!/usr/bin/env node
// Phase 2 — exercise the raw-lane presign path against live VPS + B2.
// Usage: BASE_URL=https://host/functions/v1/push AUTH=noop_... node infra/vps/scripts/b2-presign-smoke.mjs
import { createHash, randomUUID } from 'node:crypto';
import { gzipSync } from 'node:zlib';

const BASE = String(process.env.BASE_URL || '').replace(/\/$/, '');
const AUTH = process.env.AUTH || '';
const ANON = process.env.ANON_KEY || process.env.SUPABASE_ANON_KEY || '';
if (!BASE || !AUTH) {
  console.error('BASE_URL and AUTH required');
  process.exit(2);
}

const objectId = randomUUID();
const batchId = randomUUID();
const sourceId = randomUUID();
const deviceId = 'phase2-smoke-strap';
const startTs = 1_780_000_000;
const endTs = startTs + 10;
const payload = Buffer.alloc(10 * 64, 0x42);
const wire = gzipSync(payload);
const manifest = {
  type: 'binaryObject',
  protocolVersion: '1.2',
  batchId,
  sourceId,
  deviceId,
  stream: 'ppgWaveformSample',
  objectId,
  startTs,
  endTs,
  sampleCount: 10,
  uncompressedBytes: payload.length,
  compressedBytes: wire.length,
  contentSha256: createHash('sha256').update(payload).digest('hex'),
  contentEncoding: 'gzip',
};

const headers = {
  authorization: `Bearer ${AUTH}`,
  accept: 'application/json',
  'content-type': 'application/json',
  ...(ANON ? { apikey: ANON } : {}),
};

const intentRes = await fetch(`${BASE}/objects`, { method: 'POST', headers, body: JSON.stringify(manifest) });
const intent = await intentRes.json();
if (!intentRes.ok) {
  console.error('intent failed', intentRes.status, intent);
  process.exit(1);
}
console.log('intent ok', { objectKey: intent.objectKey, uploadUrl: Boolean(intent.uploadUrl) });

const putRes = await fetch(intent.uploadUrl, {
  method: 'PUT',
  headers: intent.requiredHeaders || { 'content-type': 'application/octet-stream' },
  body: wire,
});
if (!putRes.ok) {
  console.error('PUT failed', putRes.status, await putRes.text());
  process.exit(1);
}
console.log('PUT ok', putRes.status);

const completeRes = await fetch(`${BASE}/objects/${objectId}/complete`, {
  method: 'POST',
  headers: { ...headers, 'content-type': 'application/json' },
  body: '{}',
});
const ack = await completeRes.json();
if (!completeRes.ok) {
  console.error('complete failed', completeRes.status, ack);
  process.exit(1);
}
console.log('complete ok', ack);
console.log('B2 presign smoke PASS');
