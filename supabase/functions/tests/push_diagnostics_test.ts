import assert from 'node:assert/strict';
import { createPushIngest } from '../_shared/ingest.ts';
import { createSupabaseRest } from '../_shared/rest.ts';
import { PushProtocolError } from '../_shared/registry.ts';
import { inlineRequestProtocol, ingestStep, ingestProtocolErrorResponse, PushIngestFailure, unexpectedIngestDiagnostic } from '../_shared/pushDiagnostics.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const HR_BATCH = '22222222-2222-4222-8222-222222222222';
const RR_BATCH = '33333333-3333-4333-8333-333333333333';

function batch(stream: 'hrSample' | 'rrPacketProvenance') {
  const record = stream === 'hrSample'
    ? { type: 'record', key: { ts: 1700000000 }, data: { bpm: 60 } }
    : { type: 'record', key: { packetId: 'a'.repeat(64) }, data: {
      ts: 1700000000, sensorTs: 1700000000, recordIndex: 0, rawHex: 'aa'.repeat(28),
      srcChannel: 5, schemaVersion: 1, decoderVersion: 'whoop5-v18-original-words-v1',
      clockVersion: 'sensor-second-unmapped', timestampPrecisionSeconds: 1, clockOffsetSeconds: 0, declaredCount: 3,
    } };
  return new TextEncoder().encode(JSON.stringify({
    type: 'batch', protocolVersion: stream === 'hrSample' ? '1.0' : '1.1',
    batchId: stream === 'hrSample' ? HR_BATCH : RR_BATCH, sourceId: '44444444-4444-4444-8444-444444444444',
    deviceId: 'private-strap', stream, delivery: 'append', recordCount: 1,
    startCursor: null, endCursor: { rowId: 1, keySha256: 'f'.repeat(64) },
  }) + '\n' + JSON.stringify(record) + '\n');
}

function wal() {
  const acks = new Map<string, any>();
  const pending = new Set<string>();
  return {
    acks, pending,
    quotaConfig: { maxBatches: 10000, maxBytes: 1000000, windowSec: 3600 },
    async consumeQuota() {},
    async appendWal(_user: string, entry: any) { pending.add(entry.batchId); },
    async trimWal(_user: string, id: string) { pending.delete(id); },
    async getAck(_user: string, id: string) { return acks.get(id) ?? null; },
    async saveAck(_user: string, id: string, ack: unknown, bodySha256: string) { acks.set(id, { ack, bodySha256 }); },
  };
}

Deno.test('HR success and packet projection failure are distinguishable; identical retry alone advances packet ACK', async () => {
  const store = wal();
  let failPacket = true;
  const projections = new Map<string, unknown[]>();
  const ingest = createPushIngest({ walStore: store, archiveObject: async () => ({ ready: true }),
    upsertRows: async (table, rows) => {
      if (table === 'noop_rr_packet_provenance' && failPacket) {
        throw new Error(`SQL failed user=${USER} rawHex=private-waveform token=secret`);
      }
      projections.set(table, rows);
    },
  });
  await ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: batch('hrSample') });
  assert.ok(store.acks.has(HR_BATCH));
  let failure: unknown;
  try { await ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: batch('rrPacketProvenance') }); }
  catch (error) { failure = error; }
  assert.ok(failure instanceof PushIngestFailure);
  const diagnostic = unexpectedIngestDiagnostic(failure);
  assert.equal(diagnostic.stream, 'rrPacketProvenance');
  assert.equal(diagnostic.stage, 'projection');
  assert.match(diagnostic.correlationId, /^[a-f0-9-]{36}$/);
  assert.deepEqual(Object.keys(diagnostic).sort(), ['code', 'correlationId', 'protocolVersion', 'stage', 'stream', 'type']);
  for (const secret of [USER, 'private-strap', 'private-waveform', 'SQL', 'token', 'secret']) {
    assert.ok(!JSON.stringify(diagnostic).includes(secret));
  }
  assert.ok(!store.acks.has(RR_BATCH));
  assert.ok(store.pending.has(RR_BATCH));
  assert.equal(projections.size, 1);
  failPacket = false;
  await ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: batch('rrPacketProvenance') });
  assert.ok(store.acks.has(RR_BATCH));
  assert.ok(!store.pending.has(RR_BATCH));
  assert.equal(projections.get('noop_rr_packet_provenance')?.length, 1);
});

