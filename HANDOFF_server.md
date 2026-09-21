# Server pipeline handoff

## Scope and source identity

Branch: `fix/server-pipeline`. Worktree: `/Volumes/Untitled/WHOOP NARA-server-pipeline`.
Base: PR #28, `7daa66a02c9c469361cf4e68d50d8743e0177173`.
The original `/Volumes/Untitled/WHOOP NARA-pr16` checkout and its newer UI work were preserved.
No deployment, production migration, production-data access, model promotion or push was performed.

Implementation anchors include `8e01c37` (buildable JVM lanes), `477745f` (shared readback and
diagnostics), `7de5cb5` (bounded publication conflicts and invalid-clock durability), `57f3cda`
(shared migration lineage), `d74356d` (source-hashed runtime preflight), `ce1ea23` (deployment),
and `e9d009f` / `817da6e` (phone authorization).
These are review units, not interchangeable build identities. The final tested commit SHA,
test outcomes, artifact paths and exact local image IDs are recorded in
[/Volumes/Untitled/server-pipeline-final.CcPqaa/verification.md](/Volumes/Untitled/server-pipeline-final.CcPqaa/verification.md).
That receipt is outside Git so recording verification does not change the commit being tested.
If it is missing or any gate is not PASS, final local acceptance is incomplete.

## Changes

- Reconciled the independent retained-v1, physiology-v2 and historical-shadow DTOs, readers,
  queues, leases, inputs, publishers and entrypoints. Historical context, thermal, day-cycle,
  workout and metric orchestrators run through the explicit historical worker.
- Preserved frozen v1 numerical sources. Its separately built producer uses reviewed transport
  and runtime-identity patches. No v2 output is relabeled as v1. Defaults remain retained v1.
- Unified account and enrolled score selection, signed qualification, current revocation,
  manifest validation and serialization. Enrolled reads cannot substitute another device.
  Sleep approval alone cannot disclose embedded HRV or respiration from an unauthorized snapshot.
- Added production Swift/Kotlin decoder and scalar-selection tests fed unchanged bytes from
  real SQL through the actual Edge handler. Valid zero is preserved; unsupported/null is not
  treated as a worker crash. Phone local producers remain intact for the separate cutover issue.
- Added metadata-only enrolled diagnostics for all requested stages. Server-only evidence does
  not claim phone acquisition, local durability, decoding or actual screen rendering.
- Repaired baseline publication being silently filtered by an unrelated historical queue.
  Preserved immutable retries and all owner/device/revision/lease/run checks. Public publication
  conflicts now return bounded HTTP 409; private lease helpers retain their original semantics.
- Preserved durable raw sensor rows with unrepresentable timestamps; no fake calendar day is
  queued. Repaired lowercase digest validation and idempotent accepted-receipt audit retries.
- Added strict native-distribution source identity and deployed image checks, selected-version
  producers, hosted-project binding, advancing polls, publication progress and projection-debt
  checks. A healthy heartbeat alone cannot pass a stalled projection/publication gate.

See [the contract](docs/server-pipeline-contract.md) for the exact lane and API boundaries and
[the deployment review plan](infra/vps/SERVER_PIPELINE_DEPLOYMENT.md) for operational details.

## Local verification

Final-commit results are in the verification receipt above. Retained development evidence:

| Gate | Completed development result | Evidence or reproduction |
| --- | --- | --- |
| Fresh and populated upgrade | Both pass all 117 SQL files, full-name/hash ledger and empty pending plan | `migrations-fresh-117` and `migrations-populated-117` under the final evidence directory |
| Queue, revision and lease behavior | 158 actual PostgreSQL tests pass; includes 305 live-arrival cycles | `scoring-service/scripts/test-physiology-queue.sh`; final full JVM run repeats these |
| Deployment contract | 116 Node, 42 Python and 6 baseline-builder tests pass | `infra/vps/scripts/*.test.mjs`, `infra/vps/tests`, `scoring-service/legacy-baseline/test_builder.py` |
| Native Edge intake and recovery | 158 tests / 56 substeps pass; one SQL-to-phone case ignored here and run separately by `test-server-pipeline.sh` | `/Volumes/Untitled/server-pipeline-edge.vzpySD/edge-native-suite-repair2.log` |
| Phone authorization and presentation logic | 56 Swift and 4 standalone production Kotlin codec tests pass | Final receipt records rerun and real-envelope results |
| Current Swift/JVM parity | Fresh write-once Swift export; 13 whole-day cases pass | `scoring-service/scripts/test-server-jvm.sh` exports and verifies exact hashes |
| Full JVM and installDist | Clean full suite and distribution required on final commit | Final receipt includes XML totals and explicit external-reference skips |
| Containers and four-device readback | Exact-source images and complete regression rerun required on final commit | Final receipt; commands below |

The queue count is part of the full service suite, not an additional independent test count.
Five kernel agreement tests require absent private/reference corpora; these are existing explicit
skips and do not establish physiological accuracy. The native Edge run exports current Swift
auxiliary fixtures; its IMF fixture is a hash-verified replay of the supplied historical producer
artifact, not proof of a newly built full app host.
The frozen baseline's separate legacy test run also has six database-integration skips plus
five private/reference-data kernel skips. The new real v1 worker test is additional evidence,
not a relabeling of those skipped legacy cases as passes.

