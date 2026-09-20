# Intake durability receipt v1

`POST /push/objects/:objectId/complete` returns `type: "objectAck"`,
the reserved `protocolVersion` (1.2 or 1.3), `objectId`, `status: "ready"`, `objectKey`, `duplicate`,
and `durabilityReceipt`. An already completed intent returns the same receipt without
an upload URL. Inline ACKs also carry a receipt for their archived NDJSON object.

```json
{
  "version": 1,
  "state": "verified_indexed",
  "receiptId": "<stable UUID>",
  "ownerUserId": "<authenticated account UUID>",
  "deviceId": "<canonical owned device UUID>",
  "objectId": "<object UUID>",
  "batchId": "<batch UUID>",
  "sourceId": "<source UUID>",
  "stream": "ppgWaveformSample",
  "schemaVersion": 2,
  "objectKey": "<server-only verified archive key>",
  "contentSha256": "<lowercase SHA-256 of decoded payload>",
  "wireSha256": "<lowercase SHA-256 of stored compressed bytes>",
  "compressedBytes": 123,
  "uncompressedBytes": 456,
  "verifiedAt": "<UTC timestamp>",
  "indexedAt": "<UTC timestamp>"
}
```

The client must durably associate the receipt with the exact immutable upload job and
its source-row membership before permitting pruning. Match owner, canonical device,
object/batch/source IDs, stream, schema, decoded digest and both sizes. For opaque device
IDs, use the same owner-scoped `noopDeviceId` mapping as intake; never compare against an
unrelated current login/device. No bare ready flag, HTTP 2xx, or legacy ACK is a receipt.
Legacy repaired objects without batch/source metadata are retained until the original
intent retry binds those identifiers; clients must not accept null identifiers for a job.

Schema 1 remains readable; protocol 1.3 PPG implies schema 2 (an explicit `schemaVersion`
is optional, but must agree). Other streams retain schema 1. Protocol 1.0–1.2 negotiation
remains supported. Schema 2 identifies a `recordIndex`-preserving codec. The Edge
lane hashes and preserves the entire decoded payload without flattening records into a
timestamp-keyed table. The BLE producer and JVM replay reader must agree on codec v2 and
the explicit unknown-identity representation (presence byte 0, not an invented sequence).
Known PPG identity uses presence byte 1 followed by little-endian signed i64, after rowId/ts
and before the burstIndex presence byte. The receipt attests stored bytes, not physiological
validity or scorer completion. Signal-window sample counts remain client declarations.

The presigned staging key differs from the verified archive key. Completion snapshots
the upload, streams gzip/zstd decoding and both SHA-256 digests, checks both sizes, and
commits the receipt and signal index in one database transaction. Concurrent identical
completion selects one immutable snapshot and receipt. Index failure cannot publish a
receipt. Retries/reconcile reverify and repair existing ready rows and missing indexes.
The persistent reconcile cursor processes at most 16 objects per invocation, wrapping
at the end; failures are counted and revisited. It is not an all-backlog completion claim.

Research raw objects retain the existing indefinite research retention policy; auxiliary
diagnostics retain their existing short expiry policy. This receipt does not promise
retention beyond the stream policy. Snapshots orphaned by an ambiguous commit/crash are
retained conservatively; automatic orphan deletion is deliberately not guessed.

Native acceptance: `tests/intake_integration_test.ts` uses disposable local PostgreSQL,
real PostgREST with signed synthetic user-role JWTs, and a loopback HTTP object store.
No production URLs, credentials, data, or device are used. See `tests/local_postgres.ts`.