Deno.test('large append batches bound projection statements and acknowledge only after every chunk survives retry', async () => {
  const count = 5000;
  const header = JSON.parse(new TextDecoder().decode(batch('hrSample')).split('\n')[0]);
  header.recordCount = count;
  header.endCursor.rowId = count;
  const body = new TextEncoder().encode([JSON.stringify(header), ...Array.from({ length: count }, (_, index) =>
    JSON.stringify({ type: 'record', key: { ts: 1700000000 + index }, data: { bpm: 60 + index % 20 } }))].join('\n') + '\n');
  const store = wal();
  const stored = new Map<number, any>();
  let fail = true;
  let writes = 0;
  let largestStatement = 0;
  const ingest = createPushIngest({ walStore: store, archiveObject: async () => ({ ready: true }),
    upsertRows: async (_table, rows) => {
      largestStatement = Math.max(largestStatement, rows.length);
      assert.ok(!store.acks.has(HR_BATCH), 'ACK must follow every projection statement');
      if (fail && writes++ === 2) throw new Error('synthetic_mid_batch_failure');
      for (const row of rows as any[]) stored.set(row.ts, row);
    },
  });
  await assert.rejects(() => ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: body }),
    (error: unknown) => error instanceof PushIngestFailure && error.stage === 'projection');
  assert.ok(stored.size > 0 && stored.size < count);
  assert.ok(!store.acks.has(HR_BATCH));
  assert.ok(store.pending.has(HR_BATCH));
  fail = false;
  await ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: body });
  assert.equal(stored.size, count);
  assert.ok(largestStatement <= 250);
  assert.equal(store.acks.get(HR_BATCH).ack.acceptedRows, count);
  assert.deepEqual(store.acks.get(HR_BATCH).ack.endCursor, header.endCursor);
  assert.ok(!store.pending.has(HR_BATCH));
  for (let index = 0; index < count; index++) assert.equal(stored.get(1700000000 + index)?.bpm, 60 + index % 20);
  const beforeReplay = [...stored.entries()];
  await ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: body });
  assert.deepEqual([...stored.entries()], beforeReplay);
});

Deno.test('duplicate projected keys across a chunk boundary reject the whole batch before durable side effects', async () => {
  // Wire representations differ, but PostgreSQL receives the same mapped bigint key.
  for (const [duplicateTimestamp, duplicateBpm] of [
    [1700000000, 99], ['1700000000', 99], ['01700000000', 99], ['1.7e9', 99], [1700000000, 60],
  ]) {
    const header = JSON.parse(new TextDecoder().decode(batch('hrSample')).split('\n')[0]);
    header.recordCount = 251;
    header.endCursor.rowId = 251;
    const records = Array.from({ length: 250 }, (_, index) => ({ type: 'record',
      key: { ts: 1700000000 + index }, data: { bpm: 60 } }));
    const body = new TextEncoder().encode([JSON.stringify(header), ...records.map((record) => JSON.stringify(record)),
      JSON.stringify({ type: 'record', key: { ts: duplicateTimestamp }, data: { bpm: duplicateBpm } })].join('\n') + '\n');
    const store = wal();
    let quota = 0, archives = 0, devices = 0, projections = 0;
    store.consumeQuota = async () => { quota++; };
    const ingest = createPushIngest({ walStore: store,
      archiveObject: async () => { archives++; return { ready: true }; },
      ensureDevice: async () => { devices++; },
      upsertRows: async () => { projections++; },
    });
    await assert.rejects(() => ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: body }),
      (error: unknown) => error instanceof PushProtocolError && error.status === 422 && error.code === 'duplicate_record_key');
    assert.equal(store.acks.size, 0);
    assert.equal(store.pending.size, 0);
    assert.deepEqual({ quota, archives, devices, projections }, { quota: 0, archives: 0, devices: 0, projections: 0 });
  }
});

Deno.test('RR composite identities preserve equal intervals with distinct sequence and reject numeric aliases', async () => {
  const header = JSON.parse(new TextDecoder().decode(batch('hrSample')).split('\n')[0]);
  header.stream = 'rrInterval';
  header.recordCount = 2;
  header.endCursor.rowId = 2;
  const row = (seq: number | string) => ({ type: 'record', key: { ts: 1700000000, rrMs: 1000, seq }, data: {} });
  const body = (seq: number | string) => new TextEncoder().encode(
    [JSON.stringify(header), JSON.stringify(row(0)), JSON.stringify(row(seq))].join('\n') + '\n');
  const accepted: any[] = [];
  const store = wal();
  const ingest = createPushIngest({ walStore: store, archiveObject: async () => ({ ready: true }),
    upsertRows: async (_table, rows) => { accepted.push(...rows); },
  });
  const ack = await ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: body(1) });
  assert.equal(ack.acceptedRows, 2);
  assert.deepEqual(accepted.map((record) => record.seq), [0, 1]);
  const duplicate = createPushIngest({ walStore: wal(), archiveObject: async () => { throw new Error('archive must not run'); },
    upsertRows: async () => { throw new Error('projection must not run'); },
  });
  for (const seq of [0, '0', '-0', '0e0']) {
    await assert.rejects(() => duplicate.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: body(seq) }),
      (error: unknown) => error instanceof PushProtocolError && error.code === 'duplicate_record_key');
  }
});

