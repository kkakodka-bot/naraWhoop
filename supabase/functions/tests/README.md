# Local intake gate

For a clean checkout or CI runner, start with
[`Tests/ServerFixtureNative/README.md`](../../../Tests/ServerFixtureNative/README.md).
Its exporter generates all three actual Swift fixture directories and documents the portable
tool setup and complete gate command. Historical paths below describe retained earlier evidence.

Run from `supabase/functions` in the integrated worktree. This creates a fresh synthetic
PostgreSQL cluster, starts PostgREST and an HTTP object fixture on loopback, applies the
listed **actual** prerequisite migrations plus scoring `20260918010000`, intake `020000`,
scoring review repairs `030000`, and projection debt `040000`, and stops its services.
The separate scalar integration fixture opts into actual `050000` plus additive `060000`;
the shared harness default remains through `040000` for root's Swift loopback runner.
The identity/provenance and actual Swift IMU fixtures opt into the entire chain through `070000`.
All fixtures also apply additive `20260922010000_object_copy_intents.sql`.
They now also apply `20260922020000_async_object_verification.sql`; absent explicit negotiation,
the object-completion endpoint retains its synchronous behavior.
It never accepts a production database URL, reads an env file, or invokes a device.
Cluster data, SQL/server logs and `receipt-example.json` remain on the external SSD.
The older failed bootstrap fixtures are retained as evidence too, not running services.

Verified tools: Deno 2.5.6 (pinned external npm package), PostgreSQL 18.3 and PostgREST 16.2
at `/opt/homebrew/bin`. This is not proof against the deployed Supabase/PostgreSQL version.
The dependency versions and integrity hashes are frozen in `../deno.lock`.

```sh
cd '/Volumes/Untitled/WHOOP NARA-production-sync-2026-09-18/supabase/functions'
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  EDGE_TEST_ARTIFACTS=/Volumes/Untitled/nara-production-sync-evidence-20260918 \
  DENO_DIR=/Volumes/Untitled/nara-production-sync-evidence-20260918/edge-tools/deno-cache \
  TMPDIR=/Volumes/Untitled/nara-production-sync-evidence-20260918/edge-tmp \
  /Volumes/Untitled/nara-production-sync-evidence-20260918/edge-tools/node_modules/@deno/darwin-arm64/deno \
  test --cached-only --frozen --lock=deno.lock --allow-env --allow-read \
  --allow-write=/Volumes/Untitled/nara-production-sync-evidence-20260918 \
  --allow-run=/opt/homebrew/bin/initdb,/opt/homebrew/bin/pg_ctl,/opt/homebrew/bin/psql,/opt/homebrew/bin/postgrest \
  --allow-net=127.0.0.1,localhost tests/
```

For an empty cache, first resolve the pinned dependencies with the same sanitized
environment using `deno cache --frozen --lock=deno.lock tests/*_test.ts push/index.ts
reconcile/index.ts ingest-verify/index.ts`. This dependency step uses public package
registries; the test execution above has no external network permission.

Entry-point type check (same sanitized DENO_DIR/TMPDIR environment):
`deno check --frozen --lock=deno.lock push/index.ts reconcile/index.ts ingest-verify/index.ts`.

## Evidence boundary

