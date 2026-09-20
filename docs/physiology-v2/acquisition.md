# Acquisition and provenance contract

Scope: exact baseline `5caa31689da0023e111beb36850d3f81d67e1be2`, with the specific PR15 PPG identity repair adapted to preserve baseline migrations v46 and v47. No BLE commands, acquisition schedules, syncing branch, or device databases were changed.

## Local identity and schema compatibility

GRDB `v48-ppg-record-identity` and Room `39 -> 40` widen PPG identity to `(deviceId, ts, recordIndex)`. The migration retains sample bytes, burst index and SQLite rowids, because raw upload cursors use rowids. Existing legacy rows receive `recordIndex = -1`, meaning unknown. An already widened research schema is adopted after its primary key is checked. Unknown counter identities are never fabricated. Records already lost by an older `(deviceId, ts)` key cannot be recovered from that table; recovery requires original retained packet archives.

PPG no longer consults a timestamp-only backfill frontier. Distinct counters within one second therefore survive, including out-of-order arrivals. Duplicate identity replay retains the first raw record. The original RR v46 source index and v47 server cache remain in the migration chain. The schema and cloud-destination oracles also now cover the baseline server cache that was previously missing from both fixtures.

## Raw PPG archive format

The transport envelope remains the existing object-lane contract and gzip encoding. The decompressed binary header retains magic `NPB1`, followed by a one-byte format version and kind `1` (PPG). Legacy rows without any known counter retain byte-identical version 1 encoding. An object containing a known counter uses version 2 for every row:

```
header: magic[4], version:u8=2, kind:u8=1, recordCount:u32le
row: rowId:i64le, ts:i64le, hasBurst:u8, [burstIndex:i32le],
     recordIndex:i64le, sampleByteLength:u32le, sampleBytes
```

`recordIndex` is the decoded unsigned 32-bit wire counter represented in 64 bits; `-1` is the only unknown sentinel. New decoders accept versions 1 and 2, reject invalid ranges, truncation, trailing bytes and oversized records. Version 1 decode returns no record identity. Neither version supplies an optical wavelength, verified sample rate, clock mapping or inferred beat times. A future archive consumer must examine the binary header, not treat the historical `bin_gzip_noop_push_v1` container label as the payload version.

Cursor fingerprints include a known record index. Old nil-index fingerprints remain unchanged. Swift and Kotlin tests use byte-identical `ppg_identity_binary_oracle.json` including a same-second pair, the largest u32 counter and a mixed unknown identity. The bundled macOS zstd library now backs raw IMU/batch compression; the prior macOS path supplied an unsupported numeric algorithm to Apple's Compression API. The iOS Compression fallback still needs an actual supported-device check.

## Server RR source and timing

Policy `whoop-canonical-rr-1` matches the native requested-range policy. WHOOP5 uses only channel 5 (historical), or channel 7 (standard BLE) when no nonsuspect historical row exists in the requested range. It never splices those transports. Channel 6 native realtime, unlabelled legacy, unknown transports and `tsSuspect = 1` are unavailable for WHOOP5 scoring. WHOOP4 retains its original millisecond contract; the redundant Oura SpO2 IBI channel 2 is excluded as on the native reader. Equal-valued intervals remain separate observations. There is no legacy unit conversion.

The receiver retains null RR metadata as null rather than coercing it to numeric zero. Server inputs retain `ts`, `rrMs`, `seq`, `ord`, `srcChannel`, `tsSuspect`, the current device-catalog firmware when registered, the source policy version and timestamp precision of one second. Day ownership and context reads use persisted historical timezone segments, including disjoint travel-day intervals; today's profile timezone does not replace that historical ownership. The queued IANA timezone remains a compatibility bound. Steps have an additive receiver projection and reader input; their existing counter semantics are unchanged.

