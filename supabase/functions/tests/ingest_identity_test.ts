import { assertEquals, assertRejects } from 'jsr:@std/assert';
import { createPushIngest } from '../_shared/ingest.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const SOURCE_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const SOURCE_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const BATCH = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const DEVICE = 'my-whoop';
const DEVICE_UUID = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const TOKEN_ID = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

function body(sourceId: string, deviceId = DEVICE) {
  return new TextEncoder().encode(JSON.stringify({
    type: 'batch',
    protocolVersion: '1.1',
    batchId: BATCH,
    sourceId,
    deviceId,
    stream: 'hrSample',
    delivery: 'append',
    recordCount: 0,
    endCursor: null,
  }) + '\n');
}

function harness() {
  const calls: any = { wal: 0, archive: 0, device: 0, receipts: [] as any[], archiveArgs: null };
  const acks = new Map<string, any>();
  const walStore: any = {
    async getAck(_userId: string, batchId: string) {
      return acks.get(batchId) || null;
    },
    async appendWal() {
      calls.wal += 1;
    },
    async saveAck(_userId: string, batchId: string, ack: any, bodySha256: string) {
      acks.set(batchId, { ack, bodySha256 });
    },
    async trimWal() {},
  };
  const ingest = createPushIngest({
    walStore,
    archiveObject: async (args: any) => {
      calls.archive += 1;
      calls.archiveArgs = args;
      return { ready: true };
    },
    resolveDeviceId: async () => {
      calls.device += 1;
      return DEVICE_UUID;
    },
    receiptStore: {
      configured: true,
      async recordAccepted(receipt: any) {
        calls.receipts.push(receipt);
        return receipt;
      },
    },
    now: () => new Date('2026-09-19T12:00:00.000Z'),
  });
  return { calls, ingest };
}

Deno.test('inline identity: source mismatch is rejected before WAL, device, archive, or receipt work', async () => {
  const h = harness();
  const err = await assertRejects(
    () => h.ingest.acceptBatch({
      userId: USER,
      sourceId: SOURCE_A,
      tokenId: TOKEN_ID,
      authMode: 'installation',
      decodedBody: body(SOURCE_B),
    }),
  );
  assertEquals((err as any).code, 'source_id_mismatch');
  assertEquals((err as any).status, 403);
  assertEquals(h.calls.wal, 0);
  assertEquals(h.calls.device, 0);
  assertEquals(h.calls.archive, 0);
  assertEquals(h.calls.receipts.length, 0);
});

Deno.test('inline identity: accepted data and receipt use server-bound identity provenance', async () => {
  const h = harness();
  const ack = await h.ingest.acceptBatch({
    userId: USER,
    sourceId: SOURCE_A,
    tokenId: TOKEN_ID,
    authMode: 'installation',
    decodedBody: body(SOURCE_A),
  });
  assertEquals(ack.status, 'accepted');
  assertEquals(h.calls.archiveArgs.sourceId, SOURCE_A);
  assertEquals(h.calls.archiveArgs.tokenId, TOKEN_ID);
  assertEquals(h.calls.archiveArgs.authMode, 'installation');
  assertEquals(h.calls.receipts, [{
    userId: USER,
    sourceId: SOURCE_A,
    deviceId: DEVICE_UUID,
    tokenId: TOKEN_ID,
    authMode: 'installation',
    lane: 'inline',
    stream: 'hrSample',
    batchId: BATCH,
    objectId: BATCH,
    bodySha256: h.calls.receipts[0].bodySha256,
    acceptedStatus: 'accepted',
    acceptedRows: 0,
  }]);
});

Deno.test('inline identity: unsafe wearable ids fail before durable side effects', async () => {
  const h = harness();
  const err = await assertRejects(
    () => h.ingest.acceptBatch({
      userId: USER,
      sourceId: SOURCE_A,
      tokenId: TOKEN_ID,
      authMode: 'installation',
      decodedBody: body(SOURCE_A, 'tester@example.test'),
    }),
  );
  assertEquals((err as any).code, 'invalid_device_id');
  assertEquals((err as any).status, 400);
  assertEquals(h.calls.wal, 0);
  assertEquals(h.calls.archive, 0);
});
