# Server pipeline deployment and rollback

This is a review plan, not deployment approval. No production migration, worker replacement,
model promotion, production-data read or registry push is part of this repair's local acceptance.
See [the score contract](../../docs/server-pipeline-contract.md) and the root server handoff for
the exact tested commit and outstanding acceptance evidence.

## Three independent producers

| Compose service | Algorithm version | Input and publication lane |
| --- | --- | --- |
| `scoring-baseline-v1` | `frwhoop-server-1` | Frozen original math; fenced v1 queue; immutable physiology results |
| `scoring-physiology-v2` | `frwhoop-physiology-2` | Physiology queue and immutable publication; reference qualification still required |
| `scoring-history` | `frwhoop-server-2-history` | Explicit `--history`; generation-fenced history jobs, checkpoints and snapshots; shadow only |

Defaults remain v1. Starting v2 or history never promotes it or changes phone selection. All
selected versions must have a compatible healthy producer; an unknown selected version fails
deployment acceptance. The v1 build is not the v2 kernel under a different label. Its numerical
baseline, result mapping and algorithm identity are byte-preserved, which is not evidence that
the old formulas are physiologically qualified.

The baseline image is separately built from `5caa31689da0023e111beb36850d3f81d67e1be2` with the two
reviewed transport patches. Its image labels include the exact repair SHA, original baseline SHA
and both patch hashes. Build it locally using [the baseline builder](../../scoring-service/legacy-baseline/README.md).
Authorized deployment requires `SCORING_BASELINE_IMAGE` pinned to its reviewed registry digest;
this repair does not publish that digest. Physiology and history use the same exact-source image.

## Migration lineage: no timestamp truncation or blind replay

The reviewed catalog is `scoring-service/service/src/main/resources/scoring-migration-catalog.json`
at the repository root. Infra planning and JVM preflight share this same packaged catalog. Each identity is a complete SQL
basename plus SHA-256, not just its first 14 digits. Six historical timestamp collisions are real
independent files. No original migration is renamed, changed or inferred to have run because a
different file shares its timestamp. `verifyMigrationSources` rejects missing, extra, symlinked or
changed source files.

Fresh install has one explicit dependency exception: the existing forward repair
`20260921060000_production_intake_durability.sql` executes before
`20260918040000_production_projection_debt.sql`. It provides intake fields required by projection
debt. It executes once, under its original identity. An already applied repair is never replayed.
The five new additive repairs are `20260921100000_server_score_read_contract.sql`,
`20260921101000_server_pipeline_diagnostics.sql`,
`20260921102000_server_baseline_publication.sql`,
`20260921103000_server_publication_conflict_transport.sql`, and
`20260921104000_server_unrepresentable_clock.sql`. The transport repair maps stale publication
leases to bounded HTTP 409 without changing private SQL lease/fence behavior. The clock repair
retains raw input while excluding unrepresentable/nonfinite timestamps from day projection.

Before an authorized upgrade, export the actual target ledger read-only and compare its identities
with reviewed prior deployment artifacts. The planner does not access a database or execute SQL:

```sh
node infra/vps/scripts/scoring-migration-plan.mjs \
  supabase/migrations /reviewed-target/ledger.json /reviewed-target/historical-identities.json
```

Rows may use `{ "version": "full_basename.sql", "sha256": "..." }`, or native timestamp and `name`
fields when the full identity can be resolved unambiguously. Optional historical attestations must
come from reviewed deployment artifacts, not hashes manufactured from today's files. Unknown
identities, ambiguous timestamps, duplicates and hash drift stop planning. A nonempty target with
historical omissions is `REVIEW_REQUIRED`; do not run the missing historical SQL speculatively.
Only a reviewed upgrade plan may authorize the exact pending forward repairs.

`apply-migrations.sh` is a legacy **self-hosted** runner targeting VPS-local `supabase-db`, not the
hosted scorer. It requires `--self-hosted-reviewed`, checks the complete plan before mutations, and
refuses unreconciled native/unhashed rows. It records a durable started receipt before each SQL
file; interrupted execution stops subsequent automatic retries. Reconcile any partial execution
from evidence. Do not use this runner or `supabase db push` to guess the hosted collision lineage.

Local fresh and populated-upgrade tests run all reviewed SQL in a disposable, network-isolated
Supabase PostgreSQL image, preserve a full-name/hash ledger, validate the final functions, and
confirm that all selected defaults remain v1. These tests do not establish the production ledger.

## Authorized deployment sequence