`seq` is occurrence identity assigned during insertion; `ord` is emission order within a stored second. The legacy RR primary key is numerical-value based, and sources can be promoted on collisions. These fields are NOT evidence of three consecutive original beats. Legacy-only inputs retain `packet_identity_not_projected` and `continuity_unverified`; no migration manufactures original identities from those values.

### Additive checked-packet lane

GRDB `v50-rr-packet-provenance`, Room `40 -> 41`, and PostgreSQL `20260918040000_rr_packet_provenance.sql` add companion records without rewriting legacy RR rows. The actual WHOOP5 v18 extraction path retains a CRC-checked full frame even when diagnostic field collection is disabled. `packetId` is SHA-256 of the immutable sensor record, excluding the replay-varying outer transport envelope and CRC. Receipts retain full bytes, original sensor second, mapped second, record counter, declared count, decoder/clock versions and mapping uncertainty. Original word indices include zero words; rejected zero endpoints cannot create an adjacency pair across the gap. WHOOP4 and standard BLE remain separate sources.

Native append snapshots export `rrPacketProvenance` with protocol 1.1 and schema version 1; protocol 1.0 is unchanged. Native stores deduplicate by `(deviceId, packetId)` and retain the first receipt; no timestamp frontier drops late packets. Packet-only arrival schedules scoring transactionally. The receiver validates the bounded versioned shape, projects owner/device-scoped rows, and PostgreSQL statement triggers dirty revisions on material insert/update/delete, excluding arrival-only replay metadata. The scoring reader independently rechecks CRC, record digest and all claimed decoded metadata before emitting original packet-local beat identities. `DayInputs.rrContinuityEvidence` then reports `verified_packet_local_original_words_no_beat_clock`. The current device-catalog firmware is not claimed as historical capture firmware.

This completes an implementable identity seam, not a beat clock. No receipt or adapter asserts `verifiedSpan`, reconstructs subsecond endpoints, or links beats across packets. A complete packet can prove local word adjacency while still returning `timing_coverage_unverified` for a five-minute measurement. The external evidence gap is a verified acquisition clock and cross-packet continuity; the application no longer needs to discard identities that the packet actually contains. Existing rows lost or compacted before this lane require retained original packets to recover identity.

Both native `IntelligenceEngine.analyzeRecent` loaders also read the owner's checked receipts and pass the shared `packetOrLegacy` adapter to `analyzeDay`. Historical receipt observations exclude same-second value-keyed legacy duplicates and do not borrow standard BLE rows; other historical rows remain explicitly continuity-unverified. Global `v4` analysis fingerprints and per-day `s3` stream witnesses include immutable receipt count/rowid, so packet-only late arrival invalidates both the persisted watermark and the process-local day memo. No verified time span is added by this wiring.

For an otherwise unknown native owner, a stored WHOOP5 receipt is also a source-family witness even before legacy RR tags exist. This does not override a confirmed WHOOP4 or non-WHOOP registry owner and never borrows another physical owner's receipts. A family-policy change invalidates the day witness even outside the receipt's own time range.

Per-device deletion and stable-identity adoption include the companion table on both platforms. Adoption retains the packet digest and raw bytes while changing only the local owner key; deleting one owner's data does not delete another owner's receipt. Final full-package testing caught the missing lifecycle-list entry, and temporary SQLite regression tests now exercise the actual delete/re-key orchestration. No real user database was deleted or re-keyed during validation.

`canonical_rr_source_oracle.json` exercises real GRDB source reads and the server policy with the same counterexamples. `rr_packet_store_server_oracle.json` carries the baseline checked wire fixtures through Swift packet decode and SQLite replay and checks the resulting millisecond/source contract on the server. Those tests prove parsing/storage/selection parity, not the accuracy of beat timing or physiological estimates.

## Signal availability inventory

This is a source-contract inventory, not a measured user/night coverage report. No consenting device database, verified raw object collection, or device soak was supplied to this worktree.