The SQL-to-phone test uses two synthetic owners with two devices each, real append projection,
both worker executables, immutable publication and enrolled readback. It also checks account
authorization, approved/shadow/missing/revoked/manifest-mismatched v2, sleep-only field boundaries,
bounded stale-lease HTTP conflicts, private-function permissions and concurrent same-owner
publications with identical sleep start times. Synthetic signed approvals exist only inside the
disposable test database; they are not scientific evidence or deployable promotion metadata.

Reproduction from a clean checkout, with Java 17, Swift, Docker, Node/Deno and local PostgreSQL:

```sh
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
PG_BIN=/opt/homebrew/opt/postgresql@18/bin \
bash scoring-service/scripts/test-server-jvm.sh

# Build the frozen baseline using its reviewed builder instructions, then set both paths.
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
PIPELINE_TEST_V1_BINARY=/absolute/baseline/service/bin/service \
PIPELINE_TEST_V2_BINARY="$PWD/scoring-service/service/build/install/service/bin/service" \
bash scoring-service/scripts/test-server-pipeline.sh
```

The installed native v2 artifact must match the current commit; rebuild after changing HEAD.
Supplying neither worker path tests SQL/API/decoders only and is not worker acceptance.
Use the [baseline build instructions](scoring-service/legacy-baseline/README.md) and reviewed
Dockerfiles for exact-source images. Do not substitute an environment source label for image
or packaged-byte identity. Local image config IDs are not published registry digests.

## Migration impact

The original 112 migration files are byte-preserved. Five forward repairs are added:

1. `20260921100000_server_score_read_contract.sql` — shared authorized reads.
2. `20260921101000_server_pipeline_diagnostics.sql` — service-only scoped diagnostics.
3. `20260921102000_server_baseline_publication.sql` — original serializer behind the live fence.
4. `20260921103000_server_publication_conflict_transport.sql` — private fenced implementations
   and public HTTP-conflict adapters; no lease validation is removed.
5. `20260921104000_server_unrepresentable_clock.sql` — unknown time remains unknown and durable.

The authoritative full-basename/hash catalog is
`scoring-service/service/src/main/resources/scoring-migration-catalog.json`, shared by runtime
preflight and infrastructure validation. Six historical timestamp collisions remain distinct.
Fresh order explicitly applies the existing `20260921060000` intake repair before the historical
projection-debt SQL that depends on it. Applied identities are never blindly replayed.
An ambiguous, unverified or incomplete hosted ledger requires human-reviewed reconciliation;
passing the disposable upgrade fixture does not attest an uninspected production ledger.

## Remaining boundaries and blockers

- Target VPS deployment, hosted-project/ledger binding, registry digests, live polling/publication,
  enrolled real-phone readback, physical displayed state, soak, B2 and hardware timing are
  **NOT_MEASURED**. This task deliberately did not authorize those operations.
- HRV timing without proven continuity remains `continuity_unverified`. Calibrated SpO2 remains
  unsupported without a qualified source. No reference/model approval or clinical accuracy is
  claimed by synthetic tests, a successful upload, container builds or legacy-v1 retention.
- Full Android app test compilation has unrelated missing PPG test symbols
  `PPG_RECORD_IDENTITY_MIGRATION_SQL` and `unpackPpgRecords`. Main app sources compile; actual
  production score decoders are compiled and exercised separately. No source/test exclusion was
  introduced to conceal this app-test blocker.
- Historical archives with null source identity or a completed projection ledger but only a
  legacy non-durable ACK are **NOT_READY** for automatic provenance repair. They remain fail-closed;
  no source is rebound or receipt fabricated. The tested pre-ledger retry is not evidence that a
  corrupted modern-ledger/stripped-ACK hybrid can be recovered. See `projections.ts` receipt checks,
  `objects.ts` null-source rejection and the legacy-ACK branches in migration `20260918040000`.
- The frozen baseline retains its legacy lack of absolute JDBC/attempt deadlines. It does not
  hold an input gate during compute; deployment must fail stale poll/publication checks rather
  than infer progress from lease renewal. The 305-cycle concurrency proof covers physiology v2.
- The historical camelCase snapshot API remains a distinct shadow contract; this repair does
  not claim historical-model phone activation or replace every local metric producer.

## Deployment and rollback plan — not executed

Review the exact final commit, test receipt, both immutable images and target ledger first.
Obtain separate authority for migrations, registry publication, deployment and any model promotion.
Apply only the reviewed forward migration plan; configure the dedicated hosted database/REST
project binding and secrets. If an unpatched v1 producer is running, stop it and prevent restart
before installing the fencing migrations; resume only with the reviewed patched baseline.
Cut over retained v1, physiology shadow and historical shadow lanes
independently, then verify exact image/source/process/version, advancing polls, real publication
under debt, projection progress, and an authorized enrolled-phone canary.

Keep prior images, protected configuration and per-lane state. Roll back only the affected owned
lane to a reviewed compatible artifact; do not start an unfenced old v1 binary, relabel v2, replay
old migrations or mutate immutable results. Keep archive debt recoverable/draining independently.
Lane rollback is not a distributed transaction: report the actual state of every lane and stop if
ownership or restoration cannot be established. Selection or qualification changes need separate
authority. Preserve the additive schema and repair it forward if necessary.
