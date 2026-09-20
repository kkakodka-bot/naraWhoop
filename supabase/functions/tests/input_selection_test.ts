import assert from 'node:assert/strict';
import { gunzipSync } from 'node:zlib';
import { scalarProvenance } from '../_shared/scalarProvenance.ts';
import { createPushArchive, createPushIngest } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { registerDevice } from '../_shared/durability.ts';
import { commitArchivedBatch, reconcileProjections } from '../_shared/projections.ts';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';

const base = { v: 1, origin: 'whoop-v26-ppg-derived', algorithm: 'ppg-acf-v1',
  sampleRateHz: 24, windowSettingSeconds: 8, inputStartTs: 1790000000, inputEndTs: 1790000009,
  inputSHA256: 'a'.repeat(64) };
const selections = ['last-record-per-second-v1', 'concat-records-per-second-v1'];
const malformed: unknown[] = [null, 0, true, '', 'unknown', [], {}];

Deno.test('PPG selection is optional, strict and derived-only', () => {
  assert.deepEqual(scalarProvenance(base, '1.4'), base);
  for (const inputSelection of selections) {
    const p = { ...base, inputSelection };
    assert.deepEqual(scalarProvenance(p, '1.4'), p);
    assert.throws(() => scalarProvenance(p, '1.3'), /invalid_scalar_provenance/);
    for (const origin of ['whoop-v18', 'legacy-unknown']) {
      assert.throws(() => scalarProvenance({ v: 1, origin, inputSelection }, '1.4'), /invalid_scalar_provenance/);
    }
  }
  for (const inputSelection of malformed) {
    assert.throws(() => scalarProvenance({ ...base, inputSelection }, '1.4'), /invalid_scalar_provenance/);
  }
});

Deno.test('080 PPG selection survives verified archive replay and PostgreSQL constraints', async () => {
  const db = await startLocalPostgres({ auxiliaryIdentity: true });
  const bucket = startObjectHttp();
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
  const archive = createPushArchive({ cfg, rest: db.rest, raw: bucket.raw });
  const ingest = (fault = false) => createPushIngest({ walStore: createPushWalStore({ rest: db.rest })!,
    ensureDevice: (row) => registerDevice(db.rest, row), archiveObject: (args) => archive.archiveObject(args),
    commitProjection: (receipt, bytes) => {
      if (fault) throw new Error('fixture_selection_after_archive');
      return commitArchivedBatch(db.rest, receipt, bytes);
    } });
  try {
    for (const [i, inputSelection] of [undefined, ...selections].entries()) {
      const provenance = inputSelection ? { ...base, inputSelection } : base;
      assert.equal(await db.rest.rpc('noop_valid_scalar_provenance', { p: provenance }), true);
      const header = { type: 'batch', protocolVersion: '1.4', schemaVersion: 2, stream: 'ppgHrSample',
        deviceId: '33333333-3333-4333-8333-333333333333', sourceId: '44444444-4444-4444-8444-444444444444',
        batchId: crypto.randomUUID(), delivery: 'append', recordCount: 1 };
      const ts = 1790000000 + i;
      const body = new TextEncoder().encode([header,
        { type: 'record', key: { ts }, data: { bpm: 72, conf: 0.8, provenance } }]
        .map((v) => JSON.stringify(v)).join('\n') + '\n');
      await assert.rejects(ingest(true).acceptBatch({ userId: USER_A, decodedBody: body }), /fixture_selection_after_archive/);
      assert.equal((await db.rest.select('noop_ppg_hr_samples', `ts=eq.${ts}`)).length, 0);
      assert.equal((await reconcileProjections(db.rest, bucket.raw, 1)).settled, 1);
      const row = (await db.rest.select('noop_ppg_hr_samples', `ts=eq.${ts}`))[0];
      assert.deepEqual(row.provenance, provenance);
      const ack = await ingest().acceptBatch({ userId: USER_A, decodedBody: body });
      assert.deepEqual(new Uint8Array(gunzipSync(bucket.objects.get(ack.durabilityReceipt.objectKey)!)), body);
      const foreign = await db.request(`noop_ppg_hr_samples?ts=eq.${ts}`, 'authenticated', USER_B);
      assert.deepEqual(foreign.body, []);
      for (const invalid of malformed) {
        const bad = { ...base, inputSelection: invalid };
        assert.equal(await db.rest.rpc('noop_valid_scalar_provenance', { p: bad }), false);
        await assert.rejects(db.rest.upsert('noop_ppg_hr_samples', [{ ...row, ts: ts + 100, provenance: bad }],
          { onConflict: 'user_id,device_id,ts' }), /provenance_valid/);
      }
    }
    for (const inputSelection of selections) {
      for (const origin of ['whoop-v18', 'legacy-unknown']) {
        assert.equal(await db.rest.rpc('noop_valid_scalar_provenance', { p: { v: 1, origin, inputSelection } }), false);
      }
    }
    assert.equal((await db.request('rpc/noop_valid_scalar_provenance', 'authenticated', USER_A, 'POST', { p: base })).status, 403);
  } finally { await bucket.close(); await db.close(); }
});
