# Persistent sync follow-up: release blocked

This candidate continues PR #22 from freshly fetched head
`97704bdf8e4ab802083070d8d45664ade51c1f6c`. The original audited head was
`2f26b62ae685ddbcec4c539f7c5d806ce72f60cf`. The intervening commits already supplied
the connection owner, finite commit assertion, ordinary atomic chunk commit, typed
transfer outcomes, and initial resource admission. Those implementations were
reviewed in place. PR #21 was not merged. The original dirty checkout and the
older unfinished worktree were preserved.

The six audit areas were connection/restoration, notification/history transport,
local durability, cloud transport, server receipts, and failure/physical testing.
BLEManager, Backfiller and upload state machines each had one implementation
owner after the read-only audit. This document supersedes the implementation-gap
list in `persistent-sync-candidate-2026-09-19.md`; that report remains historical
evidence for its own candidate.

## Changes

All WHOOP connection requests and GATT effects now use the same production
transport adapter that deterministic tests drive. Core Bluetooth reconnecting
callbacks do not start a competing request. Restoration reads only the approved
account/device row before attaching. An already-disconnecting restored peripheral
immediately receives a fenced OS-owned standing request. A finite setup assertion
and 20-second monotonic deadline cover discovery, bonding and notification setup;
missing callbacks enter the same bounded reconnect flow as explicit failures.
The request is submitted immediately with an OS start delay, so an app timer is
not responsible for reconnecting after suspension. Shutdown, intentional disconnect
and changed device intent revoke the temporary restoration approval.

This owner covers every WHOOP proprietary history connection. Oura, generic heart
rate, Huami and FTMS retain their independent source controllers; they cannot start
WHOOP history through those paths. Literal consolidation of every non-WHOOP
`central.connect` call in the app is outside this implementation and is not claimed.

Notification readiness now belongs to a generation-specific subscription
controller. A restored cached ON flag completes OFF and then a positively
confirmed ON callback before authorizing history. Duplicate and out-of-order
callbacks cannot skip that sequence. The realtime intent controller releases
both supported WHOOP 4 producers off-wrist, records ATT completion separately
from submission, retries failed stops within a bound, and preserves the current
screen/continuous intent. Eligible cadence refreshes remain possible without
recreating intent that was closed off-wrist.

Historical rows, dirty/debt entries, rejected evidence, optional raw metadata and
cursor now share one FULL SQLite transaction. External IMU segments are flushed
before that authorization. Missing or failed IMU persistence fails closed. Empty
chunks validate account ownership too. FIFO age/depth is published synchronously;
phase samples include FIFO delay and receipt-to-ACK submission. Manager-level
lease tests cover expiration before authorization, late ATT completion, disconnect
and overlapping exact-once cleanup.

The shared budget now includes FIFO pressure, lifecycle opportunities/deadlines,
storage, network and queued cloud bytes/jobs. Background grants are revoked on
completion/expiration. Capture maintenance, startup projections and cloud lanes
check admission before optional work and between scoring, projection and archive pages.
Automatic timestamp healing cannot delete canonical capture rows in an account runtime;
unresolved legacy timestamps remain retained rather than being silently purged. The obsolete production `onBankedOffload`
worker hook is inert; durable debt and the active chunk completion path own work.

Initial capability and object-intent responses join the persistent typed retry
ledger. Terminal failures stay visible until explicit resolution; authentication
refresh has one recorded allowance per applicable request. Exact validated
receipts alone settle source state. The UI exposes resolution and the last known
verified receipt, with an unknown marker for older unrecorded receipt history.

Account-scoped SQLite replaces repeated JSON metadata rewrites. Immutable spool
segments hold prepared bytes, while compact metadata and membership references
remain in SQLite. Legacy evidence remains intact; an authority marker prevents
its resurrection. Preparation and retirement intents cover file/database crash
windows. Recovery retains at most one decoded selection. See
`cloud-metadata-spool-migration-2026-09-22.md` for migration boundaries.

The v56 source transaction records coalesced revisions for mutable daily, journal,
sleep and workout rows. Insertions, corrections, key changes and deletions update
both the journal and cloud debt atomically. Deletion markers retain their original
identity through local data deletion and serial adoption. A fresh revision counter
cannot claim account ownership; unassigned source/deletion metadata still blocks
binding. The journal contains no cloud durability authority.

