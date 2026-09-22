// Synthetic local latency characterization; never accepts a remote URL or credential.
import assert from 'node:assert/strict';
import process from 'node:process';
import { gzipSync } from 'node:zlib';
import { createHash } from 'node:crypto';
import { createPushObjects } from '../../supabase/functions/_shared/objects.ts';
import { createPushArchive, createPushIngest } from '../../supabase/functions/_shared/ingest.ts';
import { createPushWalStore } from '../../supabase/functions/_shared/wal.ts';
import { registerDevice } from '../../supabase/functions/_shared/durability.ts';
import { commitArchivedBatch } from '../../supabase/functions/_shared/projections.ts';
import { sha256Hex } from '../../supabase/functions/_shared/s3.ts';
import { startLocalPostgres, USER_A } from '../../supabase/functions/tests/local_postgres.ts';
import { startObjectHttp } from '../../supabase/functions/tests/local_objects.ts';

const output = Deno.env.get('INTAKE_BENCH_OUTPUT');
if (!output?.startsWith('/Volumes/')) throw new Error('external_artifact_directory_required');
const repetitions = Number(Deno.env.get('INTAKE_BENCH_REPETITIONS') ?? 30);
const warmups = Number(Deno.env.get('INTAKE_BENCH_WARMUPS') ?? 3);
assert(Number.isInteger(repetitions) && repetitions >= 1 && repetitions <= 1000);
assert(Number.isInteger(warmups) && warmups >= 0 && warmups <= 10);
const DEVICE = '33333333-3333-4333-8333-333333333333';
const SOURCE = '44444444-4444-4444-8444-444444444444';
const SECOND = 1_790_000_000;
type Counter = { wall: number; cpu: ReturnType<typeof process.cpuUsage>; rss: number };
type Phase = { name: string; wallMS: number; cpuMS: number; rssBefore: number; rssAfter: number };
type Sample = { case: string; repetition: number; warmup: boolean; decodedBytes: number;
  wireBytes: number; recordCount: number; phases: Phase[]; observedRSSPeak: number };
const mark = (): Counter => ({ wall: performance.now(), cpu: process.cpuUsage(), rss: Deno.memoryUsage().rss });
let sample: Sample | undefined;
let observedRSSPeak = Deno.memoryUsage().rss;
const samples: Sample[] = [];
function finish(name: string, before: Counter) {
  const after = mark();
  observedRSSPeak = Math.max(observedRSSPeak, before.rss, after.rss);
  sample?.phases.push({ name, wallMS: after.wall - before.wall,
    cpuMS: (after.cpu.user + after.cpu.system - before.cpu.user - before.cpu.system) / 1000,
    rssBefore: before.rss, rssAfter: after.rss });
}
async function measure<T>(name: string, work: () => Promise<T>): Promise<T> {
  const before = mark();
  try { return await work(); } finally { finish(name, before); }
}
function percentile(values: number[], p: number) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)];
}
function stats(values: number[]) {
  return { samples: values.length, p50: percentile(values, .5), p95: percentile(values, .95),
    p99: percentile(values, .99), max: Math.max(...values) };
}

async function sourceFingerprint() {
  const root = new URL('../../', import.meta.url);
  const files: { path: string; sha256: string }[] = [];
  async function visit(path: string) {
    const entries = [];
    for await (const entry of Deno.readDir(new URL(path, root))) entries.push(entry);
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      const next = path + entry.name;
      if (entry.isDirectory) await visit(next + '/');
      else if (/\.(ts|sql|lock|sh|md)$/.test(entry.name)) {
        files.push({ path: next, sha256: sha256Hex(await Deno.readFile(new URL(next, root))) });
      }
    }
  }
  await visit('supabase/functions/'); await visit('supabase/migrations/'); await visit('Tests/ServerIntakeBench/');
  return { digest: createHash('sha256').update(JSON.stringify(files)).digest('hex'), files };
}

