# FRWHOOP scoring service

W3 uses transactionally enqueued work, unique renewable leases, immutable per-device snapshots,
and independent archive jobs. Apply the additive migration
`20260918010000_production_scoring_durability.sql` and review repair
`20260918030000_production_scoring_review_repairs.sql` before starting this worker.
Existing RPC signatures remain available. The legacy `engine_ingest_scored` compatibility wrapper
serializes with v2 publication and ignores v2-owned keys (including pending keys and sleep start-key
conflicts). Its private implementation is not executable by service/app roles. The v2 worker always
publishes through its lease/input-generation fence.

Readback integration: [SNAPSHOT_V2_CONTRACT.md](SNAPSHOT_V2_CONTRACT.md).

## Native verification

From this directory, with Java 17:

```sh
./gradlew :analytics-kernel:test :service:test :service:installDist --no-daemon
```

The service suite starts a NEW disposable PostgreSQL cluster bound only to 127.0.0.1.
It never uses DATABASE_URL. Set `W3_TEST_PG_BIN` to a PostgreSQL binary directory
(default `/opt/homebrew/opt/postgresql@18/bin`) and optionally `W3_TEST_ARTIFACTS`
to retain its cluster/logs. Migration edits are test-task inputs. Auth plumbing is a minimal
local fixture; queue/results/projection migrations execute on real PostgreSQL.

The kernel is reserved for W4. Its native suite is a regression gate, not proof of end-to-end
Swift input/visible-result parity; fixture-dependent skipped tests are not passes.

## Runtime

`DATABASE_URL` is required. B2 configuration remains optional; without it, immutable archive
debt stays pending in PostgreSQL. The old INGEST_SECRET, SUPABASE_URL and service-role HTTP key
are no longer consumed by the v2 production entrypoint.

`SCORING_ALGORITHM_VERSION` defaults to `frwhoop-server-1`. Registration schedules existing
history in bounded ranges but does not activate a new readback version.
`SCORING_POLL_SECONDS` defaults to 8 and must be 1–3600.

Each pass repairs a bounded legacy batch, expands a bounded invalidation batch, reconciles missing
enabled-version/day pairs (including first inputs committed after registration), claims only
one immediately runnable score, and attempts one independent archive job. Long compute/PUT
operations renew their own lease. Retry delay grows exponentially to one hour; scoring enters
inspectable dead letter after 8 consecutive failures, archives after 12. New score generations
reset score failure debt. Archives never require rescoring.

`--replay-day` / Gradle `replayDay` requires REPLAY_USER_ID, REPLAY_DAY and REPLAY_DEVICE_ID
(device may be omitted only for a single-device user). It enqueues a new generation and runs
one bounded normal worker pass. It is NOT a synchronous completion guarantee: inspect the
queue/read RPC for the requested revision; normal workers finish remaining debt.

## Repair and observability

Service-role-only operations:

- `repair_legacy_scoring_v2(limit)`: resumable, idempotent import of old work, prioritizing
  stranded attempts >= 8; applies to every enabled version.
- `reconcile_scoring_versions_v2(limit)`: repeatable anti-join repair across known work days and
  enabled algorithms, at most 1,000 inserted pairs per call. Existing revisions and leases are
  unchanged. Worker maintenance invokes this every pass; no additional phone upload is needed.
- `reconcile_scoring_days_v2(user,device,from,through,limit)`: explicit audited date scope,
  at most 31 days/call. Scans actual input presence, inserts only missing jobs and returns
  nextDay/done/repaired. It never dirties existing results. Repeat calls are idempotent.
- `invalidate_scoring_history_v2(user,device,from,through,reason)`: durable ranges for known
  corrections to existing history; expansion is bounded. W4 must define historical horizons.
- `retry_scoring_archive_v2(resultRevision)`: retry the same committed bytes after fixing
  the failure cause. Cannot steal an active lease or resubmit a completed archive.
- `scoring_queue_metrics_v2`: queue/archive/invalidation ages, failures, backlog, claim/renewal
  counts and last-duration mean; heartbeat meta records the metrics each pass.

Projection/index triggers cover inserts, corrections and deletions, excluding identical
transport-metadata retries. The input window is [wake-day start minus 30h, day end]; input changes
invalidate their local dates plus two wake days. Large spans and profile/version changes use
durable range cursors. Scheduling favors least-recently-served users, current days and old backlog.
Representative fleet-scale latency/load validation is still a rollout gate.

## Snapshot/archive boundary

Snapshots are keyed by owner/device/day/algorithm/input revision; server result revisions are
monotonic. Snapshot insertion, archive debt, queue settlement and selected-source legacy
replacement commit together. Source choice is explicit preference or lowest owned device UUID,
never completion order. Snapshot UPDATE is rejected.

Archive bytes are committed PostgreSQL JSONB UTF-8, uncompressed, under:

```text
v3/derived/users/{user}/devices/{device}/days/{day}/{algorithm}/revisions/{revision}.json
```

Retries use identical bytes and keys. The signed PUT binds the payload checksum; database
settlement validates hash/size against the immutable snapshot and fences the manifest write.
Local tests use a fault-injected object client, not production B2.

## W4 boundary