Mutable preparation now pages that journal by the exact revision/key tuple, including
old dates and empty deletion replacements. Only a matching indexed receipt advances
the captured tuple. Fresh replacements have a separate operation identity, so an
A-to-B-to-A change cannot reuse A's earlier receipt while the receiver still holds B.
Prepared retries retain their original operation and bytes. Calendar-rule changes
restart the bounded baseline and replay.
The v58 membership index replaces broad SQL device discovery; existing stores migrate
in committed pages of at most 2,000 row identities. Device rotation and outstanding
work from earlier devices share one account-scoped SQLite checkpoint, bound to the
ordered device-list fingerprint. A changed list restarts the cycle from its beginning.

The iOS and macOS encoder now uses vendored, pinned Zstandard 1.5.7, with independent
Deno golden decoding and the existing wire contract. Host benchmarks compare levels
1 and 3; level 1 is selected. They do not establish iPhone energy or thermal cost.
Workers share row, byte, request and monotonic duration budgets across lanes.
Fresh binary selections stream serialization, compression and both digests into
immutable files in 64-KiB slices. New local selection metadata references those
files without retaining decoded/compressed/base64 copies. The local format is
versioned separately; saved legacy payloads retain their exact bytes and identities.
Fresh streamed object identities include the wire digest and encoding, so an older
compression representation cannot conflict with a fresh object or supply its receipt.
Decoded batch identity remains stable. Fresh jobs are capped at 2,000 rows and
4 MiB decoded; bounded lookahead may inspect one additional source row.

Server copy intents are leased and survive account deletion. A conservative,
bounded sweeper handles copy/index crash windows; exact receipts and publication
remain transactional. Aggregate SQL metrics expose copy debt, age, retries,
verification/index duration, orphan candidates and receipt latency. No migration
or server function was deployed to production during this work.

Negotiated `async-v1` completion records durable verification debt and returns a
typed pending response with Retry-After. Bounded workers lease verification and
indexing; polling returns only the exact indexed receipt. Existing debt cannot be
downgraded into synchronous completion by dropping the negotiation header. Terminal
debt requires an explicit service-side retry after resolution. Capability
advertisement is off by default; rollout and worker scheduling remain unverified.

The local intake benchmark used 30 measured repetitions for each of six cases,
plus 18 warmups. Median intent/upload/receipt time was 20.99, 24.42 and 41.77 ms
for approximately 64 KiB, 1 MiB and 4 MiB decoded synthetic binary objects, and
43.54, 83.46 and 125.31 ms for 50, 500 and 2,000 inline rows. PostgreSQL and the
receipt/index transactions were real; object storage was a loopback RAM fixture.
These are diagnostic host measurements, not phone/B2 latency or an isolated
before/after baseline. See `Tests/ServerIntakeBench/README.md` for phase boundaries.

## Reproducible checks

Use private artifact directories. Test fixtures are synthetic. Do not publish
runtime databases, credentials, account/device identifiers or health values.

```sh
zsh Tests/PersistentSyncNative/run.sh /private/artifacts/persistent
zsh Tests/BLETransportNative/run.sh /private/artifacts/transport
zsh Tests/CloudUploadNative/run.sh /private/artifacts
zsh Tests/SyncPresentationNative/run.sh /private/artifacts
zsh Tests/HistoricalChunkNative/run.sh /private/artifacts 10000
swift test --package-path Packages/WhoopStore
swift test --package-path Packages/NoopPush
```

The [server fixture instructions](../Tests/ServerFixtureNative/README.md) export
current Swift payloads before running the disposable database and receiver suite.
The server integrity workflow uses that same exporter and frozen dependencies.

The persistent-sync workflow also runs hosted manager/FIFO/commit/cloud tests,
IMU tests, and an unsigned iOS Release build. A native transport test replaces the
radio boundary; it is not an iOS daemon or physical strap test. The crash harness
kills actual processes around real WhoopStore commits and reopens SQLite, but its
ACK, ATT and cloud events are scripted. SQLite-full injection is not a physical
full-filesystem or power-loss experiment.

The complete hosted app suite additionally requires the actual JVM populated-context
fixture. App-build CI runs `PopulatedContextSnapshotFixtureIntegrationTest` against
a new disposable PostgreSQL cluster, then `Tests/ServerScoreContextNative/run-hosted.sh`
binds that file into the generated XCTest run environment. Missing fixtures fail;
the interoperability tests are not skipped. Full-suite repairs retain cloud debt
separately from widget work, validate checksummed IMU fixtures, and assert account
retirement after deferred maintenance. A calendar-date caption bug found by this
suite is fixed without changing the local 04:00 logical-day boundary.

`Tools/SyncAcceptance/manifest.py` records the candidate SHA/build, allowlisted XCTest
counts and environments, evidence hashes, and a complete physical matrix initialized
to `NOT_MEASURED`. It omits hardware identifiers and failure-message contents. The
CI workflow uploads this sanitized manifest, never the raw result bundle.

