// The Postgres-backed replacement staging is the one piece of the port with NEW logic (the Node
// original stages in process memory). Pin the state machine: part conflicts, window conflicts,
// supersede, completion order, and clear.
import assert from 'node:assert/strict';
import { createPushReplacementStaging } from '../_shared/staging.ts';
import { createPushIngest } from '../_shared/ingest.ts';
import { PushProtocolError } from '../_shared/registry.ts';

const USER = '11111111-1111-4111-8111-111111111111';

/** In-memory stand-in for the noop_push_staging_parts table, behind the rest interface. */
function makeStagingRest() {
  const rows = new Map<string, any>();
  const keyOf = (r: any) => `${r.user_id}${r.scope}${r.replacement_id}${r.part}`;
  return {
    configured: true,
    rows,
    async select(_table: string, query = '') {
      const userId = /user_id=eq\.([^&]+)/.exec(query)?.[1];
      const scope = decodeURIComponent(/scope=eq\.([^&]+)/.exec(query)?.[1] || '');
      return [...rows.values()]
        .filter((r) => r.user_id === userId && r.scope === scope)
        .sort((a, b) => a.part - b.part)
        .map((r) => ({ ...r }));
    },
    async upsert(_table: string, row: any) {
      const list = Array.isArray(row) ? row : [row];
      for (const r of list) if (!rows.has(keyOf(r))) rows.set(keyOf(r), { ...r });
      return list;
    },
    async delete(_table: string, query = '') {
      const userId = /user_id=eq\.([^&]+)/.exec(query)?.[1];
      const scope = decodeURIComponent(/scope=eq\.([^&]+)/.exec(query)?.[1] || '');
      const replacementId = /replacement_id=eq\.([^&]+)/.exec(query)?.[1];
      for (const [k, r] of [...rows.entries()]) {
        if (r.user_id !== userId || r.scope !== scope) continue;
        if (replacementId && r.replacement_id !== decodeURIComponent(replacementId)) continue;
        rows.delete(k);
      }
      return [];
    },
  };
}

function headerFor(over: Record<string, unknown> = {}) {
  return {
    protocolVersion: '1.0',
    stream: 'dailyMetric',
    deviceId: 'strap-1',
    sourceId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    batchId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    window: {
      replacementId: 'r1',
      selector: 'day',
      startInclusive: '2026-09-01',
      endExclusive: '2026-09-02',
      part: 1,
      parts: 2,
    },
    ...over,
  };
}

const SHA_A = 'a'.repeat(64);
const SHA_B = 'b'.repeat(64);
const SHA_C = 'c'.repeat(64);

