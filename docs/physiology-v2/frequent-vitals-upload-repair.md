# Frequent-vitals upload and persistence repair

Local source: checkpoint `5c16cbe` plus this repair. No phone/server data was modified or deployment performed.

## Confirmed upload defect

The copied build-348 Apple database passes SQLite `quick_check`. `CloudPushSnapshot` selected
`workout.routePolyline`, an Android-only column absent from the migrated Apple schema. SQLite
raises `no such column: routePolyline` even when there are no workouts. This explains the permanent
`localDatabase` upload-cycle error. Other streams can still upload because the coordinator continues
after a table failure; this defect alone does not prove the cause of all server freshness lag.

The snapshot now exports explicit null only for this unsupported optional field, preserves an
existing route column, and continues to fail on missing required columns. All existing RR packet
and PPG identity export queries succeeded against the captured schema. Private diagnostic data
remains outside the repository.

## Added receipt lane

`standardHRReceipt` retains original standard BLE notifications by connection session and ordinal.
Equal notifications in the same second remain distinct. Raw bytes and host arrival clocks cross
Swift/Android export, the capability registry, B2 archive and an owner-scoped PostgreSQL table.
Nanoseconds use decimal strings in JSON to avoid numeric precision loss. An identical replay is
accepted; conflicting evidence under the same receipt identity is rejected without overwriting
the first receipt. These clocks remain `host-arrival-unmapped`; they do not prove beat continuity.

Migration `20260918190000` exposes `heart_rate_windows` from the HRV-selected device/version and
rejects nested windows with another owner/device. It preserves the inherited v2 selection policy;
the earlier `20260918130000` promotion is not reference-validation evidence.

## Revision safety and remaining liveness issue

The inherited `20260918150000` kept input revisions unchanged during a running lease, allowing
older-input publication to pass revision checks after new data committed. Migration
`20260918200000` restores audited revision fencing and revokes already-dirtied coalesced claims.
Tests weakened by the earlier coalescing change are restored to their audited assertions.

Correct fencing does not establish publication throughput. A deterministic PostgreSQL counterexample
with one new receipt during each of 20 claimed runs has 20 claims, zero completions and pending work.
It fails safely, but continuous-arrival liveness still needs an engineering pass using a defined input
snapshot/ingestion schedule. Do not claim a five-minute server publication guarantee.

## Verification

* NoopPush: 31 tests passed.
* Production snapshot source in an isolated Swift harness: 6 tests passed, including a read-only
  query of the copied phone database, all migrated export queries, optional route preservation,
  and exact nanosecond serialization. This is not a full app or device run.
* Full Edge suite with type checking: 73 tests passed. The inherited mock RPC return-type inference
  was corrected without changing assertions.
* Disposable PostgreSQL migration/integration harness: 88 tests passed, zero failures/skips,
  including RLS, composite owner/device constraints, immutable receipt upserts, late-input fences,
  preexisting-claim migration, independent workers and selected-device readback.
* Clean checkpoint `5c16cbe`: 81 PostgreSQL tests ran with nine failures, establishing the inherited
  failures before repair. The repaired tests explicitly select v1 when testing baseline isolation.
* Android, full app build, device upload, VPS throughput and physiological reference validation
  are separate integration/release checks; these results do not establish them.

Logs are under `/Volumes/Untitled/physiology-build/frequent-vitals-*-tests.log`; final disposable
PostgreSQL evidence is `/Volumes/Untitled/physiology-audit/tmp/physiology-queue.8zQxAP`.
