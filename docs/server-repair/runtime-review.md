# Runtime and Edge merge review

Review at 2026-09-22T23:39Z. Integration source e499162b4a0ce340b564e0232af14b5af355d6f1; full PR22 followup a972493212f2eae29f01ecaddf9182260153400f. No production writes, deploy, phone installation, selection/promotion, reset, or main merge occurred.

## Current real evidence

Sanitized trace: `/Volumes/Untitled/server-repair-edge-review/input_to_result_trace.json`. Bound privately to owner/source from the existing build371 phone SQLite snapshot read with `mode=ro`. The physical phone is disconnected, so this is historical phone linkage plus current hosted observations, not current physical readback.

- Latest same-scope accepted batch is HR, 2026-09-22T17:34:55Z. Manifest and immutable receipt/index exist, 5,000 HR input rows bind to that batch; device-day input has 24,811 HR rows. No HR values were exposed.
- Earliest observed incomplete ledger transition: accepted/indexed batch has projection debt `pending`, no failures, despite actual input rows. Manifest digest provenance is `client_claimed` despite a `verified_indexed` receipt. Source repair must reconcile these without manufacturing verification.
- Hosted selected v1 work revision 612 is pending and unclaimed. No v1 result. Shadow v2 revision 630 completed/published. All three selected features await v1.
- The only live hosted scorer is old v2 source 80a7c0771beff46b60e05ba933e78789b11cdc56, image sha256:58a843bcc41531c73daa76c7f541ccc5ed04a6f93393574a75f54cae4e84fb04, without process identity. The only v1 container points at local PostgreSQL/REST rather than the phone's hosted project.
- Hosted catalog still has 117 source identities, latest 20260921104000_server_unrepresentable_clock.sql. Neither PR22 copy-intent nor async debt table exists. Reconcile really runs `0 */6 * * *`. No verifier container is running. Async capability must remain off.
- Function versions: push13, scores3, reconcile3, ingest-verify3, retention-sweep3, account-deletion3. No compatible candidate workers/Edge/schema have been deployed.
- Actual enrolled/account authenticated HTTP and phone decoder/UI are NOT_MEASURED. The normal installation bearer/account session was unavailable to this read-only inspection. No credentials were synthesized to impersonate the phone.

## Source findings

1. Production `push/index.ts` integration construction has `projectAppend` but lacks `commitProjection`; durable archive/ACK and row writes therefore bypass the atomic projection-debt settlement path. PR22 had the callback, but restoring it directly would bypass integration's multiuser observation/conflict handling. The repair must call the lifecycle append projection inside the same archive projection settlement transaction.
2. `noop_commit_object_receipt` updates sha256_source but its update predicate omits that field (also digest_scope/verified_at). Reverification of a ready exact existing receipt can leave stale client_claimed metadata untouched. Add a forward function repair; repair only after actual byte verification.
3. Existing ScoringPoller releases the input guard after loadDay and before expensive scoring. Preserve this behavior and 305-cycle regression rather than reintroducing the old gate.
4. PR22 async default four claims per six-hour reconcile gives an upper bound of 16 claims/day. Dedicated bounded continuously serviced verifier/projection workers and operational admission guard are required.

## Stage0 Edge merge changes and validation

Resolved seven Edge conflicts preserving enrollment, fleet credential, installation-source/auth scope, accepted receipt audit and scoring enqueue. Async queue/poll paths now enforce the same source/auth manifest scope as synchronous completion; successful async polls also preserve accepted-upload receipt audit. Kept both S3 version erasure and orphan exact-version tests and both PostgreSQL harness option sets.

Integration tests exposed a merge regression: PR22 blanket failed-state demotion changed a pending manifest after database publication or scoring-gate rejection. The merge fix preserves pending retry debt after receipt publication failure while retaining failed-byte outcomes and immutable success protection.

Deno checks passed actual push/reconcile entrypoints and changed tests. Focused merged tests PASS: 28 tests with 27 substeps, zero failures. Evidence `/Volumes/Untitled/server-repair-edge-review/focused-tests-final.log`. Includes real disposable PostgreSQL/PostgREST/S3-loopback receipt/debt/lease/crash/source isolation. This does not establish target B2 behavior, device behavior or capacity.

## Implemented intake repair at reviewed common base 76f2d70f

Candidate forward migration `20260922120000_intake_service_contract.sql` hash `c39b15b45651d39d80a07f84ec4c99b1183d0addf75363209808aaac4a51d86d`:

