# Supabase upload repair deployment — 18 September 2026

The user explicitly approved deployment of the reviewed Supabase repair from commit
`27156ff257115acd1d345d27c7e52f107899a8c9`. This release applies only the five pending
migrations and the `push` receiver. It does not deploy the VPS scoring worker, change
model selections, merge PR 21, or establish physiological accuracy.

## Applied release

The release was exported from the exact committed source into a private staging
directory. Both database dry runs listed only the approved migrations. The CLI
applied them in this order:

1. `20260918180000_standard_hr_receipts.sql`.
2. Deploy `push` with its existing in-function authentication and `verify_jwt=false`.
3. `20260918190000_frequent_heart_rate_readback.sql`.
4. `20260918200000_restore_input_revision_fencing.sql`.
5. `20260918210000_bounded_scoring_input_gate.sql`.
6. `20260918220000_bound_projection_invalidation_work.sql`.

The hosted receiver advanced from version 6 to **version 7**, active at
2026-09-19 02:39:12 UTC (18 September locally). The deployed bundle's 18 embedded
source modules exactly match the committed source. No other function was deployed.

The old receiver bundle/metadata, database schema, queue snapshot and original
packet identity/content digests were saved privately before deployment. No database
reset, measurement deletion, cursor reset, or credential change occurred. The
migrations preserve original inputs and immutable published results. Migration
200000 can revoke dirty running claims; the preflight found zero such claims.

## Live verification

- All five migration ledger entries are present; no local migration remains pending.
- An independent read-only reviewer verified all seven final function bodies against
  the committed source, the receipt table's validated primary/foreign keys and CHECK
  constraints, all four triggers, RLS, and restricted table/RPC grants on PostgreSQL 17.6.
- Anonymous capabilities requests return 401. The phone's authenticated request
  returns 200 and advertises `standardHRReceipt`.
- At 02:40:01 UTC, packet receipts had increased from **5,770 to 10,770**. Every one
  of the original 5,770 packet identities remained present with identical content
  digests, excluding replay delivery metadata. The phone's cursor also advanced.
- By 02:42:40 UTC, two separate **5,000-record packet batches** had received ACKs,
  each matched by 5,000 persisted packet rows. **5,997 standard HR receipts** were
  also persisted and acknowledged. There was no remaining packet-provenance WAL
  entry at that snapshot.
- At 02:54:09 UTC, packet storage had reached **22,717 rows** and the post-release
  packet ACKs totalled **16,947 records**. Standard HR receipt storage reached
  **6,573 rows**. This is observed ingestion progress, not qualified HRV readings.
- A bounded log query from 02:40:00 through 02:46:06 UTC returned no statement
  timeout or `push_failed` messages. This short observation is not a sustained-load
  or overnight acceptance result.

Actual Supabase commands used CLI 2.75.0: `db push --dry-run`, `db push --yes`, and
`functions deploy push --project-ref sgoyxzcagqyxexmsidtk --use-api`. The staged
migration directory controlled the two approved migration groups. Credentials were
passed through process environment, not committed or printed.

## Separate client defect exposed by recovery

After packet ingestion advanced, the phone reported `invalid_object_manifest` for
`rawBatch`. This is an inherited baseline defect, not a regression in the deployed
receiver. Historical capture stores inclusive bounds with `startTs == endTs`, while
the upload contract requires a half-open range. All 1,757 unsynced raw batches in
the preserved phone backup had equal bounds. A local receiver reproduction rejects
such an otherwise valid manifest solely for `endTs`; converting the inclusive end
to an exclusive end passes while raw-batch signal coverage remains unknown.

The client follow-up converts capture indexing bounds with checked arithmetic in
Swift and Kotlin, preserves the packed bytes and original clock fields, rejects
reversed/overflowing ranges, and retains deterministic retry identity and ACK-only
local completion. It does not relax server validation or manufacture beat timing.
The corrected bounds legitimately change derived manifest identities; retries of
the corrected manifest remain deterministic. Equal-bound intents were rejected
before object creation. An older interrupted positive-duration intent can leave a
duplicate remote archive for normal cleanup; no unsafe deletion was added.

| Finding | Requirement / evidence | Impact | Repair / required regression |
|---|---|---|---|
| AV13 / P1, inherited | `PushProtocol.binaryBounds` forwarded inclusive raw capture bounds as a half-open manifest. `Backfiller` stores history with equal bounds; all 1,757 pending rows in the preserved phone copy matched this case. The unchanged Edge validator rejects `endTs <= startTs`. | The oldest invalid raw archive is repeatedly selected and that archive lane cannot advance. Raw rows remain local without an ACK. Other append lanes can continue. | Checked exclusive-end conversion in both clients. Paired serialized fixtures cover equal/inclusive bounds, unchanged payload/hash/clock evidence, deterministic retries and identities, and rejection of reversal/overflow. |

The final client follow-up passed **38 Swift push tests** and **171 Android push
tests**, with no failures or skips. A fresh reviewer independently passed the actual
Swift serialized manifest through the unchanged Edge validator and confirmed the
old variant fails only its end bound. The signed iOS **build 351** succeeded using
`generic/platform=iOS`. The physical-device destination failed because the phone
became unavailable; build 351 is not installed and its live raw archive retry is
not verified. Build 350 remains the last verified installed version.

The first Swift run exposed two stale identity goldens and a full temporary disk
during the existing 64 MiB independent zstd interoperability test. The goldens were
updated for the corrected manifest identity. A test-only `NOOP_TEST_TMPDIR` override
moved temporary fixtures to the external volume without reducing sizes or assertions;
the complete suite then passed.

Final client test commands:

```sh
# Repository root
env NOOP_TEST_TMPDIR=/Volumes/Untitled/physiology-audit/tmp \
  TMPDIR=/Volumes/Untitled/physiology-audit/tmp \
  swift test --package-path Packages/NoopPush \
  --scratch-path /Volumes/Untitled/physiology-build/diagnostics-push --jobs 2

# android/
env JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  ANDROID_HOME=/Volumes/Untitled/physiology-v2-baseline.ROUXBD/android-sdk \
  GRADLE_USER_HOME=/Volumes/Untitled/physiology-v2-baseline.ROUXBD/gradle \
  TMPDIR=/Volumes/Untitled/physiology-audit/tmp/ \
  JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=/Volumes/Untitled/physiology-audit/tmp \
  ./gradlew :app:testFullDebugUnitTest --tests 'com.noop.push.*' \
  --no-daemon --max-workers=2 -Pksp.incremental=false
```

## Remaining limits

The physiology heartbeat still had no `last_poll_at`, its last score was from
22:40 UTC, and 11 work items remained pending at the post-release snapshot. The
worker binary and environment were not changed. The input gate's worker-side
behavior therefore remains undeployed even though its database support is present.

Verified WHOOP beat timing for HRV/respiration and calibrated SpO2 remain incomplete.
Learned waveform models remain in shadow. Successful upload recovery supplies more
original evidence; it does not establish valid five-minute estimates or better
reference accuracy.

Private release evidence is retained under
`readings-investigation-20260918/private/deployment-27156ff/`, outside Git. It includes
CLI logs, schema/source verification, private backups, capabilities probes, packet
preservation checks and real ACK snapshots. Tokens and raw health data are excluded
from this report.