| Acceptance | Native evidence | Still external to this gate |
|---|---|---|
| W2 owner/device isolation | Signed synthetic authenticated/anon JWTs through real PostgREST; ownership trigger; reads, writes and RPC denials | Deployed Auth configuration and mobile account transitions |
| W3 intake idempotency | PostgreSQL reservation races and crash-before-ACK replay; permanent digest reservation; one logical projection | Other services' writers and full fleet load |
| W3.5 object durability | Real HTTP copy/GET; gzip/zstd decoding; both digests/sizes; SQL index-failure rollback; concurrent completion; retry repair | Actual B2 permissions, compatibility, latency and retention setup |
| W3.5 reconciliation | Persistent bounded cursor; legacy ready/missing-index repair without reupload; one-time legacy provenance binding | Deployment schedule, backlog drain rate, alerts and representative query plans |
| W3 P1-4 projection recovery | Real archive-to-projection fault; server-only replay; settled scoring snapshot invalidation; projection/invalidation/ACK/debt rollback; duplicate/lost-response and stale-lease fences; all 12 native stream mappings | JVM physiology calculation, deployed worker scheduling and fleet throughput |
| W1 raw identity | Exact NPB1 PPG v2 fixture has two same-second record indexes and an explicit unknown; archive bytes/digest unchanged; 1.3 negotiation | Swift/JVM cross-language golden-fixture and replay acceptance |
| W1 pruning / W5 transport | Receipt contract binds the exact object/job; legacy ready/HEAD is not a receipt | Native durable source-membership association, crash restoration and actual prune decisions |
| Security/observability | Genuine intake-role RLS; bounded zstd history/output; report fails for missing receipt/index; safe server error codes | Whole-repository security assurance, device signposts, performance, production monitoring |

`intake_integration_test.ts` is the native SQL/RLS proof. Existing server-score tests that
inspect SQL text are not counted as runtime RLS evidence. This fixture exercises real scoring
lease/publication RPCs and invalidation triggers, not a JVM scorer process. JVM tests, full
Swift suites, full deployment gates and device evidence remain root/other workstream ownership.
Do not infer release readiness from this gate alone.

Operational notes: raw completion now needs bucket **read and CopyObject** capability as
well as upload capability. Only staging keys are presigned; manifests/windows point to the
server-only verified key. Reconciliation processes 16 pending/repair objects per invocation
(SQL cap 64); its singleton cursor is fleet-wide and wraps. Confirm an adequate deployment
schedule. New COPY attempts have a durable reservation before object creation and a conservative
orphan sweep after 24 hours; legacy untracked snapshots are retained. PPG/IMU research retention remains indefinite;
auxiliary diagnostics retain the prior short retention policy. No receipt promises more.

## Immutable-copy recovery

Apply `20260922010000_object_copy_intents.sql` before the updated Edge code. Each attempt reserves a
random server-only key and a ten-minute publication lease before COPY. Verification still streams
the snapshot and checks both sizes/digests. Receipt/index publication and attempt settlement share
one PostgreSQL transaction. Staging remains mutable and is never reused as the verified key.

The authenticated worker's `copies` result is a bounded sweep of tracked attempts: default 16 rows,
512 MiB of declared candidate bytes, and ten seconds of admission time per invocation. An in-flight
storage request has its own 30-second timeout; this is not a hard ten-second wall-clock guarantee.
Attempts must be at least 24 hours old with expired publication/sweep leases. Claiming locks the
attempt and manifest and excludes either current manifest or exact receipt references. A claimed
attempt cannot publish afterward. Exact HEAD version IDs are used for DELETE because B2's ordinary
DELETE creates a hide marker and retains bytes. Missing version IDs or failed deletion retain debt.
Published snapshots and staging objects are never deleted by this worker.

Tombstones remain in the ledger and are rechecked daily so a very late COPY remains discoverable.
Deleting a manifest/account nulls its identity references while preserving the minimal key/attempt
cleanup record; detached attempts cannot publish a receipt. A maximum of 64
unswept attempts per object bounds repeated failed copies; reaching it returns a retryable 503 until
maintenance clears debt. Lost commit responses and duplicate completion return the existing exact
receipt. This does not retrofit unknown historical snapshot keys or certify production B2 permissions,
object-lock policy, physical byte reclamation, sweep scheduling, fleet throughput, or orphan drain.

`noop_copy_intake_metrics` and `noop_projection_metrics` are service-only aggregate views; the
worker response includes counts, oldest intake debt, candidate bytes, attempt counts, verification
and receipt timing, and projection debt. Candidate byte counts are ledger estimates, not a physical
bucket census. No owner/device identifiers or health values are exposed in these metrics.