Reader fixes include repeatable-read input consistency, window-local unknown-family evidence,
canonical RR-channel filtering,
suspect/SpO2-IBI exclusion and full calendar-day reads. Writer uses grouped main-night selection,
stable sleep IDs, complete stage arrays and authoritative nulls.

Historical baselines/checkpoints, learned sleep need/debt/consistency, deterministic edits,
all remaining visible metrics/additional streams, HR-only orchestration and true DST semantics
inside the kernel remain W4. Current results explicitly report partial coverage; no physiology
or cutover readiness is inferred from W3 green tests. No analytics-kernel source was edited.

## Packaging

Build Docker from the repository root so the kernel can sync its Android twin:

```sh
docker build -t frwhoop/scoring-service:latest -f scoring-service/Dockerfile .
```

That legacy developer command and the no-argument VPS deploy script remain available, but are
**NOT_READY for immutable production-sync image acceptance**. They do not establish an exact
committed source export or registry provenance. A mutable-image failure is never a fallback from
the explicit pinned path below. The final-stage OCI revision label is empty unless `VCS_REF` is
supplied; a label alone is not authenticated provenance or evidence that tests ran.

### Explicit immutable image path

`infra/vps/scripts/scorer-image-release.mjs` separates offline preparation/validation from
publish/deploy operations. Nothing here authorizes registry access, Docker execution or deployment.
Root reserves the native workspace and runs the existing phase3 `--local` command unchanged.

Offline preparation requires a full local commit, explicit `linux/amd64` or `linux/arm64` platform,
digest-qualified JDK/JRE references and a separately recorded native-evidence JSON. Output must be
a new directory on the external artifact volume, not an existing worktree. For example, with all
`SCORER_*` values explicitly selected by the operator:

```sh
node infra/vps/scripts/scorer-image-release.mjs prepare \
  --repo "$PWD" --commit "$SCORER_COMMIT" --output "$SCORER_PREPARED_DIR" \
  --platform "$SCORER_PLATFORM" --build-image "$SCORER_BUILD_BASE" \
  --runtime-image "$SCORER_RUNTIME_BASE" --native-evidence "$SCORER_NATIVE_EVIDENCE"
```

Preparation reads local Git objects only, never fetches, and rejects partial/promisor/alternate
object stores and included Git configuration. It exports an allowlisted tracked source inventory,
not dirty/untracked files, caches, build products, `.env`, keys or local configuration. Symlinks
are rejected. Limits are 4 MiB per source blob and 256 MiB aggregate. Binary wrapper bytes and
tracked executable modes are retained. Missing required source roots/wrapper files fail closed.

The native JSON has `schemaVersion:1`, `inputFiles:[{path,sha256}]` and nonempty
`reports:[{path,sha256}]`. `inputFiles` must match **all exported inputs except the Dockerfile**;
reports are relative, bounded regular files alongside that JSON. This is byte-identity binding,
not a test-result generator: the operator/reviewer must establish what actually ran, against which
fixtures and with what result. A Git commit label cannot replace this independent record. Source
identity includes a separate `nativeInputSha256`; changing only packaging need not relabel tests.

Only after separate build/publish approval:

```sh
node infra/vps/scripts/scorer-image-release.mjs publish \
  --prepared "$SCORER_PREPARED_DIR/prepared.json" --output "$SCORER_RELEASE_DIR" \
  --repository "$SCORER_REPOSITORY"
```

This operation invokes Docker/registry commands; it is **not** an offline check. It builds a private
validated context snapshot once using pinned bases and revision, pushes a unique transport tag,
then resolves by digest. A registry/index digest, selected platform-manifest digest and Docker
config ID are recorded separately. Indexes must have exactly one matching OS/architecture child
without a variant; unsupported/ambiguous descriptors fail. Digest verification tolerates only a
single CLI-framing LF whose removal produces the declared digest, never JSON reserialization.
The pulled image's own label/config/platform/RepoDigest must match. Only then is `release.json`
published atomically without overwriting an existing release; partial diagnostics stay unqualified.
No registry login is performed by the helper. Builder/registry compatibility and credentials must
be qualified separately; offline mocks do not establish a real build or authenticated provenance.

Validate an existing release bundle offline with `validate --manifest <release.json>`. The output
means internal consistency, not reviewer approval, reproducibility, deployment or release readiness.
Retain the complete bundle, including descriptor bytes, source/native inventories and report bytes.
The build-context and raw builder metadata directories are local diagnostics, not acceptance inputs.

After separate deployment approval, `deploy-scoring-service.sh --image-manifest <release.json>`
validates offline before loading the existing host selector. Supply `SCORER_KNOWN_HOSTS` explicitly.
It requires the existing configured Compose deployment and running `db`/`rest`; it does not provision
them or rewrite secrets. It pulls/verifies the pin, retains a non-secret digest override and manifest,
then uses `up -d --no-build --no-deps --pull never scoring`. No source rsync/rebuild/latest fallback.
It verifies the selected full container ID and image association but does not auto-authorize that
ID for acceptance. Retain/review a fresh independent selector. Use the same retained override file
set for later pinned operations; rollback requires separate approval and a previous retained bundle.

See the [validation runbook](../production%20sync%20docs/VALIDATION_RUNBOOK.md) for the stricter schema-2
`server.imageProvenanceArtifact` requirement and the separate offline test command.
