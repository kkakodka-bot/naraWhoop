import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { createPushObjects } from '../_shared/objects.ts';
import { completeDurableObject, verifyStoredObject } from '../_shared/durability.ts';
import { sweepCopyIntents } from '../_shared/copyIntents.ts';
import { sha256Hex } from '../_shared/s3.ts';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';

Deno.test('copy attempts survive crash boundaries and only noncurrent expired snapshots are swept', async (t) => {
  const db = await startLocalPostgres();
  const bucket = startObjectHttp({versioned:true});
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture' };
  const objects = createPushObjects({ cfg, rest: db.rest, raw: bucket.raw });
  const manifest = async (id: string) => (await db.rest.select('object_manifests', `id=eq.${id}`))[0];
  const intents = (id: string) => db.rest.select('noop_object_copy_intents', `object_id=eq.${id}`);
  async function upload() {
    const payload = new TextEncoder().encode('synthetic immutable sample');
    const wire = new Uint8Array(gzipSync(payload));
    const id = crypto.randomUUID();
    const intent = await objects.createIntent({ userId: USER_A, manifest: {
      type: 'binaryObject', protocolVersion: '1.3', stream: 'ppgWaveformSample',
      deviceId: '33333333-3333-4333-8333-333333333333', objectId: id,
      batchId: crypto.randomUUID(), sourceId: '44444444-4444-4444-8444-444444444444',
      startTs: 1_790_000_000, endTs: 1_790_000_002, sampleCount: 1,
      uncompressedBytes: payload.length, compressedBytes: wire.length,
      contentSha256: sha256Hex(payload), contentEncoding: 'gzip',
    } });
    const response = await fetch(intent.uploadUrl!, { method: 'PUT', body: wire, headers: intent.requiredHeaders });
    await response.body?.cancel(); assert.equal(response.status, 200);
    return { row: await manifest(id), wire, staging: intent.objectKey };
  }
  const reserve = (row: any) => db.rest.rpc('noop_reserve_copy_intent', { p_user_id: USER_A, p_object_id: row.id });
  async function age(id: string) {
    await db.sql(`update noop_object_copy_intents set created_at=now()-interval '25 hours',
      lease_until=now()-interval '24 hours',next_sweep_at=now()-interval '1 hour',sweep_lease_until=null
      where id='${id}';`);
  }
  async function commit(row: any, intent: any) {
    const v = await verifyStoredObject(bucket.raw,row,intent.verified_key);
    return db.rest.rpc('noop_commit_copy_receipt', {
      p_intent_id: intent.id,p_lease_token: intent.lease_token,p_wire_sha256:v.wireSha256,
      p_content_sha256:v.contentSha256,p_compressed_bytes:v.compressedBytes,
      p_uncompressed_bytes:v.uncompressedBytes,p_verification_ms:1,p_validation:null,
    });
  }
  try {
    await t.step('reservation failure prevents any object COPY', async () => {
      const f = await upload(); let copies = 0;
      await assert.rejects(completeDurableObject({ row:f.row, rest:{...db.rest, rpc:async (name,args) => {
        if (name==='noop_reserve_copy_intent') throw new Error('fixture DB unavailable');
        return await db.rest.rpc(name,args);
      }},raw:{...bucket.raw, copyObject:async () => { copies++; }} }), /fixture DB unavailable/);
      assert.equal(copies,0); assert.equal((await intents(f.row.id)).length,0);
    });
    await t.step('crash after reservation but before COPY leaves bounded tracked absent debt', async () => {
      const f = await upload(), attempt = await reserve(f.row);
      await age(attempt.id);
      const swept = await sweepCopyIntents(db.rest,bucket.raw);
      assert.equal(swept.absent,1);
      assert.equal((await intents(f.row.id))[0].state,'swept');
      assert(bucket.objects.has(f.staging));
      assert.equal((await manifest(f.row.id)).durability_receipt,null);
    });
    await t.step('lost reservation and COPY responses leave recoverable tracked attempts', async () => {
      const reserved=await upload();let copies=0;
      await assert.rejects(completeDurableObject({row:reserved.row,raw:{...bucket.raw,copyObject:async () => { copies++; }},
        rest:{...db.rest,rpc:async (name,args) => {
          const result=await db.rest.rpc(name,args);
          if(name==='noop_reserve_copy_intent') throw new Error('fixture lost reservation response');
          return result;
        }}}),/fixture lost reservation response/);
      assert.equal(copies,0);
      const reservedAttempt=(await intents(reserved.row.id))[0];
      assert.equal(reservedAttempt.state,'copying');await age(reservedAttempt.id);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw)).absent,1);
      const copied=await upload();
      await assert.rejects(completeDurableObject({row:copied.row,rest:db.rest,raw:{...bucket.raw,
        copyObject:async (source,destination) => {
          await bucket.raw.copyObject(source,destination);throw new Error('fixture lost COPY response');
        }}}),/fixture lost COPY response/);
      const copiedAttempt=(await intents(copied.row.id))[0];
      assert.equal(copiedAttempt.state,'abandoned');assert(bucket.objects.has(copiedAttempt.verified_key));
      await age(copiedAttempt.id);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw)).deleted,1);
      assert.equal((await manifest(copied.row.id)).durability_receipt,null);
    });
    await t.step('crash after COPY cannot leak an untracked object or advance a receipt', async () => {
      const f = await upload(), attempt = await reserve(f.row);
      await bucket.raw.copyObject(attempt.upload_key,attempt.verified_key);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw)).claimed,0);
      await age(attempt.id);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw)).deleted,1);
      assert(!bucket.objects.has(attempt.verified_key)); assert(bucket.objects.has(f.staging));
      assert.equal((await manifest(f.row.id)).durability_receipt,null);
      await bucket.raw.copyObject(attempt.upload_key,attempt.verified_key);
      await assert.rejects(commit(f.row,attempt),/copy_lease_lost/);
      // Tombstones remain eligible if an externally delayed COPY appears after a sweep.
      await age(attempt.id);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw)).deleted,1);
      assert(!bucket.objects.has(attempt.verified_key));
    });
    await t.step('lost committed response preserves the exact published key', async () => {
      const f = await upload();
      await assert.rejects(completeDurableObject({row:f.row,raw:bucket.raw,rest:{...db.rest,rpc:async (name,args) => {
        const result=await db.rest.rpc(name,args);
        if(name==='noop_commit_copy_receipt') throw new Error('fixture lost response');
        return result;
      }}}),/fixture lost response/);
      const saved=await manifest(f.row.id), attempt=(await intents(f.row.id))[0];
      assert.equal(attempt.state,'published'); assert.equal(saved.durability_receipt.objectKey,attempt.verified_key);
      await age(attempt.id);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw)).claimed,0);
      assert(bucket.objects.has(attempt.verified_key));
      assert.deepEqual((await objects.completeObject({userId:USER_A,objectId:f.row.id})).durabilityReceipt,saved.durability_receipt);
      assert.deepEqual(await commit(f.row,attempt),saved.durability_receipt);
      // A stale abandoned marker cannot override current manifest/receipt references.
      await db.rest.patch('noop_object_copy_intents',{state:'abandoned'},`id=eq.${attempt.id}`);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw)).claimed,0);
      assert.equal((await intents(f.row.id))[0].state,'published');
    });
    await t.step('a losing concurrent completion is retained then swept without touching winner', async () => {
      const f=await upload();
      const a=await reserve(f.row),b=await reserve(f.row);
      await bucket.raw.copyObject(a.upload_key,a.verified_key);
      await bucket.raw.copyObject(b.upload_key,b.verified_key);
      const [ra,rb]=await Promise.all([commit(f.row,a),commit(f.row,b)]);
      assert.deepEqual(ra,rb);
      const loser=ra.objectKey===a.verified_key?b:a;
      await age(loser.id);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw)).deleted,1);
      assert(bucket.objects.has(ra.objectKey)); assert(!bucket.objects.has(loser.verified_key));
    });
    await t.step('expired publication and stale sweep tokens are fenced', async () => {
      const f=await upload(),a=await reserve(f.row);
      await bucket.raw.copyObject(a.upload_key,a.verified_key); await age(a.id);
      await assert.rejects(commit(f.row,a),/copy_lease_lost/);
      const first=(await db.rest.rpc('noop_claim_copy_orphans',{p_limit:1,p_max_bytes:268435456}))[0];
      assert.equal(first.id,a.id);
      await db.sql(`update noop_object_copy_intents set sweep_lease_until=now()-interval '1 second' where id='${a.id}'`);
      const second=(await db.rest.rpc('noop_claim_copy_orphans',{p_limit:1,p_max_bytes:268435456}))[0];
      assert.notEqual(first.token,second.token);
      assert.equal(await db.rest.rpc('noop_finish_copy_sweep',{p_intent_id:a.id,p_sweep_token:first.token,p_succeeded:true}),false);
      assert.equal(await db.rest.rpc('noop_finish_copy_sweep',{p_intent_id:a.id,p_sweep_token:second.token,p_succeeded:false}),true);
      await age(a.id); await sweepCopyIntents(db.rest,bucket.raw);
    });
    await t.step('row byte and wall-clock budgets bound each worker wake', async () => {
      const f=await upload(),a=await reserve(f.row),b=await reserve(f.row);
      await bucket.raw.copyObject(a.upload_key,a.verified_key);
      await bucket.raw.copyObject(b.upload_key,b.verified_key); await age(a.id);await age(b.id);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw,{maxBytes:f.wire.length-1})).claimed,0);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw,{limit:1,maxBytes:f.wire.length})).deleted,1);
      const deferred=await sweepCopyIntents(db.rest,bucket.raw,{maxMilliseconds:0});
      assert.equal(deferred.claimed,1);assert.equal(deferred.deferred,1);assert.equal(deferred.deleted,0);
      for(const remaining of await intents(f.row.id)) if(remaining.state==='deleting') await age(remaining.id);
      await sweepCopyIntents(db.rest,bucket.raw);
    });
    await t.step('exact old-version deletion leaves a COPY that arrives after HEAD discoverable', async () => {
      const f=await upload(),a=await reserve(f.row);
      await bucket.raw.copyObject(a.upload_key,a.verified_key);await age(a.id);
      const originalVersion=(await bucket.raw.head(a.verified_key))!.versionId;
      const swept=await sweepCopyIntents(db.rest,{...bucket.raw,head:async (key) => {
        const head=await bucket.raw.head(key);
        await bucket.raw.copyObject(a.upload_key,a.verified_key);
        return head;
      }});
      assert.equal(swept.deleted,1);
      assert(bucket.objects.has(a.verified_key));
      assert.equal(bucket.versions.get(a.verified_key)!.size,1);
      assert(!bucket.versions.get(a.verified_key)!.has(originalVersion!));
      await age(a.id);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw)).deleted,1);
      assert(!bucket.objects.has(a.verified_key));
    });
    await t.step('manifest deletion preserves cleanup ownership for a later COPY', async () => {
      const f=await upload(),a=await reserve(f.row);
      await db.rest.delete('object_manifests',`id=eq.${f.row.id}`);
      const retained=(await db.rest.select('noop_object_copy_intents',`id=eq.${a.id}`))[0];
      assert.equal(retained.object_id,null);
      await bucket.raw.copyObject(a.upload_key,a.verified_key);
      await assert.rejects(commit(f.row,a),/object_unavailable/);
      await age(a.id);
      assert.equal((await sweepCopyIntents(db.rest,bucket.raw)).deleted,1);
      assert(!bucket.objects.has(a.verified_key));
    });
    await t.step('service-only ledger metrics and settlement deny normal account roles', async () => {
      const f=await upload();
      await assert.rejects(db.rest.rpc('noop_reserve_copy_intent',{p_user_id:USER_B,p_object_id:f.row.id}),/object_owner_conflict/);
      for(const role of ['anon','authenticated']) {
        for(const table of ['noop_object_copy_intents','noop_copy_intake_metrics']) {
          const result=await db.request(`${table}?select=*`,role,USER_A);
          assert([401,403].includes(result.status));
        }
        for(const [name,args] of [
          ['noop_reserve_copy_intent',{p_user_id:USER_A,p_object_id:f.row.id}],
          ['noop_commit_copy_receipt',{p_intent_id:crypto.randomUUID(),p_lease_token:crypto.randomUUID(),
            p_wire_sha256:'a'.repeat(64),p_content_sha256:'a'.repeat(64),p_compressed_bytes:1,
            p_uncompressed_bytes:1,p_verification_ms:1,p_validation:null}],
          ['noop_abandon_copy_intent',{p_intent_id:crypto.randomUUID(),p_lease_token:crypto.randomUUID(),p_failure_code:'copy_failed'}],
          ['noop_claim_copy_orphans',{p_limit:1,p_max_bytes:1024}],
          ['noop_finish_copy_sweep',{p_intent_id:crypto.randomUUID(),p_sweep_token:crypto.randomUUID(),p_succeeded:true}],
        ] as const) {
          const result=await db.request(`rpc/${name}`,role,USER_A,'POST',args);
          assert([401,403].includes(result.status));
        }
      }
      const metrics=(await db.rest.select('noop_copy_intake_metrics'))[0];
      assert(metrics.intake_debt_count>0);assert(metrics.sweep_attempt_count>0);
      assert(metrics.verification_index_p99_ms>=0);
      assert(!JSON.stringify(metrics).includes(USER_A));
      await Deno.writeTextFile(`${db.base}/copy-intent-metrics.json`,JSON.stringify(metrics,null,2));
    });
    await t.step('missing object version fails closed without claiming reclaimed bytes', async () => {
      const f=await upload(),a=await reserve(f.row);
      await bucket.raw.copyObject(a.upload_key,a.verified_key);await age(a.id);
      let deletes=0;
      const result=await sweepCopyIntents(db.rest,{
        head:async () => ({exists:true,contentLength:f.wire.length,versionId:null}),
        deleteObject:async () => { deletes++;return {deleted:true,missing:false}; },
      });
      assert.equal(result.failed,1);assert.equal(result.deletedBytes,0);assert.equal(deletes,0);
      assert(bucket.objects.has(a.verified_key));
      assert.equal((await intents(f.row.id))[0].state,'abandoned');
      await age(a.id);await sweepCopyIntents(db.rest,bucket.raw);
    });
    await t.step('account deletion detaches tombstones and fences a delayed COPY publication', async () => {
      const f=await upload(),a=await reserve(f.row);
      // The external COPY was already dispatched. Preserve its synthetic result until after deletion.
      const lateBytes=bucket.objects.get(a.upload_key)!.slice();
      await db.rest.delete('object_manifests',`user_id=eq.${USER_A}`);
      await db.sql(`delete from auth.users where id='${USER_A}';`);
      const retained=(await db.rest.select('noop_object_copy_intents',`id=eq.${a.id}`))[0];
      assert.equal(retained.object_id,null);assert.equal(retained.user_id,null);
      await bucket.raw.putObject(a.verified_key,lateBytes);
      await assert.rejects(commit(f.row,a),/object_unavailable/);
      await age(a.id);
      const swept=await sweepCopyIntents(db.rest,bucket.raw);
      assert(swept.deleted>=1);assert(!bucket.objects.has(a.verified_key));
    });
  } finally { await bucket.close(); await db.close(); }
});