`copy_intents_integration_test.ts` uses real PostgreSQL/PostgREST and loopback signed object HTTP
for reservation-before-COPY failure, both COPY crash boundaries, expired publisher rejection,
lost committed responses, racing completions, current-key preservation, stale sweep tokens,
late-COPY tombstones after account/manifest deletion, version races between HEAD and DELETE,
row/byte/admission budgets, missing version IDs, and account-role RPC denials.
These synthetic process-boundary failures do not simulate a B2 outage or machine power loss.

## Opt-in asynchronous object verification

Apply `20260922020000_async_object_verification.sql` before this Edge code. Capability advertisement is off
unless `NOOP_ASYNC_OBJECT_VERIFICATION=1`; enable only after an authenticated reconcile worker
schedule is configured. Capability `objectLane.completionModes` then advertises `sync` and
`async-v1`. An authenticated completion must also send `Noop-Push-Completion: async-v1`.
Missing/unknown mode retains synchronous completion for an object that never opted in. Once
verification debt exists it is authoritative even if a later client drops or changes the header;
terminal pauses and worker leases cannot be bypassed by a mode downgrade. Disabling capability
advertisement later does not change already-negotiated jobs: explicit async-v1 requests remain
valid so persisted polls cannot silently become synchronous verification.
No upload encoding or version-1 durability receipt fields change.

The opted-in POST `/objects/:id/complete` durably enqueues verification, then serves as its own
poll endpoint. Pending returns HTTP 503 with numeric `Retry-After` and the typed error code
`verification_pending`, state `pending_verification`, manifest protocol version and object ID.
It performs no object HEAD/COPY/GET/decode/hash. A pending response is never a source release.
Once verified, polling returns the original exact `objectAck` only if current owner, manifest
identity/digests/sizes, immutable object key and committed index agree. Repeated polling does
not verify the object again. Missing index becomes bounded repair debt; an unverified or
mismatched record cannot masquerade as a completed receipt. Cached fields also require correct
JSON types, canonical UUIDs, hashes, positive sizes and valid ordered ISO timestamps. Malformed
receipt state pauses as `receipt_mismatch`; a missing index alone remains repairable.

`reconcile` processes four serial claims by default (hard row cap 16), with at most 256 MiB of
declared compressed bytes and 512 MiB of declared decoded bytes per invocation, matching the
existing maximum single-object contract. These are server ceilings, not recommended phone
job sizes or a throughput measurement. Claims stop after ten seconds of admission time; the
worker rechecks after database awaits and releases an unused claim without recording failure.
An in-flight HEAD can take 30 seconds, COPY/streamed GET 120 seconds each; PostgreSQL/network
awaits and decoding also consume wall time. **This is not a hard ten-second execution limit.**
Leases last ten minutes and expire across worker termination. No SQL lock spans storage I/O.
A lost commit response is healed from the exact receipt; duplicate/stale settlement cannot
increment failure counts twice or overwrite a successor's lease. The legacy intake cursor
excludes all async debt, including terminal pauses; previously admitted legacy work may finish
using the existing copy-intent/receipt concurrency fences. A manifest-locked copy-reservation
wrapper requires the current async lease token after opt-in; its previous implementation is
private and denied even to direct service-role calls. Async claims wait for any live COPY
admitted before opt-in, closing the lookup/enqueue race without holding locks during I/O.

Transient failures use persisted full-jitter backoff; terminal manifest/byte validation failures
remain `paused_terminal`. Polling returns the recorded typed terminal HTTP outcome and retains
source/objects. Explicit service-only `noop_retry_object_verification(user,object)` may requeue
only a paused row after a compatible fix or operator resolution. A phone's local Retry button
alone cannot resolve server terminal debt. This RPC is not exposed as an unauthenticated or
ordinary-user reset endpoint. Existing copy-intent tombstones survive account/manifest removal;
verification debt itself may cascade because it no longer has authority to publish.

`noop_object_verification_metrics` adds queue depth/oldest debt, retry/terminal counts, active
and expired leases, verification duration and requested-to-receipt-index latency. Receipt timing
uses the original indexed timestamp, not a later poll or lost-response recovery time. Prior
receipt repair cannot produce a negative latency. Metrics contain no owner/device/object IDs
or health values. Deployed schedule, monitoring, production B2 behavior, fleet drain rate and
phone-to-receipt/energy improvements remain `NOT_MEASURED`.