/** Exact NPB1 v2 PPG field layout; synthetic sample bytes carry no physiological meaning. */
function ppgPayload(targetBytes: number) {
  const records = Math.min(2000, Math.max(1, Math.floor(targetBytes / 1024)));
  const blobBytes = Math.floor(((targetBytes - 10) / records - 30) / 2) * 2;
  const bytes = new Uint8Array(10 + records * (30 + blobBytes));
  bytes.set([0x4e, 0x50, 0x42, 0x31, 2, 1]);
  const view = new DataView(bytes.buffer); view.setUint32(6, records, true);
  let cursor = 10, state = 0x13579bdf;
  for (let row = 0; row < records; row++) {
    view.setBigInt64(cursor, BigInt(row + 1), true); cursor += 8;
    view.setBigInt64(cursor, BigInt(SECOND + row), true); cursor += 8;
    bytes[cursor++] = 1; view.setBigInt64(cursor, BigInt(row), true); cursor += 8;
    bytes[cursor++] = 0; view.setUint32(cursor, blobBytes, true); cursor += 4;
    for (let i = 0; i < blobBytes; i += 2) {
      state ^= state << 13; state ^= state >>> 17; state ^= state << 5;
      view.setInt16(cursor, state & 0x3ff, true); cursor += 2;
    }
  }
  assert.equal(cursor, bytes.length);
  return { bytes, records };
}