1. Pin and review the final clean commit, local build/test reports, immutable image config IDs,
   baseline digest and patch provenance. Build main/history and baseline images from those exact
   bytes. Record both image IDs; a source label alone is insufficient.
2. Review the hosted ledger and apply only the separately authorized forward plan. Preserve raw
   inputs, immutable results, queue revisions, leases and prior image/configuration identities.
   If any unpatched v1 producer is running, stop it and prevent restart before installing the
   fencing migrations; resume only with the reviewed patched baseline.
3. Configure only dedicated `SCORING_DATABASE_URL`, `SCORING_SUPABASE_URL`,
   `SCORING_SUPABASE_SERVICE_ROLE_KEY` and `SCORING_INGEST_SECRET` for the same hosted project.
   VPS-local Supabase credentials are not substitutes. Never put credentials into evidence.
4. Run the reviewed exact-source deployment script only with deployment authority. It requires a
   clean checkout, streams `git archive` rather than local caches, performs read-only preflight,
   and cuts over each worker lane independently. It never accepts inherited replay selectors,
   relabels v2 as v1, changes qualification, or exposes scorer ports.
5. Review all three version-specific runtime observations and the enrolled-phone canary. Deployment
   success is not qualification, a decoded phone result, or physical displayed-state evidence.

The old single-worker `--image-manifest` entrypoint now validates the artifact then explicitly
returns `NOT_READY`: its self-hosted topology cannot substitute for this hosted three-lane path.
The retained image provenance tooling still checks exact context/native bytes, config IDs,
platform/registry digests and labels; no fallback to mutable `:latest` is supported here.

## Read-only runtime evidence

The installed `verify-scoring-runtime.sh` requires a full source SHA, independently reviewed
immutable image ID, and explicit version. For example, on the authorized target:

```sh
/opt/frwhoop/scoring/verify-scoring-runtime.sh FULL_SOURCE_SHA sha256:REVIEWED_IMAGE_ID frwhoop-physiology-2
/opt/frwhoop/scoring/verify-scoring-runtime.sh FULL_SOURCE_SHA sha256:REVIEWED_BASELINE_ID frwhoop-server-1
/opt/frwhoop/scoring/verify-scoring-runtime.sh FULL_SOURCE_SHA sha256:REVIEWED_IMAGE_ID frwhoop-server-2-history
```

Each check binds the intended hosted project and exact container/image/source/version, requires a
unique deployment/process UUID and two advancing polls, and rejects restarts, competing workers,
wrong run modes, replay selectors, ports and stale/error progress. If scoring debt is observed,
the same process must advance confirmed score completion and an immutable publication marker.
An empty queue only proves polling; output explicitly says publication was unexercised. Delayed
debt and exhausted revisions are not healthy work. Projection debt older than the configured
120-second default threshold fails even when the worker heartbeat advances.

`read-scoring-query.sh` uses dedicated hosted configuration and a bounded, read-only PostgreSQL
client. It validates database/REST project binding, requires encrypted connection settings, never
prints connection credentials, and returns only the requested diagnostic state. The older
`check-sync-live.mjs` artifact inspector now queries this hosted client, but its legacy snapshot
canary is a narrow check; it does not replace the exact-version runtime checks or enrolled read.

Use the owner-scoped pipeline diagnostics for accepted, projected, queued, claimed, computed,
published and selected states. Phone acquisition/durability and decoded/displayed events need
actual phone observations; the server must not claim them from upload success. Null values with
unsupported RR timing, uncalibrated SpO2, absent coverage or failed reference qualification are
explicit capability/unavailable states, not evidence of a worker crash.

## Rollback

Cutover keeps prior containers by ID and retains prior environment/Compose files in a protected
`scoring-rollback.*` directory. Failed candidate acceptance stops only a container with the expected
deployment ownership and restores the prior lane's config/name/running state. A name race or
failed recovery is `Rollback incomplete`, with evidence retained for operator review. Never start
competing producers if candidate ownership cannot be established.

Rollback is lane-wise, not a distributed transaction: if a later lane fails, earlier accepted
lanes may still run the new release. Record the actual per-lane state and restore reviewed prior
identities deliberately. Do not infer overall success from any one lane's healthy heartbeat.

Do not roll back by replaying old migrations, mutating immutable results or starting an unfenced
old v1 binary. The compatible fallback is the reviewed patched baseline; keep an independent
archive-only process if v2 is stopped so durable archive debt can drain. Qualification/selection
changes require their own authority. Preserve additive schema and investigate with diagnostic
states before considering a separately reviewed forward schema repair.
