# Shared repair base

The merge containing this document retains both complete histories:

- Integration: `e499162b4a0ce340b564e0232af14b5af355d6f1`, executable source `33a38c5167afec5beeadd700be714e89fa25fb57`.
- PR22: `a972493212f2eae29f01ecaddf9182260153400f`, all 46 divergent follow-ups.
- Original common ancestor: `97704bdf8e4ab802083070d8d45664ade51c1f6c`.

The repair merge SHA is recorded externally in `/Volumes/Untitled/server-repair-evidence/common-base.json` after commit. The BLE repair branch must start at that SHA. Do not use either parent or the frozen release artifact as an interchangeable repair build.

## Preserved interface

1. Phone capture, protocol decoding, original timestamps/units/provenance, direct device observations, durable buffering and upload/retry remain native. Final-hosted physiological calls remain retired and instrumented. Server outages never reactivate local inference.
2. Local durable commit precedes BLE ACK. Cloud release requires the exact owner/source/device/stream/batch/digest verified-indexed receipt; pending verification never permits pruning. Raw/index acceptance does not certify canonical projection or physiological input qualification.
3. Enrollment and account identity remain independently authorized. Physical source and canonical device identity stay distinct. Retirement, generation and current-destination fences survive callbacks, retries, cached reads and publication.
4. Immutable wire representation, SQLite upload debt, source membership/mutable revisions, bounded FIFO and deferred maintenance from PR22 are retained. Slow IMU indexing cannot block authorized scalar capture.
5. SQL/API/native publication keeps metric-level ownership, genuine qualification, immutable input/result revisions and missingness. Existing baseline mathematics and identity remain frozen. Shadow/history models are not selected by this merge.
6. Async verification remains off by default. Its six-hour maintenance caller is not a live consumer. New async rollout requires compatible phone, schema, Edge and continuously serviced verifier evidence; existing debt must remain recoverable.
7. Preserve all applied migration basenames and hashes. The combined base contains 126 source identities; later repair migrations must extend the manifest and rerun fresh/populated/actual-predecessor compatibility checks.
8. Ingestion cannot wait behind heavy inference. Future changes retain bounded input snapshots, lease/owner/revision fences and immutable publication.

## Ownership for subsequent edits

BLE work owns transport scheduling, finite execution-grant admission, scalar flush deadlines, acquisition lifecycle and physical continuity. Server work owns projection/verifier service, producer queues, scientific adapters, immutable results and native result consumption. Coordinate changes to `BLEManager`, `Collector`, `CloudPushWorker`, `CloudUploadQueue`, shared registry/receipts, SQL/API DTOs and ownership gates before editing the same file.

## Evidence and remaining limits

Independent release, upload, acquisition/native and Edge reviewers inspected actual source. Release artifact hashes verify the old frozen release, not a newly built repair. The base checks include NoopPush 141, store/migration 85, native cloud 84, BLE transport 47, deployment contract 12, and fresh/populated/hosted-predecessor 126-migration chains. Exact logs are hashed in `stage0-receipts.json`. App-linked compilation, final producer repair and physical acceptance remain outstanding.

`04_VPS_ALGORITHMS_SPEC.md` and `01_EVIDENCE_AND_DIAGNOSIS.md` were read from Downloads. At the time of this record, the user-named `FRWHOOP_Recovery_Pack/02_SHARED_CONTRACT.md` and `evidence/{server,algorithms,lineage}.md` were not present at the supplied location. This document records the interface preserved from the available specification and actual source; it does not claim to replace or have reviewed those missing files. Reconcile them when the pack is available.

No production migration, deployment, model promotion, phone installation/reset or main merge is authorized by this base.