Deno.test('invalid append records and inexact integer keys cannot be discarded while ACK counts them', async () => {
  const base = JSON.parse(new TextDecoder().decode(batch('hrSample')).split('\n')[0]);
  for (const record of [
    { type: 'record', key: { ts: 1700000000 }, data: { bpm: 'not-a-number' } },
    { type: 'record', key: { ts: 1700000000.5 }, data: { bpm: 60 } },
    { type: 'record', key: { ts: 9007199254740992 }, data: { bpm: 60 } },
  ]) {
    const store = wal();
    const ingest = createPushIngest({ walStore: store,
      archiveObject: async () => { throw new Error('archive must not run'); },
      upsertRows: async () => { throw new Error('projection must not run'); },
    });
    await assert.rejects(() => ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet',
      decodedBody: new TextEncoder().encode(JSON.stringify(base) + '\n' + JSON.stringify(record) + '\n') }),
    (error: unknown) => error instanceof PushProtocolError && error.status === 422 &&
      ['invalid_record', 'invalid_record_key'].includes(error.code));
    assert.equal(store.acks.size, 0);
    assert.equal(store.pending.size, 0);
  }
});

Deno.test('nested archive stages and existing protocol errors survive diagnostic wrapping', async () => {
  await assert.rejects(() => ingestStep('archive', 'rrInterval', () => ingestStep('archive_write', 'rrInterval',
    () => Promise.reject(new Error('private-object-key')))),
  (error: unknown) => error instanceof PushIngestFailure && error.stage === 'archive_write');
  const protocolError = new PushProtocolError('archive_not_ready', 503);
  await assert.rejects(() => ingestStep('archive', 'rrInterval', () => Promise.reject(protocolError)),
    (error: unknown) => error === protocolError);
  const diagnostic = unexpectedIngestDiagnostic(new Error('Bearer secret'));
  assert.ok(!('stream' in diagnostic));
  assert.ok(!('stage' in diagnostic));
  assert.notEqual(diagnostic.correlationId, unexpectedIngestDiagnostic(null).correlationId);
});

Deno.test('exact scoring gate contention returns retryable503 without ACK; retry succeeds', async () => {
  const store = wal();
  let busy = true;
  const rest = createSupabaseRest({ cfg: { supabaseUrl: 'https://local.invalid', supabaseServiceRoleKey: 'test' },
    fetchImpl: async () => busy
      ? new Response(JSON.stringify({ code: '55P03', message: 'scoring_input_gate_busy' }), { status: 500 })
      : new Response('[]', { status: 200 }),
  });
  const ingest = createPushIngest({ walStore: store, archiveObject: async () => ({ ready: true }),
    upsertRows: (table, rows, opts) => rest.upsert(table, rows, opts),
  });
  let failure: unknown;
  try { await ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: batch('rrPacketProvenance') }); }
  catch (error) { failure = error; }
  assert.ok(failure instanceof PushProtocolError);
  const response = ingestProtocolErrorResponse(failure);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('retry-after'), '2');
  assert.equal((await response.json()).code, 'scoring_input_gate_busy');
  assert.ok(!store.acks.has(RR_BATCH));
  assert.ok(store.pending.has(RR_BATCH));
  busy = false;
  await ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: batch('rrPacketProvenance') });
  assert.ok(store.acks.has(RR_BATCH));
});

Deno.test('unrelated SQL lock errors do not become scoring gate responses', async () => {
  const rest = createSupabaseRest({ cfg: { supabaseUrl: 'https://local.invalid', supabaseServiceRoleKey: 'test' },
    fetchImpl: async () => new Response(JSON.stringify({ code: '55P03', message: 'private lock detail' }), { status: 500 }),
  });
  await assert.rejects(() => ingestStep('projection', 'rrInterval', () => rest.upsert('noop_rr_intervals', [{}])),
    (error: unknown) => error instanceof PushIngestFailure && error.stage === 'projection');
});

Deno.test('failed1.0 HR and1.1 packet requests retain their exact validated diagnostic version', async () => {
  const ingest = createPushIngest({ walStore: wal(), archiveObject: async () => ({ ready: true }),
    upsertRows: async () => { throw new Error('private SQL detail'); },
  });
  for (const stream of ['hrSample', 'rrPacketProvenance'] as const) {
    const body = batch(stream);
    const version = inlineRequestProtocol(body);
    assert.equal(version, stream === 'hrSample' ? '1.0' : '1.1');
    await assert.rejects(() => ingest.acceptBatch({ userId: USER, sourceId: null, tokenId: null, authMode: 'legacy_fleet', decodedBody: body }), (error: unknown) => {
      const diagnostic = unexpectedIngestDiagnostic(error, version);
      assert.equal(diagnostic.protocolVersion, version);
      assert.equal(diagnostic.stream, stream);
      assert.equal(diagnostic.stage, 'projection');
      return true;
    });
    const response = ingestProtocolErrorResponse(new PushProtocolError('scoring_input_gate_busy', 503), version);
    assert.equal((await response.json()).protocolVersion, version);
  }
  for (const header of [
    { type: 'batch', protocolVersion: 'private-data' }, { type: 'record', protocolVersion: '1.0' },
    { type: 'batch', protocolVersion: '1.2' },
  ]) assert.equal(inlineRequestProtocol(new TextEncoder().encode(JSON.stringify(header))), '1.1');
  assert.equal(inlineRequestProtocol(new Uint8Array(65537)), '1.1');
  assert.equal(inlineRequestProtocol(new TextEncoder().encode('malformed')), '1.1');
});