`object_verification_integration_test.ts` exercises actual additive SQL and role denials,
HTTP response negotiation, no-I/O enqueue/polls, concurrent claims, crash/response boundaries,
lease recovery, exact cached receipts, index repair, terminal resolution, worker row/byte/time
admission bounds, and deletion with delayed COPY. The fixture uses real local PostgreSQL,
PostgREST and loopback signed-object HTTP. It does not deploy or certify server scheduling. Duplicate **intent** requests still use the
existing synchronous verification branch when a receipt already exists; the no-repeat-I/O
claim applies to persisted completion polling, not every control-plane request.

## Projection recovery contract (P1-4)

Apply additive `20260918040000_production_projection_debt.sql` before the updated Edge code.
The existing `020000` migration and receipt JSON are unchanged. A `verified_indexed` receipt
attests the immutable archive and index, **not completed scoring**. The archive transaction
now also persists projection debt for inline NDJSON; it excludes binary object-lane payloads.

- Both live intake and server reconciliation use `commitArchivedBatch` and the same mappers.
  Reconciliation reads the verified key, checks both sizes/digests while decompressing, and
  calls service-only `noop_commit_push_projection`. No phone resubmission is needed.
- Projection upsert/deletion, affected scoring invalidations, ACK, WAL trimming and debt
  completion commit in one PostgreSQL transaction. A lost response reuses the saved ACK;
  completed debt is retained to prevent duplicate projection or extra invalidation.
- `pending` debt is eligible for replay. `staged` replacement parts have durable mapped rows
  and wait for the remaining parts; only a complete generation applies its window atomically.
  Completed-window ordering records preserve newer corrections and deletions during delayed
  overlapping replay. Append correction ordering uses immutable reservation time. Multipart
  generations use their earliest reservation time, with replacement ID breaking timestamp ties.
- Each invocation scans/claims at most 16 objects by default (hard cap 64), one leased object
  at a time. Leases expire after two minutes; failures retry with capped exponential backoff.
  Decoded inline archives are capped at 4 MiB + 64 KiB. Replacement generations cap at 128
  parts and 32 MiB of staged JSON rows. These bounds are not a fleet latency guarantee.
- A resumable cursor discovers older indexed manifests missing debt. Existing ACKs are
  treated as settled except unfinished legacy staging parts. This does not reconstruct
  historical replacement tombstones from already-settled pre-040000 ACKs. Missing immutable
  legacy provenance/reservations fail closed and need a separate upgrade decision.
- Retention holds NDJSON archives with pending/staged/missing debt. Service-only
  `noop_projection_metrics` exposes backlog, active leases, backoff and oldest debt age;
  ingest-verify reports `projection_debt` until the corresponding ledger entry is complete.

Native tests also inject invalidation failure, corrupt a verified HTTP object, reclaim an
expired lease, simulate a lost committed response, finish a multipart generation using only
server replay, preserve newer overlapping windows, hold retention, and deny real authenticated
  and anonymous roles access to debt, ordering records, metrics and settlement RPCs.

## Three existing scalar streams (060000)

`scalar_integration_test.ts` exercises step counter/activity class, raw sleep-band state/byte,
and derived PPG-HR/confidence against their real tables, PostgREST owner roles and loopback
object storage. These streams are offered at 1.1 and later, never 1.0. Optional absent values
remain NULL. Invalid numeric types/ranges and inconsistent band state/raw-byte pairs fail
before reservation or archive writes. These are not clinical sleep stages or measured HR.

Unlike the original append streams' correction policy, the three scalar timestamp keys are
measurement-immutable: changed values fail with `scalar_identity_conflict` (409), retain the
original projection and both archives, and leave pending projection debt without an ACK.
Bounded replay defers such conflicts; it does not silently pick the later sample. Exact
duplicates, concurrent settlement and lost responses do not reinvalidate settled scores.
The native fixture deliberately retains three conflict debts as evidence, not a zero-backlog claim.