The ordinary package CI uses a current Apple Git and full repository history for
Analytics provenance checks. The previous runner rejected `--no-lazy-fetch` and
its shallow checkout lacked pinned historical blobs. Source inventories and
provenance assertions are unchanged. Localization coverage failures are repaired
in the catalogs; the baseline was not regenerated to suppress findings.

Every final test/build result must identify its source SHA or source fingerprints.
Earlier working-tree runs do not become exact-head Release or CI evidence merely
because a later commit contains similar code. The machine-readable run manifest
records those distinctions, missing samples and the physical matrix explicitly.

## Remaining implementation and release gates

| Area | Remaining requirement |
|---|---|
| Connection timing | Physical callback-to-standing-request p99, discovery/readiness duration, and absent-callback recovery under actual suspension. Callback provenance limitations of reused native objects still require genuine restoration testing. |
| Required notification profile | The authoritative WHOOP 5 profile is retained. No physical captures establish a smaller mandatory set or prove every firmware variant. |
| Critical path | Full matched callback/FIFO/decode/transaction-wait/commit/cursor/ACK/ATT/next-chunk traces, on-device fsync counts, and main-actor contention decision. |
| Thermal policy | Two-second admission response and every active worker's physical CPU/energy behavior. Already-running synchronous work is not preempted by a policy check. |
| Streaming | Fresh binary preparation streams from a bounded source selection. Physical peak RSS and energy remain unmeasured; the compatibility reader can still materialize one large legacy selection, so legacy migration/replay must be included in memory acceptance. |
| Selection indexing | Mutable revision/key paging and bounded SQL membership bootstrap replace repeated source discovery and rolling-window scans. Legacy file-backed IMU discovery still inventories retained file metadata; that discovery cost needs measurement and a compact device index if material. |
| Legacy timestamps | Automatic destructive timestamp healing is disabled for account capture. A lossless quarantine/projection repair for legacy bad-clock rows remains unfinished. |
| Server phases | Opt-in asynchronous verification/index debt and exact receipt polling pass disposable PostgreSQL integration tests. Production profiling, deployment, metrics, worker and sweeper scheduling are unverified. In-flight storage requests retain their own timeout beyond the between-job admission budget. |
| UI | Devices and Test Centre share separate strap and cloud state, ATT-confirmed chunk count, pressure/error pauses and independent sync dates. A defensible remaining-backlog-age estimate still requires a clock-aligned frontier/range source; the UI displays an unknown marker instead. Rendered device/localization/accessibility acceptance is unmeasured. |
| Stress scope | A hosted test interleaves 10,000 real FIFO/chunk commits with the durable cloud queue, duplicate/out-of-order scripted callbacks and pressure changes. Real radio, daemon, network and locked-phone chaos remain unmeasured. |
| Physical evidence | Every requested cell/scenario, Instruments traces, MetricKit summaries, matched memory/battery/throughput, genuine restoration and production-server account isolation remains `NOT_MEASURED`. |

Required physical scenarios remain: two hours locked; three independent 12-hour
runs per supported phone/strap cell; 30 range-return cycles; ten minutes Bluetooth
off then locked recovery; discovery/subscription/commit/ACK interruption; genuine
iOS termination/restoration; two hours offline with BLE continuing; network and
credential/URL transitions; Low Power Mode and thermal pressure; reboot/first
unlock; force-quit negative control; and a 72-hour soak. The oldest supported
phone/iOS cell and current-public-iOS cell must both be identified in the manifest.

All numerical release gates remain `NOT_MEASURED` until matched physical evidence
exists: ACK integrity, wrong-account delivery, exact receipts, replay duplicates,
1-second reconnect p99, 20-second readiness, 500-ms ACK p99/no app sample above
2 seconds, one ordinary durability commit, cloud impact at most 20%, throughput
and 120-second progress gaps, thermal response, jetsam/EXC_RESOURCE, 75-MiB memory
delta/250-MiB peak and 10% battery regression. A passing synthetic integrity test
supports only its tested invariant and environment, not those release claims.

## Platform limits

Core Bluetooth offers event-driven wakes and pending requests, not indefinite
background execution. Ordinary recovery is not promised after user force-quit.
Protected account storage can be unavailable before first unlock after reboot.
Background URLSession and BGTask scheduling are discretionary; OS scheduling
latency must be reported separately from app-controlled latency. No candidate was
installed on a physical phone as part of this follow-up, and no phone database was
reset, truncated or replaced.

**Disposition: NOT_READY.** The implementation and local evidence are reviewable;
missing implementation and physical acceptance are not waived.