| Signal | Available representation | Rate and timing evidence | Remaining limitation |
|---|---|---|---|
| HR | Postgres `noop_hr_samples` integer BPM | Whole-second event timestamp; emitted rows may be sparse | Per-night coverage and clock accuracy unmeasured |
| IBI | Legacy `noop_rr_intervals` plus checked `noop_rr_packet_provenance` receipts | Known WHOOP5 packet words use 1/1024-second duration ticks; original word positions/zeros retained in the companion lane, timestamps remain whole seconds | Cross-packet beat identity, verified beat clock and observed-time union unverified |
| Gravity | `noop_gravity_samples` x/y/z | Timestamped summary samples | Cannot replace aligned full-rate IMU axes; units/orientation must be qualified per adapter |
| Steps | `noop_step_samples` counter/activity class | Native timestamped counter, no algorithm changes | Actual device density and receiver rollout unverified |
| Respiration field | `noop_resp_samples.raw` | Raw decoded scalar at row timestamp | Not a synchronized respiratory waveform or reference label |
| Off-wrist/events | `noop_events` kind/payload | Native event timestamp | Missing events are not proof of wear/contact |
| Raw v26 optical | Local PPG blobs; versioned gzip archive | Usually 24 i16 samples per decoded record; timestamp second, burst and record counters | Nominal 24 Hz assumption is not measured continuous sampling; multiple records/second, wavelength, clock uncertainty and gaps require qualification |
| Raw IMU | Optional file-backed 600-i16 axis-major record and archive | Existing format declares 100 samples/s across six axes | Actual synchronized optical/IMU coverage, axis units/orientation and clock mapping unverified |
| Raw packets/v18 auxiliary | Optional rawBatch/v18Aux object lane | Original packet bytes or decoded auxiliary blob where retained | Archive absence/pruning and verified digest status require a per-window inventory |
| Phone use/bed occupancy/manual context | No universal phone-use or bed-occupancy sensor feed | Independent annotations needed | Wrist inactivity cannot establish phone use or sleep |

Continuous HRV is opt-in. The existing overnight refinement defaults to 22:00-07:00 for a new configuration and honors prior-user migration behavior. Battery and background conditions can pause capture. No daytime continuity, battery draw, sleep coverage, locked-phone behavior or five-minute upload SLA was measured here.

### Executable owner/night inventory

The service's `--inventory-signals` command executes only read-only, repeatable-read PostgreSQL queries, before initializing any scorer, heartbeat, B2 client or model worker. It requires an explicit owner, physical device and date, verifies their relationship and uses the same persisted historical calendar segments as scoring. It exports no heart-rate values, interval values, raw bytes, object keys or credentials. The report itself still contains sensitive owner identifiers/timestamps and needs the same access controls as the source data.

After `:service:installDist`, run against an explicitly authorized database copy or account:

```sh
export DATABASE_URL='postgresql://read_only_user:…@localhost:5432/authorized_copy'
export INVENTORY_USER_ID='the-authorized-owner-uuid'
export INVENTORY_DEVICE_ID='the-owned-device-uuid'
export INVENTORY_DAY='2026-09-18'
# Optional exact half-open window within that date and its preceding context:
export INVENTORY_START='2026-09-17T22:00:00Z'
export INVENTORY_END='2026-09-18T07:00:00Z'
./service/build/install/service/bin/service --inventory-signals > signal-inventory.json
```

The dates above are examples, not an actual capture. Omit **both** optional bounds for the whole historical date plus preceding-date context. Non-owned/oversized windows and mismatched devices fail rather than widen scope. The command cannot be combined with replay/scoring. Statements have a 15-second deadline; more than 10,000 raw catalogue windows requires a narrower request.

For each projection the report records row count, occupied event seconds, occupied-second fraction, maximum empty-second run and event endpoints. It separately records RR source/suspect counts, checked-receipt clock versions/precision, and raw catalogue count/size/digest/decode status. Occupied second bins are **not** verified observed duration or waveform sample rate. Unsupported rates, channel identities, timing uncertainty and continuous coverage stay null/unqualified. A nominal format, first-to-last span or catalogue's reported coverage cannot make them valid. Raw records are explicitly catalogue-only: this read-only survey does not re-fetch objects or grant pruning/model-activation permission. Use the bounded byte verifier and a qualified acquisition adapter for those stronger proofs.