- Restore the actual production atomic commit callback, routing enrolled append projection through the integration lifecycle observer/conflict logic inside the existing debt/ACK transaction. Require exact current archive receipt and active source before settlement.
- Fix the gravity whole-row alias ambiguity (`to_jsonb(x.*)`, `to_jsonb(t.*)`) found by an independent real SQL positive fixture.
- Full-chain testing identified the reason for hosted `client_claimed` despite a receipt: the raw-input invalidation BEFORE trigger clears byte and decoder proof when the COPY destination changes object_key. Publish exact byte proof in a second stable-metadata update under the same manifest lock/transaction; preserve decoder invalidation. Reverification also repairs old metadata only after reading/checking actual bytes.
- Add independent single-object verification, scalar projection and old-intake lanes. Verify packaged source, target hosted project, SQL contract before running. Actual queue calls update service progress; no timer heartbeat establishes readiness. New async requires explicit flag plus a recent compatible successful verification poll; existing debt remains readable/drainable when off.
- Both verification and projection rotate owners and recent/history lanes. New debt transactionally registers owners; old owners seed once. Indexed service windows inspect at most 128 owners per claim, idle owners back off. No per-poll distinct scan of all owners' debt remains.
- Sanitized bounded status includes old debt age, sample size/truncation, last 15 complete minutes of real service counts/rates. It explicitly labels capacity/physical continuity NOT_MEASURED. Minute aggregates and stale process rows have bounded retention work.

Validation:

- Full 127-migration disposable Supabase/PostgREST plus actual signed streaming S3 client on synthetic loopback storage: PASS 1 test / 7 steps, `/Volumes/Untitled/server-repair-evidence/server-pipeline.UYRqFi` and `intake-pipeline5.log`.
- Covers actual HR/gravity NDJSON -> WAL/archive -> immutable byte receipt/index -> source-bound lifecycle observations -> settled projection debt/ACK; immutable retries; conflicting receptions excluded; old verification metadata repair; real async raw verification; two-owner recent/history scheduling; interrupted-before-projection queue replay; service-role boundaries.
- Focused prior contracts PASS 9 tests / 14 steps at `intake-regressions2.log`; standalone consumer source tests PASS 4/4; actual entrypoints and SQL harness type-check.
- Local dirty fixture image built (source label all-zero deliberately NOT a release). Offline, cached-only, read-only, non-root Deno module smoke passes; missing identity fails closed. `intake-fixture-image.json` and `intake-fixture-runtime-smoke.log`. Final exact-clean-SHA labels/digest/manifest build remains separate.
- Independent acquisition/science review confirmed the second proof update retains the manifest lock and leaves decoder/model qualification unset. Independent release review found the projection fairness gap, now repaired and exercised above.

No production changes, async enablement or target-VPS capacity measurement were performed. Positive scalar worker fixture is being joined to the actual NDJSON/archive path; a synthetic result remains distinct from the current historical-phone-scoped hosted trace and physical acceptance.

## Joined positive input-to-result fixture

PASS `/Volumes/Untitled/server-repair-evidence/server-pipeline.Be25gT`, full output `server-repair-edge-review/positive-durable-intake.log`:

- 22 actual NDJSON batches containing 10,800 HR and 10,800 gravity samples passed the production parser, actual source-bound installation/fleet lookup, WAL, signed synthetic S3 COPY/streamed verification, immutable receipt/index, atomic lifecycle projection and settled debt.
- Initial v1 queue admission came from actual scalar-change triggers; the initial manual test enqueue was removed. The unchanged baseline daemon stayed running through two publications despite stale REPLAY environment. The second publication intentionally uses an explicit enqueue to test persistent daemon behavior.
- Selected immutable sleep output was `179.98333333333332 min`, RHR `53 bpm`, qualification `retained_legacy`. No RR, HRV, respiration, SpO2 or new model qualification was manufactured.
- Actual enrolled API and a disposable real GoTrue issued/verified account bearer returned the same immutable value. Swift/Kotlin each accepted 23 real Edge envelopes and their persisted selections; both rejected four mutation cases (8 total).
- Trace `decoders/computed_fixture_input_to_result_trace.json` SHA256 `573e5985be9de819369f6db016aa05f094c56c445e32d888efd6a8f18e59c05f`; immutable payload hash `25b3742471ba8110ac0fefc8d4506aa9de9095ce46ab989c6c1dba5a29aac68b`.
- Evidence explicitly distinguishes synthetic acquisition and loopback S3 from physical BLE/hosted B2. Physical readback remains NOT_MEASURED. These development binaries were supplied from the reviewed base; the worktree was dirty. The accompanying source-receipt.json records this. A later metadata-only trace change adds the dirty-state/hash and source-receipt path directly to new traces; this was type-checked and awaits the already required final combined-SHA rerun.

This closes a local source integration gap; it does not change the current hosted failure findings or grant deployment authority.