Deno.test('staging: parts accumulate and the completing part carries every record', async () => {
  const rest = makeStagingRest();
  const staging = createPushReplacementStaging({ rest: rest as any });

  const first = await staging.stagePart({
    userId: USER,
    header: headerFor(),
    records: [{ key: { day: '2026-09-01' }, data: { steps: 100 } }],
    bodySha256: SHA_A,
  });
  assert.equal(first.complete, false);
  assert.equal(first.isCompletingPart, false);
  assert.deepEqual(first.records, []);

  const second = await staging.stagePart({
    userId: USER,
    header: headerFor({ batchId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', window: { ...headerFor().window, part: 2 } }),
    records: [{ key: { day: '2026-09-01' }, data: { steps: 200 } }],
    bodySha256: SHA_B,
  });
  assert.equal(second.complete, true);
  assert.equal(second.isCompletingPart, true);
  assert.equal(second.records.length, 2, 'the completing part must carry parts 1 and 2 in order');
  assert.equal(second.records[0].data.steps, 100);
  assert.equal(second.records[1].data.steps, 200);

  await staging.clearGeneration({ userId: USER, header: headerFor() });
  assert.equal(rest.rows.size, 0, 'clearing must drop every staged part');
});

Deno.test('staging: a re-delivered part with the same bytes is idempotent', async () => {
  const rest = makeStagingRest();
  const staging = createPushReplacementStaging({ rest: rest as any });
  const header = headerFor();
  await staging.stagePart({ userId: USER, header, records: [{ key: { day: '2026-09-01' } }], bodySha256: SHA_A });
  const again = await staging.stagePart({ userId: USER, header, records: [{ key: { day: '2026-09-01' } }], bodySha256: SHA_A });
  assert.equal(again.alreadyStaged, true);
  assert.equal(rest.rows.size, 1);
});

Deno.test('staging: a complete generation retries projection and can be cleared', async () => {
  const rest = makeStagingRest();
  const staging = createPushReplacementStaging({ rest: rest as any });
  const first = headerFor();
  const second = headerFor({
    batchId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    window: { ...headerFor().window, part: 2 },
  });
  await staging.stagePart({ userId: USER, header: first, records: [{ key: { day: '2026-09-01' } }], bodySha256: SHA_A });
  await staging.stagePart({ userId: USER, header: second, records: [{ key: { day: '2026-09-01' } }], bodySha256: SHA_B });

  // Models projection success followed by a transient clear/ACK failure and delivery retry.
  const retry = await staging.stagePart({
    userId: USER,
    header: second,
    records: [{ key: { day: '2026-09-01' } }],
    bodySha256: SHA_B,
  });
  assert.equal(retry.complete, true);
  assert.equal(retry.isCompletingPart, true);
  assert.equal(retry.records.length, 2);
  await staging.clearGeneration({ userId: USER, header: second });

  const next = headerFor({ window: { ...headerFor().window, replacementId: 'r2' } });
  const accepted = await staging.stagePart({ userId: USER, header: next, records: [], bodySha256: SHA_A });
  assert.equal(accepted.complete, false);
  assert.equal([...rest.rows.values()][0].replacement_id, 'r2');
});

Deno.test('staging: a newer generation receives complete prior records for recovery first', async () => {
  const rest = makeStagingRest();
  const staging = createPushReplacementStaging({ rest: rest as any });
  const first = headerFor();
  const second = headerFor({
    batchId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    window: { ...headerFor().window, part: 2 },
  });
  await staging.stagePart({ userId: USER, header: first, records: [{ data: { steps: 100 } }], bodySha256: SHA_A });
  await staging.stagePart({ userId: USER, header: second, records: [{ data: { steps: 200 } }], bodySha256: SHA_B });

  const newer = headerFor({ window: { ...headerFor().window, replacementId: 'r2', parts: 1 } });
  const recovery = await staging.stagePart({ userId: USER, header: newer, records: [], bodySha256: SHA_A });
  const superseded = recovery.supersededComplete;
  if (!superseded) throw new Error('expected a complete prior generation');
  assert.equal(superseded.header.window.replacementId, 'r1');
  assert.equal(superseded.header.window.part, 2);
  assert.deepEqual(superseded.records.map((r: any) => r.data.steps), [100, 200]);
  assert.equal([...rest.rows.values()].some((r) => r.replacement_id === 'r2'), false);

  await staging.clearGeneration({ userId: USER, header: superseded.header });
  const accepted = await staging.stagePart({ userId: USER, header: newer, records: [], bodySha256: SHA_A });
  assert.equal(accepted.complete, true);
  assert.equal(accepted.isCompletingPart, true);
});

Deno.test('ingest: a newer generation repairs a complete unacknowledged generation before its own projection', async () => {
  const rest = makeStagingRest();
  const staging = createPushReplacementStaging({ rest: rest as any });
  const oldFirst = headerFor({ window: { ...headerFor().window, endExclusive: '2026-09-03' } });
  const oldSecond = headerFor({
    batchId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    window: { ...headerFor().window, endExclusive: '2026-09-03', part: 2 },
  });
  await staging.stagePart({ userId: USER, header: oldFirst,
    records: [{ type: 'record', key: { day: '2026-09-01' }, data: { steps: 100 } }], bodySha256: SHA_A });
  await staging.stagePart({ userId: USER, header: oldSecond,
    records: [{ type: 'record', key: { day: '2026-09-02' }, data: { steps: 200 } }], bodySha256: SHA_B });

  const newer = headerFor({
    batchId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
    recordCount: 1,
    delivery: 'replace_window',
    startCursor: null,
    endCursor: null,
    window: { ...headerFor().window, replacementId: 'r2', parts: 1 },
  });
  const body = new TextEncoder().encode(JSON.stringify({ type: 'batch', ...newer }) + '\n' +
    JSON.stringify({ type: 'record', key: { day: '2026-09-01' }, data: { steps: 300 } }) + '\n');
  const acks = new Map<string, any>();
  const walStore = {
    async consumeQuota() {}, async appendWal() {}, async trimWal() {},
    async getAck(_user: string, id: string) { return acks.get(id) ?? null; },
    async saveAck(_user: string, id: string, ack: any, bodySha256: string) { acks.set(id, { ack, bodySha256 }); },
  };
  const projected: any[][] = [];
  const ingest = createPushIngest({ walStore: walStore as any, replacementStaging: staging,
    archiveObject: async () => ({ ready: true }),
    upsertRows: async (_table, rows) => { projected.push(rows as any[]); },
    deleteRows: async () => {},
  });
  const ack = await ingest.acceptBatch({ userId: USER, decodedBody: body });
  assert.equal(ack.status, 'accepted');
  assert.deepEqual(projected.map((rows) => rows.map((row) => row.day)),
    [['2026-09-01', '2026-09-02'], ['2026-09-01']]);
  assert.deepEqual(projected.map((rows) => rows.map((row) => row.steps)), [[100, 200], [300]]);
  assert.equal(rest.rows.size, 0);
});

Deno.test('ingest: an acknowledged first part completes after a receiver upgrade', async () => {
  const rest = makeStagingRest();
  const header = headerFor({ window: { ...headerFor().window, endExclusive: '2026-09-03' } });
  const legacyScope = `${USER}|${header.sourceId}|${header.deviceId}|${header.stream}`;
  const identity = JSON.stringify({
    replacementId: header.window.replacementId,
    selector: header.window.selector,
    startInclusive: header.window.startInclusive,
    endExclusive: header.window.endExclusive,
    parts: header.window.parts,
  });
  const legacyPart = {
    user_id: USER, scope: legacyScope, replacement_id: header.window.replacementId,
    window_identity: identity, part: 1, parts_total: 2, batch_id: header.batchId,
    body_sha256: SHA_A,
    records: [{ type: 'record', key: { day: '2026-09-01' }, data: { steps: 100 } }],
  };
  rest.rows.set(`${legacyPart.user_id}${legacyPart.scope}${legacyPart.replacement_id}${legacyPart.part}`, legacyPart);

  const finalHeader = headerFor({
    batchId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', recordCount: 1,
    delivery: 'replace_window', startCursor: null, endCursor: null,
    window: { ...header.window, part: 2 },
  });
  const body = new TextEncoder().encode(JSON.stringify({ type: 'batch', ...finalHeader }) + '\n' +
    JSON.stringify({ type: 'record', key: { day: '2026-09-02' }, data: { steps: 200 } }) + '\n');
  const projected: any[][] = [];
  let acknowledged = false;
  const walStore = {
    async consumeQuota() {}, async appendWal() {}, async trimWal() {}, async getAck() { return null; },
    async saveAck() {
      assert.equal(projected.length, 1, 'the complete replacement must project before final-part ACK');
      acknowledged = true;
    },
  };
  const staging = createPushReplacementStaging({ rest: rest as any });
  const ingest = createPushIngest({ walStore: walStore as any, replacementStaging: staging,
    archiveObject: async () => ({ ready: true }),
    upsertRows: async (_table, rows) => { projected.push(rows as any[]); },
    deleteRows: async () => {},
  });
  await ingest.acceptBatch({ userId: USER, decodedBody: body });
  assert.equal(acknowledged, true);
  assert.deepEqual(projected[0].map((row) => row.day), ['2026-09-01', '2026-09-02']);
  assert.equal(rest.rows.size, 0);
});

Deno.test('staging: multipart state survives a new-to-old-to-new receiver sequence', async () => {
  const rest = makeStagingRest();
  const staging = createPushReplacementStaging({ rest: rest as any });
  const first = headerFor();
  const second = headerFor({
    batchId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    window: { ...headerFor().window, part: 2 },
  });
  await staging.stagePart({ userId: USER, header: first,
    records: [{ type: 'record', key: { day: '2026-09-01' }, data: { steps: 100 } }], bodySha256: SHA_A });

  const legacyScope = `${USER}|${first.sourceId}|${first.deviceId}|${first.stream}`;
  const stored = [...rest.rows.values()];
  assert.equal(stored.length, 1);
  assert.equal(stored[0].scope, legacyScope,
    'an older receiver must find the acknowledged first part in its unchanged scope');

  // This is the same legacy-scope read and write an old receiver performs after rollback. It must
  // combine the second part rather than ACKing an invisible incomplete generation.
  const completed = await staging.stagePart({ userId: USER, header: second,
    records: [{ type: 'record', key: { day: '2026-09-02' }, data: { steps: 200 } }], bodySha256: SHA_B });
  assert.equal(completed.complete, true);
  assert.equal(completed.isCompletingPart, true);
  assert.deepEqual(completed.records.map((row: any) => row.data.steps), [100, 200]);

  // The old receiver clears that generation after projection. Rolling forward then starts the
  // next generation in the same protocol-defined scope without reviving either old part.
  await staging.clearGeneration({ userId: USER, header: second });
  const next = headerFor({
    protocolVersion: '1.1',
    batchId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
    window: { ...headerFor().window, replacementId: 'r2' },
  });
  const rolledForward = await staging.stagePart({ userId: USER, header: next,
    records: [{ type: 'record', key: { day: '2026-09-01' }, data: { steps: 300 } }], bodySha256: SHA_C });
  assert.equal(rolledForward.complete, false);
  assert.equal(rest.rows.size, 1);
  assert.equal([...rest.rows.values()][0].replacement_id, 'r2');
});

Deno.test('staging: a protocol change still supersedes the same stream generation', async () => {
  const rest = makeStagingRest();
  const staging = createPushReplacementStaging({ rest: rest as any });
  const old = headerFor();
  const first = await staging.stagePart({ userId: USER, header: old, records: [], bodySha256: SHA_A });
  assert.equal(first.complete, false);
  const next = headerFor({ protocolVersion: '1.1', window: { ...headerFor().window, replacementId: 'r2' } });
  const superseding = await staging.stagePart({ userId: USER, header: next, records: [], bodySha256: SHA_B });
  assert.equal(superseding.complete, false);
  assert.equal(superseding.supersededComplete, undefined);
  assert.equal(rest.rows.size, 1);
  assert.equal([...rest.rows.values()][0].replacement_id, 'r2');
});

Deno.test('staging: same part, different batch or bytes, is a conflict', async () => {
  const rest = makeStagingRest();
  const staging = createPushReplacementStaging({ rest: rest as any });
  const header = headerFor();
  await staging.stagePart({ userId: USER, header, records: [], bodySha256: SHA_A });

  await assert.rejects(
    () => staging.stagePart({
      userId: USER,
      header: headerFor({ batchId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' }),
      records: [],
      bodySha256: SHA_A,
    }),
    (err: any) => err instanceof PushProtocolError && err.code === 'replacement_part_conflict' && err.status === 409,
  );
  await assert.rejects(
    () => staging.stagePart({ userId: USER, header, records: [], bodySha256: SHA_B }),
    (err: any) => err.code === 'batch_id_conflict' && err.status === 409,
  );
});

Deno.test('staging: a new replacement id abandons an incomplete generation', async () => {
  const rest = makeStagingRest();
  const staging = createPushReplacementStaging({ rest: rest as any });
  await staging.stagePart({ userId: USER, header: headerFor(), records: [], bodySha256: SHA_A });

  const superseding = headerFor({ window: { ...headerFor().window, replacementId: 'r2' } });
  const out = await staging.stagePart({ userId: USER, header: superseding, records: [], bodySha256: SHA_B });
  assert.equal(out.complete, false);
  const remaining = [...rest.rows.values()];
  assert.equal(remaining.length, 1);
  assert.equal(remaining[0].replacement_id, 'r2', 'the abandoned generation must be gone');
});

Deno.test('staging: window shape validation matches the Node codes', async () => {
  const rest = makeStagingRest();
  const staging = createPushReplacementStaging({ rest: rest as any });
  await assert.rejects(
    () => staging.stagePart({ userId: USER, header: { stream: 'dailyMetric' }, records: [], bodySha256: SHA_A }),
    (err: any) => err.code === 'missing_window',
  );
  await assert.rejects(
    () => staging.stagePart({
      userId: USER,
      header: headerFor({ window: { ...headerFor().window, part: 3 } }),
      records: [],
      bodySha256: SHA_A,
    }),
    (err: any) => err.code === 'invalid_window_part',
  );
  await assert.rejects(
    () => staging.stagePart({
      userId: USER,
      header: { ...headerFor(), endCursor: { rowId: 1 } },
      records: [],
      bodySha256: SHA_A,
    }),
    (err: any) => err.code === 'invalid_replace_cursor',
  );
});
