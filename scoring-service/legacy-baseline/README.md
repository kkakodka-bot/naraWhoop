# Frozen v1 scorer with fenced transport

This package builds the numerical baseline at exactly
`5caa31689da0023e111beb36850d3f81d67e1be2` with a small queue/publication transport patch.
It remains `frwhoop-server-1`. It does not relabel the v2 kernel as v1 or promote shadow algorithms.

`transport.patch` changes only the baseline application wiring, work queue, lease renewal,
publication transport, retirement of the old mutable archive writer, and transport tests.
The entire Android tree, analytics-kernel source/configuration, DayScorer, input reader,
UserDayBounds, and original result mapping remain byte-identical to the baseline.
The builder archives the exact Git commit, rejects any other input checkout HEAD, refuses an
existing output directory, permits only the reviewed transport file paths, and hashes all other
baseline files before/after applying the patch. It separately pins the unchanged result mapper.
A dirty input checkout cannot enter the build: `git archive` reads committed baseline bytes only.

## Build without deployment

Use the existing Java 17/Gradle toolchain. `--context` must name a new directory outside a source
checkout. Dependencies and container base images still follow the baseline build; these commands
reproduce the pinned source plus transport patch, not a claim of bit-identical binaries.

```sh
python3 scoring-service/legacy-baseline/build.py \
  --repository '/path/to/exact-baseline-checkout' \
  --context '/scratch/new-baseline-context' --build
```

`--build` runs the unchanged baseline kernel suite, service suite, and `installDist`. Without a
disposable database, six explicit legacy integration cases skip; they are not passes. To execute
them, first create the repair branch's disposable PostgreSQL schema through migration
`20260918120000_fenced_baseline_transport.sql`, then set `PHYSIOLOGY_TEST_DATABASE_URL` to that
localhost `physiology_queue_test` database before building. Never use a deployed database for tests.
The queue migration suite separately covers more than 350 revisions, v1/v2 independence,
publication races, owner/device fences, and archive retries.

Append `--image frwhoop/scoring-baseline-fenced:reviewed` to build a local Docker image after tests
pass. The builder never starts, pushes, or deploys that image. Inspect the resulting
`baseline-transport-provenance.json`, test XML, patch hash, and image identity before authorized use.

## Runtime contract

The patched worker claims exactly one runnable v1 item before computing. The existing serial poll
budget stays bounded at eight completed items per cycle. Data-triggered work and explicit replay
use `scoring_legacy_claim_one`, `scoring_legacy_renew_lease`, and `scoring_legacy_finish_work` on the
baseline lane. The claim binds user, physical device, day, input revision, lease token, and run ID.
Renewal runs during input loading/scoring; any renewal failure permanently fences that run locally.
The publication transaction rechecks ownership and expiry under a row lock, so a check/publish race
cannot authorize stale data. Every completion/wait/failure carries the same token; an old worker
cannot release its successor's lease. Missing input enters waiting without consuming a failure.

`engine_publish_legacy_fenced` receives the original v1 metric/episode envelope plus claim identity.
It preserves original baseline arithmetic, records immutable v1 snapshots and archive debt, and
keeps v1 work independent from the v2 shadow lane. The old `engine_ingest_scored` entry and direct
queue mutations reject unpatched workers once the fence migration is installed. The v1 worker
refuses a different algorithm-version configuration.

Original mutable-key B2 publication is retired. The repaired service's archive worker drains the
shared durable outbox for either version. During a baseline-only rollback, run its `--archive-only`
mode alongside the patched baseline image; this executes archive retries without v2 scoring.
PostgreSQL results remain usable when B2 is unavailable and archive status remains pending/failed.
Do not use the old baseline binary against the fenced schema.

This source package does not authorize migration, container replacement, or deployment. Stop
unpatched workers before an authorized migration and start the reviewed patched baseline binary
with the independent shadow worker only after exact-version integration checks. Preserve existing
results, raw inputs, and immutable archives. Numerical baseline defects remain the baseline;
transport hardening does not make it physiologically validated.

## Evidence

The isolated baseline build preserves the original kernel (746 reported tests: 741 pass and five
unavailable private/reference fixtures). Five transport behavior tests exercise the actual request
serializer, owner/device/day/version mismatch rejection, error redaction, running renewal and
permanent loss fencing. Six disposable PostgreSQL cases cover queue wrappers and the actual
baseline replay -> original scorer -> request serializer -> fenced SQL publication path, plus
superseded replay and immutable archive debt. See the overall repair verification report for exact
commands/results; no device run, overnight soak, reference qualification, image deployment or
production endpoint is implied.