const fingerprint = await sourceFingerprint();
const db = await startLocalPostgres({ auxiliaryIdentity: true, statementTimeoutMs: 120000 });
let closeBucket: (() => Promise<void>) | undefined;
try {
const bucket = startObjectHttp({ chunkBytes: 64 * 1024 });
closeBucket = () => bucket.close();
let verification: Counter | undefined;
const rest = { ...db.rest, rpc: async (name: string, args: Record<string, unknown>) => {
  if (verification && ['noop_commit_copy_receipt', 'noop_commit_object_receipt', 'noop_commit_aux_object_receipt'].includes(name)) {
    finish('verify_stream_decode_hash', verification); verification = undefined;
  }
  return await measure('db.' + name, () => db.rest.rpc(name, args));
} };
const raw = { ...bucket.raw,
  head: (key: string) => measure('storage.head', () => bucket.raw.head(key)),
  copyObject: (from: string, to: string) => measure('storage.copy', () => bucket.raw.copyObject(from, to)),
  putObject: (...args: Parameters<typeof bucket.raw.putObject>) => measure('storage.put', () => bucket.raw.putObject(...args)),
  getObjectStream: async (key: string) => {
    verification = mark();
    return await measure('storage.get_headers', () => bucket.raw.getObjectStream(key));
  },
};
const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
const objects = createPushObjects({ cfg, rest, raw });
const archive = createPushArchive({ cfg, rest, raw });
const ingest = createPushIngest({ walStore: createPushWalStore({ rest })!,
  archiveObject: (args) => archive.archiveObject(args), ensureDevice: (row) => registerDevice(rest, row),
  commitProjection: (receipt, body) => measure('projection.total', () => commitArchivedBatch(rest, receipt, body)),
  quotaConfig: { maxBatches: 100000, maxBytes: 1024 * 1024 * 1024, windowSec: 3600 } });
const rssTimer = setInterval(() => { observedRSSPeak = Math.max(observedRSSPeak, Deno.memoryUsage().rss); }, 20);
const runStarted = mark();
const payloads: { case: string; decodedBytes: number; wireBytes: number; recordCount: number; compression: string }[] = [];
let failure: string | null = null;
try {
  for (const target of [64 * 1024, 1024 * 1024, 4 * 1024 * 1024]) {
    const packed = ppgPayload(target);
    const wire = new Uint8Array(gzipSync(packed.bytes, { level: 3 }));
    const name = 'object_gzip_' + target;
    payloads.push({ case: name, decodedBytes: packed.bytes.length, wireBytes: wire.length,
      recordCount: packed.records, compression: 'gzip_level_3_synthetic_fixture' });
    for (let repetition = -warmups; repetition < repetitions; repetition++) {
      sample = { case: name, repetition, warmup: repetition < 0, decodedBytes: packed.bytes.length,
        wireBytes: wire.length, recordCount: packed.records, phases: [], observedRSSPeak: 0 };
      observedRSSPeak = Deno.memoryUsage().rss;
      const manifest = { type: 'binaryObject', protocolVersion: '1.3', stream: 'ppgWaveformSample',
        deviceId: DEVICE, objectId: crypto.randomUUID(), batchId: crypto.randomUUID(), sourceId: SOURCE,
        startTs: SECOND, endTs: SECOND + packed.records + 1, sampleCount: packed.records,
        uncompressedBytes: packed.bytes.length, compressedBytes: wire.length,
        contentSha256: sha256Hex(packed.bytes), contentEncoding: 'gzip' };
      await measure('object.end_to_end', async () => {
        const intent = await measure('object.intent', () => objects.createIntent({ userId: USER_A, manifest }));
        await measure('client.loopback_put', async () => {
          const response = await fetch(intent.uploadUrl!, { method: 'PUT', body: wire, headers: intent.requiredHeaders });
          await response.body?.cancel(); assert.equal(response.status, 200);
        });
        const ack = await measure('object.complete', () => objects.completeObject({ userId: USER_A, objectId: manifest.objectId }));
        assert.equal(ack.durabilityReceipt.state, 'verified_indexed');
        assert.equal(ack.durabilityReceipt.contentSha256, manifest.contentSha256);
        assert.equal(ack.durabilityReceipt.wireSha256, sha256Hex(wire));
      });
      const phasesBeforeReplay = sample.phases.length;
      await measure('object.duplicate_complete', () => objects.completeObject({ userId: USER_A, objectId: manifest.objectId }));
      for (const phase of sample.phases.slice(phasesBeforeReplay)) {
        if (phase.name !== 'object.duplicate_complete') phase.name = 'duplicate.' + phase.name;
      }
      sample.observedRSSPeak = observedRSSPeak; samples.push(sample);
      // Disposable RAM fixture eviction is outside the measured window, never product retention.
      bucket.objects.clear(); bucket.versions.clear(); sample = undefined;
    }
    console.log(JSON.stringify({ case: name, measuredRepetitions: repetitions, warmups }));
  }
  for (const count of [50, 500, 2000]) {
    const caseRepetitions = repetitions;
    const caseWarmups = warmups;
    const name = 'inline_rows_' + count;
    for (let repetition = -caseWarmups; repetition < caseRepetitions; repetition++) {
      const start = SECOND + count * 10000 + (repetition + caseWarmups) * 3000;
      const header = { type: 'batch', protocolVersion: '1.3', stream: 'hrSample', deviceId: DEVICE,
        sourceId: SOURCE, batchId: crypto.randomUUID(), delivery: 'append', recordCount: count };
      const body = new TextEncoder().encode([header, ...Array.from({ length: count }, (_, n) =>
        ({ type: 'record', key: { ts: start + n }, data: { bpm: 60 + n % 20 } }))].map((value) => JSON.stringify(value)).join('\n') + '\n');
      sample = { case: name, repetition, warmup: repetition < 0, decodedBytes: body.length,
        wireBytes: 0, recordCount: count, phases: [], observedRSSPeak: 0 };
      observedRSSPeak = Deno.memoryUsage().rss;
      const ack = await measure('inline.end_to_end', () => ingest.acceptBatch({ userId: USER_A, decodedBody: body }));
      assert.equal(ack.durabilityReceipt.state, 'verified_indexed');
      sample.wireBytes = ack.durabilityReceipt.compressedBytes;
      assert.equal(ack.durabilityReceipt.contentSha256, sha256Hex(body));
      sample.observedRSSPeak = observedRSSPeak; samples.push(sample);
      bucket.objects.clear(); bucket.versions.clear(); sample = undefined;
    }
    const first = samples.find((value) => value.case === name)!;
    payloads.push({ case: name, decodedBytes: first.decodedBytes, wireBytes: first.wireBytes,
      recordCount: count, compression: 'production_inline_gzip_default' });
    console.log(JSON.stringify({ case: name, measuredRepetitions: caseRepetitions, warmups: caseWarmups }));
  }
} catch (error) { failure = error instanceof Error ? error.name : 'unknown'; throw error; }
finally {
  clearInterval(rssTimer);
  const finalFingerprint = await sourceFingerprint();
  const grouped = new Map<string, Phase[]>();
  for (const value of samples.filter((value) => !value.warmup)) {
    for (const phase of value.phases) {
      const key = value.case + '/' + phase.name;
      grouped.set(key, [...grouped.get(key) ?? [], phase]);
    }
  }
  const summary = Object.fromEntries([...grouped].map(([name, phases]) => [name, {
    wallMS: stats(phases.map((value) => value.wallMS)), cpuMS: stats(phases.map((value) => value.cpuMS)),
    observedRSS: stats(phases.map((value) => Math.max(value.rssBefore, value.rssAfter))),
  }]));
  const metrics = (await db.rest.select('noop_copy_intake_metrics'))[0] ?? null;
  const projectionMetrics = (await db.rest.select('noop_projection_metrics'))[0] ?? null;
  const manifest = {
    schemaVersion: 1, status: failure == null && fingerprint.digest === finalFingerprint.digest ? 'PASS_LOCAL' : 'INCOMPLETE',
    failure, sourceSHA: Deno.env.get('INTAKE_BENCH_SOURCE_SHA'), sourceFingerprint: fingerprint,
    sourceFingerprintStable: fingerprint.digest === finalFingerprint.digest, sourceDirty: Deno.env.get('INTAKE_BENCH_SOURCE_DIRTY'),
    schemaOptions: { auxiliaryIdentity: true, includesScalarProjection060000: true, statementTimeoutMS: 120000 },
    platform: Deno.build, runtime: Deno.version, startedAt: new Date(Date.now() - (performance.now() - runStarted.wall)).toISOString(),
    servicesArtifactDirectory: Deno.env.get('EDGE_TEST_ARTIFACTS'),
    repetitions, warmups, measuredSamples: samples.filter((value) => !value.warmup).length,
    payloads, summary, samples, copyIntakeMetrics: metrics, projectionMetrics,
    boundaries: {
      real: ['production service functions', 'signed loopback object HTTP', 'streamed gzip decode and SHA256',
        'PostgREST HTTP', 'PostgreSQL migrations, receipt/index transaction, scalar projection'],
      simulated: ['RAM object provider with64KiB response chunks', 'synthetic NPB1 bytes and scalar rows',
        'direct service invocation replaces deployed HTTP handler/auth/gateway'],
      cpu: 'Deno process user+system time; includes HTTP fixture, excludes PostgreSQL/PostgREST child CPU',
      rss: 'Deno process sampled at phase boundaries and20ms; includes RAM fixture; not exact peak or iOS RSS',
      phaseTimes: 'Nested inclusive phases must not be summed. verify phase starts at GET request and ends before receipt RPC.',
      orphanBytes: 'Declared ledger estimates, not physical bucket census. No aged sweeper fixture used.',
      hostContention: Deno.env.get('INTAKE_BENCH_HOST_CONTENTION') ?? 'NOT_MEASURED',
      phoneRadioEnergyThermal: 'NOT_MEASURED', productionB2LatencyPermissions: 'NOT_MEASURED',
      productionSchedulingFleetTail: 'NOT_MEASURED', physiologicalPayloadRepresentativeness: 'NOT_MEASURED',
    },
  };
  await Deno.writeTextFile(output + '/intake-benchmark.json', JSON.stringify(manifest, null, 2));
  assert.equal(finalFingerprint.digest, fingerprint.digest, 'bench source changed during run');
}
} finally {
  try { await closeBucket?.(); } finally { await db.close(); }
}
