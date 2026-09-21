# Server pipeline contract

Issue 1 owns this contract, the migration catalog, score readback, and deployment path.
Work started from PR #28 commit `7daa66a02c9c469361cf4e68d50d8743e0177173` in the isolated
`fix/server-pipeline` worktree. The original checkout's UI work is unrelated and preserved.

## Runtime lanes

| Version | Input and queue | Producer | Immutable result | Canonical read |
| --- | --- | --- | --- | --- |
| `frwhoop-server-1` | Owned scalar projections, `scoring_work_items`, fenced legacy lease | Frozen baseline kernel with reviewed transport/identity patches | `server_physiology_results` and independent archive outbox | Retained baseline selection |
| `frwhoop-physiology-2` | Event-time calendar, `physiology_work_items`, input revision and lease | `ScoringPoller` / `DayScorer` | `server_physiology_results` and independent archive outbox | Per-feature signed reference approval and exact release manifest required |
| `frwhoop-server-2-history` | Versioned profile/context/scalar inputs, `scoring_jobs_v2`, generation and predecessor checkpoint | `--history` / `HistoricalScoringPoller`; real context, day-cycle, workout, and historical orchestrators | Existing history snapshots and checkpoints, committed with generation/predecessor fences | Shadow only; does not activate the physiology read contract |

The historical source was partly merged into the physiology DTOs at the starting commit.
Its typed readers, claims, scorer and publisher now explicitly name the historical lane.
An input revision from one queue cannot serve as a generation or lease from another queue.
The historical producer runs independently; it cannot impersonate retained v1 or bypass
physiology qualification. Issue 3 owns any later per-family consumer cutover.

The physiology input gate covers capture of a consistent input snapshot. Compute proceeds
after release of the gate. Publication still checks the current input revision, live lease,
run ID and owner/device. Input arriving during computation therefore invalidates that attempt
without blocking ingestion for the full computation. Expiry, retries and archive failures
remain separate conditions. A PostgreSQL publication can be readable while its B2 archive is pending.

## Read contract, schema 2 / contract revision 1

Both `server_scoring_for_day` and `server_scoring_for_device_day` delegate to
`server_scoring_read_contract`. The account wrapper retains its per-feature source choice;
the enrolled wrapper always binds the requested registered device. A selection for a different
device cannot substitute that device's results. The ordinary caller must own the account;
the Edge service resolves personal installation plus fleet authorization before invoking SQL.

Every selected feature includes its device, algorithm, input and required revisions, computed
time, processing/archive state, calendar metadata, qualification and manifest identity.
Non-v1 availability requires a current signed approval, matching algorithm manifest, and
matching feature manifest. Revocation is checked on every read. A newest incompatible result
returns `manifest_mismatch`; the reader does not silently return an older compatible result.

`available` means the selected snapshot is usable. It does not promise every measurement in
that snapshot is numeric. Zero is valid; null retains its capability/quality explanation.
`stale` means a usable older snapshot exists while newer input is pending. A result with an
explicit unavailable reason remains unavailable even if its revision is also old.

Sleep episodes have an additional field boundary. Embedded HRV and respiration are serialized
only when their independently qualified feature has the same device, version and input revision
as the selected sleep result. Both phone decoders apply the same admission rule as a second check.
Phone local producers remain in place until Issue 3's replacement gates pass.

## Migration lineage

`scoring-service/service/src/main/resources/scoring-migration-catalog.json` records complete basenames, SHA-256 hashes,
and reviewed application order. The six duplicate timestamp groups remain distinct identities.
No applied SQL file is renamed or edited by this repair.

Fresh installs must execute the existing intake repair
`20260921060000_production_intake_durability.sql` before the historical projection-debt
migration that depends on its columns. This is an explicit dependency, not timestamp rewriting.
On upgrade an already-applied identity is skipped. A timestamp-only ledger that cannot identify
which colliding file was applied requires a reviewed reconciliation; the planner refuses to guess.
Checksums that were never recorded cannot be asserted retrospectively without evidence.