The command and scope/ownership/DST/no-mutation behavior are tested with synthetic disposable PostgreSQL records. No private user/night inventory has been run by this task.

Local waveform retention remains a bounded newest-record policy without an archive digest-verification prerequisite. Upload cursors and accepted object manifests do not establish verified archived content. Consequently local PPG/IMU presence and a catalogue row alone cannot enable a waveform candidate. Its adapter must independently fetch, digest-check, decode and measure eligible coverage; an absent/unverified object disables only that dependent candidate. This limitation must be resolved before unverified local pruning is used as a model-data retention guarantee.

## Executed checks

Final runtime checks on 2026-09-18 used the isolated physiology worktree and external build/cache storage. Swift test counts below include the explicitly reported skips; none of the skips is treated as a pass.

| Suite | Reported tests | Skipped | Failures | Log under `/Volumes/Untitled/physiology-build/` |
|---|---:|---:|---:|---|
| Full WhoopProtocol | 731 | 1 | 0 | `w0-final-protocol.log` |
| Full WhoopStore, after lifecycle repair | 562 | 1 | 0 | `w0-final-store.log` |
| Full NoopPush | 27 | 0 | 0 | `w0-final-push.log` |
| Full Edge function suite | 61 | 0 | 0 | `w0-final-edge.log` |
| Android device-registry/adoption/packet-lifecycle subset | 38 | 0 | 0 | `w0-final-android-registry.log` |

Swift commands use `swift test --package-path Packages/<package> --scratch-path /Volumes/Untitled/physiology-build/swift-<protocol|store|nooppush>`. Edge uses `NPM_CONFIG_CACHE=/Volumes/Untitled/physiology-build/npm npx --yes deno test --allow-all tests/` from `supabase/functions`. The Android subset uses `:app:testFullDebugUnitTest` for `DeviceRegistryTest`, `RrPacketProvenanceMigrationTest`, `RegistryDayOwnerSourceTest` and `SourceCoordinatorAdoptionTest`, with the lead's external SDK/JDK/Gradle cache. It compiles all application/test sources but does not mean all Android runtime tests ran.

The protocol skip requires a supplied `WHOOP_R20_CORPUS` deep-buffer JSONL; the store skip requires a disposable private phone-database copy. Neither input was available. Initial full-store testing reported one genuine missing `deviceScopedTables` entry for receipts; the final result above follows the twin lifecycle repair and its added regression test, not a weakened assertion.

Additional scoped evidence: Swift shared packet adapter/HRV integration 6 tests passed (`rr-native-analytics.log`); earlier Android packet/decoder/schema/export 25 tests passed (`rr-packet-android.log`). The independent reviewer subsequently reported 64 combined native tests passed with zero skips/failures, including final receipt-only source boundaries and the unchanged JaCoCo guard (`audit-native-android.log`, 55,683 instrumented bytes against its 55,700-byte budget). That combined run preceded the lifecycle-list repair; the final 38-test registry gate above covers that repair. Existing integer-primary-key nullability metadata divergence is documented in both schema oracles without a production table rewrite.

The lead's disposable PostgreSQL run also exercised `RrPacketProvenanceIntegrationTest`: actual packet-only transactional revision, replay, owner isolation, original zero slot, invalid-CRC rejection and delete invalidation. Final service, full application build, full Android and HRV-math audit gates belong to the lead's global ledger. Shared schema, decoder and packet fixture copies are byte-identical.

Not executed here: private phone-copy acceptance, exact-branch physical acquisition/backfill soak, iOS raw compression runtime, verified archived-object survey, ECG/PSG/respiratory reference validation, or deployment. Local runtime/build green does not supply missing beat-clock, capture-firmware, reference-label or device-soak evidence.
