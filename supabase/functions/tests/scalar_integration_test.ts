import assert from 'node:assert/strict';
import { gunzipSync } from 'node:zlib';
import { createPushArchive, createPushIngest } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { registerDevice, type DurabilityReceipt } from '../_shared/durability.ts';
import { commitArchivedBatch, reconcileProjections } from '../_shared/projections.ts';
import { advertisedStreams, capabilitiesBody } from '../_shared/registry.ts';
import { sha256Hex } from '../_shared/s3.ts';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';

const DEVICE = '33333333-3333-4333-8333-333333333333';
const SOURCE = '44444444-4444-4444-8444-444444444444';
const SECOND = 1_790_000_000;
const streams = [
  { stream: 'stepSample', table: 'noop_step_samples', required: 'counter', optional: 'activityClass',
    column: 'activity_class', value: 1234, extra: 2 },
  { stream: 'sleepStateSample', table: 'noop_sleep_state_samples', required: 'state', optional: 'rawByte',
    column: 'raw_byte', value: 3, extra: 48 },
  { stream: 'ppgHrSample', table: 'noop_ppg_hr_samples', required: 'bpm', optional: 'conf',
    column: 'conf', value: 73, extra: 0.75 },
] as const;

Deno.test('scalar intake: actual 050000/060000, PostgreSQL projections, HTTP archives and recovery', async (t) => {
  const db = await startLocalPostgres({ scalarProjections: true });
  const bucket = startObjectHttp();
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
  const archive = createPushArchive({ cfg, rest: db.rest, raw: bucket.raw });
  const ingest = (commit = (receipt: DurabilityReceipt, bytes: Uint8Array) => commitArchivedBatch(db.rest, receipt, bytes)) =>
    createPushIngest({ walStore: createPushWalStore({ rest: db.rest })!,
      archiveObject: (args) => archive.archiveObject(args), ensureDevice: (row) => registerDevice(db.rest, row), commitProjection: commit });
  const revision = async () => Number(await db.sql(`select coalesce(sum(input_revision),0) from scoring_jobs_v2
    where user_id='${USER_A}' and device_id='${DEVICE}'`));
  const manifest = async (id: string) => (await db.rest.select('object_manifests', `id=eq.${id}`))[0];
  const debt = (id: string) => db.sql(`select state from noop_projection_debt where object_id='${id}'`);
  const ackRows = (id: string) => db.rest.select('noop_push_acks', `batch_id=eq.${id}`);
  const proofs: unknown[] = [];
  try {
    await t.step('capabilities expose all three at existing versions without an object-lane change', () => {
      for (const version of ['1.0', '1.1', '1.2', '1.3']) {
        const caps = capabilitiesBody({ receiverStateId: 'scalar-fixture', protocolVersion: version,
          streams: advertisedStreams(version), objectLane: { endpoint: '/objects', maxObjectBytes: 1000, urlTtlSec: 300 } });
        for (const { stream } of streams) {
          assert.equal(caps.streams.includes(stream), version !== '1.0');
          assert(!caps.objectLane?.streams.includes(stream));
        }
      }
    });
    for (const [index, scalar] of streams.entries()) {
      const { stream, table, required, optional, column, value, extra } = scalar;
      const ts = SECOND + index * 100;
      function batch(at: number, measurement = value as number, withSecond = false) {
        const header = { type: 'batch', protocolVersion: '1.1', stream, deviceId: DEVICE, sourceId: SOURCE,
          batchId: crypto.randomUUID(), delivery: 'append', recordCount: withSecond ? 2 : 1,
          endCursor: { rowId: withSecond ? 2 : 1, keySha256: 'a'.repeat(64) } };
        const records = [{ type: 'record', key: { ts: at }, data: { [required]: measurement,
          [optional]: stream === 'sleepStateSample' ? measurement << 4 : extra } },
          ...withSecond ? [{ type: 'record', key: { ts: at + 1 }, data: { [required]: measurement - 1 } }] : []];
        return { header, records, body: new TextEncoder().encode([header, ...records].map((row) => JSON.stringify(row)).join('\n') + '\n') };
      }
      const select = (at: number) => db.rest.select(table, `user_id=eq.${USER_A}&device_id=eq.${DEVICE}&ts=eq.${at}`);

      await t.step(`${stream}: exact values/nulls, owner RLS, atomic ACK/debt and duplicate receipt`, async () => {
        const f = batch(ts, value, true);
        const ack = await ingest().acceptBatch({ userId: USER_A, decodedBody: f.body });
        assert.equal(ack.acceptedRows, 2); assert.deepEqual(ack.endCursor, f.header.endCursor);
        assert.equal(ack.durabilityReceipt.state, 'verified_indexed');
        assert.equal(ack.durabilityReceipt.contentSha256, sha256Hex(f.body));
        assert.equal(ack.durabilityReceipt.ownerUserId, USER_A);
        assert.equal(ack.durabilityReceipt.deviceId, DEVICE);
        assert.equal(ack.durabilityReceipt.sourceId, SOURCE);
        assert.equal((await select(ts))[0][required], value);
        assert.equal((await select(ts))[0][column], extra);
        assert.equal((await select(ts + 1))[0][column], null, 'missing optional scalar remains unknown');
        const bytes = bucket.objects.get(ack.durabilityReceipt.objectKey)!;
        assert.deepEqual(new Uint8Array(gunzipSync(bytes)), f.body);
        assert.equal(await debt(f.header.batchId), 'complete');
        assert.equal((await ackRows(f.header.batchId)).length, 1);
        assert.equal((await db.rest.select('noop_push_wal', `batch_id=eq.${f.header.batchId}`)).length, 0);
        const before = await revision(); assert(before > 0);
        assert.deepEqual(await ingest().acceptBatch({ userId: USER_A, decodedBody: f.body }), ack);
        assert.deepEqual(await commitArchivedBatch(db.rest, ack.durabilityReceipt, f.body), ack);
        assert.equal(await revision(), before);
        const own = await db.request(`${table}?device_id=eq.${DEVICE}&ts=eq.${ts}`, 'authenticated', USER_A);
        const other = await db.request(`${table}?device_id=eq.${DEVICE}&ts=eq.${ts}`, 'authenticated', USER_B);
        assert.equal(own.status, 200); assert.equal(own.body.length, 1);
        assert.equal(other.status, 200); assert.deepEqual(other.body, []);
        const row = (await select(ts))[0];
        for (const user of [USER_A, USER_B]) {
          const write = await db.request(table, 'authenticated', user, 'POST', row);
          assert.equal(write.status, 403);
          const privileged = await db.request('rpc/noop_apply_projection_rows', 'authenticated', user, 'POST', {
            p_stream: stream, p_rows: [row],
          });
          assert.equal(privileged.status, 403);
        }
        const beforeForeign = bucket.objects.size;
        await assert.rejects(ingest().acceptBatch({ userId: USER_B, decodedBody: f.body }), /device_owner_conflict/);
        assert.equal(bucket.objects.size, beforeForeign);
        proofs.push({ stream, receipt: ack.durabilityReceipt, ownerRead: own.status, otherOwnerRows: other.body.length });
      });

      await t.step(`${stream}: server-only replay repairs verified archive crash and dirties settled scores`, async () => {
        const f = batch(ts + 10);
        await assert.rejects(ingest(() => { throw new Error('fixture_after_verified_archive'); })
          .acceptBatch({ userId: USER_A, decodedBody: f.body }), /fixture_after_verified_archive/);
        assert.equal((await manifest(f.header.batchId)).durability_receipt.state, 'verified_indexed');
        assert.equal((await select(ts + 10)).length, 0);
        assert.equal((await ackRows(f.header.batchId)).length, 0); assert.equal(await debt(f.header.batchId), 'pending');
        // The actual v2 lease/publication RPCs may finish the index generation before projection.
        for (let i = 0; i < 3; i++) {
          const [job] = await db.rest.rpc('claim_scoring_v2', { p_version: 'frwhoop-server-1' });
          assert(job);
          assert(await db.rest.rpc('publish_scoring_snapshot_v2', { p_token: job.lease_token, p_revision: job.input_revision,
            p_payload: { status: 'no_data', daily: null, sleep: [], coverage: {}, dataThrough: null, timezone: 'UTC' }, p_duration_ms: 1 }));
        }
        const before = await revision();
        assert.deepEqual(await reconcileProjections(db.rest, bucket.raw, 1), { scanned: 1, settled: 1, deferred: 0 });
        assert.equal((await select(ts + 10))[0][required], value);
        assert((await revision()) > before);
        assert.equal(await db.sql(`select count(*) from scoring_jobs_v2 where user_id='${USER_A}'
          and device_id='${DEVICE}' and completed_revision<input_revision`), '3');
        assert.equal(await debt(f.header.batchId), 'complete'); assert.equal((await ackRows(f.header.batchId)).length, 1);
      });

      await t.step(`${stream}: invalidation failure rolls back projection, ACK and debt; replay repairs`, async () => {
        const f = batch(ts + 20);
        await db.sql(`create or replace function fixture_scalar_abort() returns trigger language plpgsql as $$begin
          if new.reason='${table}' then raise exception 'fixture_scalar_invalidation'; end if; return new; end$$;
          create trigger fixture_scalar_abort before update on scoring_jobs_v2 for each row execute function fixture_scalar_abort();`);
        let afterArchive = 0;
        await assert.rejects(ingest(async (receipt, bytes) => {
          afterArchive = await revision(); return commitArchivedBatch(db.rest, receipt, bytes);
        }).acceptBatch({ userId: USER_A, decodedBody: f.body }), /fixture_scalar_invalidation/);
        assert.equal(await revision(), afterArchive); assert.equal((await select(ts + 20)).length, 0);
        assert.equal((await ackRows(f.header.batchId)).length, 0); assert.equal(await debt(f.header.batchId), 'pending');
        assert.equal((await reconcileProjections(db.rest, bucket.raw, 1)).deferred, 1);
        await db.sql(`drop trigger fixture_scalar_abort on scoring_jobs_v2;
          update noop_projection_debt set not_before=clock_timestamp() where object_id='${f.header.batchId}';`);
        assert.equal((await reconcileProjections(db.rest, bucket.raw, 1)).settled, 1);
        assert.equal((await select(ts + 20)).length, 1); assert((await revision()) > afterArchive);
        assert.equal((await ackRows(f.header.batchId)).length, 1); assert.equal(await debt(f.header.batchId), 'complete');
      });

      await t.step(`${stream}: changed same-second values retain the original projection and explicit replay debt`, async () => {
        const old = batch(ts + 30);
        await assert.rejects(ingest(() => { throw new Error('fixture_before_projection'); })
          .acceptBatch({ userId: USER_A, decodedBody: old.body }), /fixture_before_projection/);
        const newer = batch(ts + 30, value - 1);
        await assert.rejects(ingest(async (receipt, bytes) => {
          await commitArchivedBatch(db.rest, receipt, bytes); throw new Error('fixture_lost_ack');
        }).acceptBatch({ userId: USER_A, decodedBody: newer.body }), /fixture_lost_ack/);
        const before = await revision();
        assert.equal((await reconcileProjections(db.rest, bucket.raw, 1)).deferred, 1);
        assert.equal((await select(ts + 30))[0][required], value - 1);
        await db.sql(`update noop_projection_debt set not_before=clock_timestamp()+interval '1 hour'
          where object_id='${old.header.batchId}'`);
        assert.equal((await select(ts + 30))[0].batch_id, newer.header.batchId);
        assert.equal(await revision(), before);
        await ingest().acceptBatch({ userId: USER_A, decodedBody: newer.body });
        assert.equal(await revision(), before);
        assert.equal(await debt(old.header.batchId), 'pending'); assert.equal(await debt(newer.header.batchId), 'complete');
        await assert.rejects(ingest().acceptBatch({ userId: USER_A, decodedBody: old.body }),
          (error: any) => error.code === 'scalar_identity_conflict' && error.status === 409);
        assert.equal((await ackRows(old.header.batchId)).length, 0);
        assert.equal((await manifest(old.header.batchId)).durability_receipt.state, 'verified_indexed');
        assert.equal((await select(ts + 30))[0][required], value - 1);
      });

      await t.step(`${stream}: concurrent exact replay settles one projection generation`, async () => {
        const f = batch(ts + 40);
        let afterArchive = 0;
        const concurrent = ingest(async (receipt, bytes) => {
          afterArchive = await revision();
          const [one, two] = await Promise.all([commitArchivedBatch(db.rest, receipt, bytes), commitArchivedBatch(db.rest, receipt, bytes)]);
          assert.deepEqual(one, two); return one;
        });
        await concurrent.acceptBatch({ userId: USER_A, decodedBody: f.body });
        assert.equal((await select(ts + 40)).length, 1);
        assert.equal((await revision()) - afterArchive, 3, 'one projection invalidation per affected wake day');
        assert.equal((await ackRows(f.header.batchId)).length, 1); assert.equal(await debt(f.header.batchId), 'complete');
      });

      await t.step(`${stream}: malformed row cannot be dropped behind a successful ACK`, async () => {
        const f = batch(ts + 50, value, true);
        f.records[1].data = { [required]: null } as any;
        const bytes = new TextEncoder().encode([f.header, ...f.records].map((row) => JSON.stringify(row)).join('\n') + '\n');
        const objectsBefore = bucket.objects.size;
        await assert.rejects(ingest().acceptBatch({ userId: USER_A, decodedBody: bytes }), /invalid_scalar_record/);
        assert.equal(bucket.objects.size, objectsBefore);
        assert.equal((await ackRows(f.header.batchId)).length, 0);
        assert.equal((await db.rest.select('noop_push_reservations', `batch_id=eq.${f.header.batchId}`)).length, 0);
        assert.equal((await select(ts + 50)).length, 0);
      });
    }
    await Deno.writeTextFile(`${db.base}/scalar-projection-proof.json`, JSON.stringify({ proofs,
      pendingDebt: await db.sql("select count(*) from noop_projection_debt where state<>'complete'"),
      migration: '20260918060000_production_scalar_projections.sql' }, null, 2));
    console.log(`Scalar projection proof: ${db.base}/scalar-projection-proof.json`);
  } finally { await bucket.close(); await db.close(); }
});