New forward repairs:

- `20260921100000_server_score_read_contract.sql`: shared selection, qualification, manifest and field serialization.
- `20260921101000_server_pipeline_diagnostics.sql`: scoped metadata diagnostics and stage reasons.
- `20260921102000_server_baseline_publication.sql`: retain the baseline revision/lease fence while
  calling the original private serializer; the older history-queue compatibility filter must not
  silently discard an independently claimed baseline day. Immutable retries and private RPC
  permissions remain enforced.
- `20260921103000_server_publication_conflict_transport.sql`: translate stale publication fences
  into bounded HTTP 409 responses. The real PostgREST negative test exposed an indefinite retry of
  SQLSTATE `40001`; private lease/revision helpers retain that code, while public publication
  wrappers roll back the failed attempt and return `PT409` using
  [PostgREST's custom error contract](https://docs.postgrest.org/en/stable/references/errors.html#raise-errors-with-http-status-codes).
- `20260921104000_server_unrepresentable_clock.sql`: preserve durable raw rows when the
  historical queue cannot represent their sensor timestamp. Invalid or nonfinite clocks
  produce no fabricated day or score; ordinary date conversion is unchanged.

The local migration suite covers a fresh database and the repository's populated predecessor
fixture. These fixtures do not establish the lineage of an uninspected hosted project.

## Diagnostics and evidence boundaries

`GET /scores/diagnostics?day=YYYY-MM-DD&deviceId=...` uses the same personal/fleet credentials
and device resolver as enrolled score reads. The ops route also accepts the explicit
`user_id`, `source_id`, `device_id`, `day` tuple. It calls the same device-day reader in one
database snapshot and emits pseudonymous correlation, stages, revisions, queue state,
publication identities, selected versions and matching worker identities. It excludes health
values, raw payloads, object keys, tokens and SQL error text.

The trace names acquired, durable, accepted, projected, queued, claimed, computed, published,
selected, decoded and displayed. The server cannot establish phone acquisition, local commit,
decoder execution or rendering: those stages explicitly say `not_measured` until corresponding
client evidence exists. Client decoder/presentation diagnostics contain stage and reason only.
Receipt timestamps describe acceptance on the requested calendar day; result timestamps describe
the measurement day. A historical upload can therefore have different acceptance and result dates.

Projection retry/debt is reported independently of worker polling. Computed shadows, a selected
version with no producer, pending computation, an incompatible manifest and a legitimately null
measurement are different states. Unsupported beat-clock continuity remains `continuity_unverified`;
calibrated SpO2 remains unavailable without a qualified source. No repair supplies physiological
reference evidence or production approval.

## Executable local acceptance

`scoring-service/scripts/test-server-pipeline.sh` creates disposable Supabase Postgres and PostgREST
containers, runs official Auth migrations and the reviewed application catalog, exercises real
SQL through the actual enrolled Edge handler, and feeds those exact bytes into production Swift
and Kotlin decoders. Only generated synthetic identities and data are used.

Set `PIPELINE_TEST_V1_BINARY` and `PIPELINE_TEST_V2_BINARY` to the built retained-baseline and
current service distributions to also exercise two users with two devices each through real
append projection, both worker executables, immutable publication, selected readback and both
decoders. Supplying only one worker binary fails. Without them, the run covers the SQL/API/decoder
contract but does not claim worker execution. The scripts retain evidence and stop their own containers.

Deployment is a separate authorized operation. Preflight must bind the phone/Edge/PostgREST/database
to one hosted project, verify the exact source/image and migration identities, and prove a producer
for each selected version. Advancing empty polls prove liveness only. Queued debt requires actual new
publication evidence and projection progress. Baseline, physiology shadow and historical shadow
artifacts retain separate identities and rollback controls.