## Receiver1.4 support (070000), not yet advertised

Apply additive070 before the updated receiver. The supported schema map matches root's sender:
PPG schema2 at1.3/1.4; auxiliary and three scalars schema2 at1.4; other cases schema1.
Negotiation still tops out at1.3 pending the cross-stack golden approval. Known provenance is
rejected below1.4 rather than stripped. Legacy absent/null provenance remains unknown.
Strict scalar JSONB validation matches producer fields/types/origin-specific shape and bounds;
the archive keeps exact submitted bytes and atomic projection replay preserves the metadata.

Auxiliary1.4 verification streams NPB1format2/kind2 with at most64KiB parser buffering. It
checks count, half-open bounds, strict presence flag, u32-domain i64 index and complete known
fields-blob identity. Unsupported fields retain exact bytes with `noop_aux_object_validation`
pending debt, in the same transaction as receipt/index. No guessed identity or candidate
physiology is produced. Pending/missing validation holds automatic retention. `ingest-verify`
reports `auxiliary_validation`; validated framing is not scorer completion. A future decoder
upgrade/typed-debt settlement policy remains separate from this receipt contract.

Full native suite additionally requires root's synthetic exports under EDGE_TEST_ARTIFACTS:
`aux14-swift/{payload.npb1,payload.gz,golden.json}`,
`aux14-swift-intake-v1/{manifest.json,payload.npb1,payload.gz,golden.json}` and
`imf1-swift-native-v1/{fixture.json,session/*,continuous/*}`. Missing exports fail the suite;
they are never silently replaced with a hand-built sender fixture. Export recipes/evidence are
in `root-push-aux14-golden.log` and `W5-IMF1-SWIFT-FIXTURE-HANDOFF.md`.
The original auxiliary golden uses ts100 and proves parser/fingerprint parity. The separate
actual Swift intake export uses ts1800000000 and runs unchanged through the entire070 PG/HTTP
intake, transactional fault rollback, server-only reconciliation and duplicate/owner-role gates
in `swift_auxiliary_integration_test.ts`. The original golden is untouched. Actual Swift IMU intake runs unchanged
except adding measured compressedBytes, just as the direct-lane sender does.

`swift_imf1_integration_test.ts` decodes recovered bytes only for verification. Production
rawBatch remains opaque, retains the two framed descriptor/file members, and indexes received
members2 with expected/missing/coverage NULL. It does not pretend these are two BLE samples.
Those native results do not alone authorize pruning: W5 exact owner/file/member/source-commit
and cleanup gates still apply. No OS power-loss, device, real B2 or deployment claim follows.

## Scout handoff outside Edge ownership

- Android remains blocked by the absent SDK in checked standard/external locations and by
  `ImuSessionFileStore.kt:20` exposing only a one-argument constructor while
  `ImuContinuousRecorder.kt:725` expects a namespace; `registeredWindows()` and
  `NAMESPACE_CONTINUOUS` are missing. The signed FNV literal at `ImuSessionFileStore.kt:318`
  also needs a bounded unsigned-to-Long fix. Meaningful native proof is compilation plus
  isolated IMU persistence/restart/prune and multi-window tests, not a source-string check.
- Native Java is installed at `/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`;
  Gradle 8.7 is cached in the user wrapper distribution. Do not start the broad phase3 script
  in a secrets-free scout: it sources environment files and has remote branches. Root owns
  gate script changes and integration.
- Swift 6.2.4 / Xcode 26.3 is at `/Volumes/External SSD/Xcode.app/Contents/Developer`.
  Root owns WhoopStore/WhoopProtocol suites; this work did not duplicate them. Native NoopPush
  receipt/identity tests belong with BLE/transport integration, using an external scratch path.
- During concurrent work, root corrected the phase3 local-skip outcome and the JVM fake-HTTP
  test isolation. Initial scout findings about those files must not be treated as current defects.
