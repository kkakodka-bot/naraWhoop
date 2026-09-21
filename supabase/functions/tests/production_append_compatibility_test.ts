import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

const DEVICE = '33333333-3333-4333-8333-333333333333';
const SOURCE = '44444444-4444-4444-8444-444444444444';

Deno.test('production append repair accepts every advertised scalar projection and keeps scorer columns compatible', async () => {
  const db = await startLocalPostgres({ scalarProjections: true, appendCompatibility: true });
  try {
    await db.sql(`
      create table noop_app_installations(
        source_id uuid primary key,
        user_id uuid not null,
        revoked_at timestamptz
      );
      insert into devices(id,user_id,source_kind,external_device_id)
        values('${DEVICE}','${USER_A}','noop','fixture');
      insert into noop_app_installations values('${SOURCE}','${USER_A}',null);
    `);

    async function project(stream: string, fields: Record<string, unknown>, batch = crypto.randomUUID()) {
      const row = { user_id: USER_A, device_id: DEVICE, source_id: SOURCE, batch_id: batch, ...fields };
      const count = await db.rest.rpc('noop_project_append_batch', {
        p_user: USER_A, p_device: DEVICE, p_source: SOURCE, p_batch: batch,
        p_stream: stream, p_rows: [row],
      });
      assert.equal(count, 1);
      return { row, batch };
    }

    const step = await project('stepSample', { ts: 1_790_000_000, counter: 123, activity_class: 2 });
    assert.equal(await db.sql(`select activity_class||':'||"activityClass" from noop_step_samples
      where user_id='${USER_A}' and ts=1790000000`), '2:2');

    await project('sleepStateSample', { ts: 1_790_000_001, state: 3, raw_byte: 48 });
    assert.equal(await db.sql(`select state||':'||raw_byte from noop_sleep_state_samples
      where user_id='${USER_A}' and ts=1790000001`), '3:48');

    await project('ppgHrSample', { ts: 1_790_000_002, bpm: 71, conf: 0.75 });
    assert.equal(await db.sql(`select bpm||':'||conf from noop_ppg_hr_samples
      where user_id='${USER_A}' and ts=1790000002`), '71:0.75');

    await project('gravitySample', { ts: 1_790_000_003, x: 0.1, y: 0.2, z: 0.9, dynAccel: 0.4,
      orientation_evidence_version: 'projected-gravity-g-1',
      motion_evidence_version: 'projected-dynamic-acceleration-g-1' });
    assert.equal(await db.sql(`select orientation_evidence_version||':'||motion_evidence_version
      from noop_gravity_samples where user_id='${USER_A}' and ts=1790000003`),
      'projected-gravity-g-1:projected-dynamic-acceleration-g-1');

    assert.equal(await db.rest.rpc('noop_project_append_batch', {
      p_user: USER_A, p_device: DEVICE, p_source: SOURCE, p_batch: step.batch,
      p_stream: 'stepSample', p_rows: [step.row],
    }), 1, 'an exact receipt retry remains idempotent');

    await assert.rejects(project('stepSample', { ts: 1_790_000_000, counter: 124, activity_class: 2 }),
      /scalar_identity_conflict/);
    await assert.rejects(db.rest.rpc('noop_project_append_batch', {
      p_user: USER_A, p_device: DEVICE, p_source: SOURCE, p_batch: crypto.randomUUID(),
      p_stream: 'notAStream', p_rows: [{}],
    }), /unsupported append stream/);
    await assert.rejects(db.rest.rpc('noop_project_append_batch', {
      p_user: USER_A, p_device: DEVICE, p_source: SOURCE, p_batch: crypto.randomUUID(),
      p_stream: 'stepSample', p_rows: [{ ...step.row, user_id: '22222222-2222-4222-8222-222222222222' }],
    }), /append row identity mismatch/);
  } finally {
    await db.close();
  }
});
