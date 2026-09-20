# W3 snapshot contract for root/readback integration

Migration: `20260918010000_production_scoring_durability.sql`. Existing RPC signatures remain available.

Authenticated read: `get_server_score_snapshot_v2(p_day date, p_algorithm_version text default null)`.
The owner comes exclusively from `auth.uid()`. Null version selects the controlled active pointer in
`scoring_algorithms_v2`. Registration enables computation; it does not activate a new client version.

Top-level snapshot fields: `schemaVersion` (2), `userId`, `algorithmVersion`, `sourceDeviceId`, `timezone`,
`day`, `inputRevision`, `resultRevision`, `computedAt`, `dataThrough`, `coverage`, `status`, `daily`, `sleep`.
Timestamps are ISO-8601. Revisions are signed 64-bit integers. `daily` retains the existing snake_case
metric vocabulary. `sleep` contains the COMPLETE replacement set, stable UUID `id`, `start_at`,
`end_at`, `is_nap`, duration/stage totals, and `stages: [{start,end,stage}]` with epoch-second bounds.
An empty sleep array removes the previous machine-derived set for that source/day/version.
Null metrics are authoritative unavailable values. They must not be replaced by zero or stale local metrics.

Completed snapshots have `status` = `partial`, `available`, or `no_data`. The current JVM producer uses
`partial` whenever observations exist because historical algorithm orchestration is not yet complete.
`coverage.gaps` lists missing inputs/policies; sample counts are observations, not completeness estimates.

Readback adds `requestedInputRevision`, `pending`, and `archiveStatus` to a completed immutable snapshot.
`pending` means later input or a durable invalidation range remains outstanding: keep cached results
with that status until the next revision. A first result returns `pending` (or `failed` for dead-letter
work), with null daily/result revision and empty sleep. An unsupported algorithm returns a tagged
`unsupported` response; the client must not treat it as an authoritative empty result.

Source selection: an explicit owned device in `scoring_source_preferences_v2`, else lowest owned
device UUID among that day's jobs. It never depends on scorer completion order. A preferred source
with no result stays pending. Service-only `set_scoring_source_v2(user,device)` validates ownership
and schedules affected days. Readback does not merge devices.

Publication: `publish_scoring_snapshot_v2(token,input_revision,payload,duration_ms)` locks the job and
checks the live lease and exact input revision, including outstanding range invalidations. In one
transaction it inserts the immutable snapshot, records archive debt, settles the job, and replaces
the selected source's legacy score/sleep projection. Returns server result revision or SQL NULL for
lost/superseded work. `scoring_snapshots_v2` rows cannot be updated.

Archive identity: `v3/derived/users/{user}/devices/{device}/days/{day}/{algorithm}/revisions/{revision}.json`.
Bytes are the committed PostgreSQL JSONB serialization encoded as UTF-8, without recomputation or
compression. The immutable revision includes the full payload; storage retry remains independent of
score retries. The signed B2 PUT binds the body SHA-256; manifest/queue settlement is token-fenced.

Historical inputs still unavailable: ordered baseline checkpoints, learned need/consistency/midsleep,
recalibration epochs, server-applied sleep edits, and additional physiology streams. The reserved
analytics-kernel also retains fixed-offset day attribution and its internal HR-only helper. W3 does
not assert Swift parity or activate ownership for those fields. `invalidate_scoring_history_v2`
provides a bounded durable replay range once W4 defines each dependency horizon and checkpoint rule.

Edge integration: projection/index mutations enqueue affected days transactionally via statement
triggers. Edge retains ownership of raw object digest verification and ready-manifest/index repair.
The raw-object index trigger invalidates the full indexed span plus the next two wake days.

Native tests: from `scoring-service`, run
`./gradlew :analytics-kernel:test :service:test :service:installDist --no-daemon` with Java 17.
`W3_TEST_PG_BIN` selects a local PostgreSQL binary directory, never a database URL.
`W3_TEST_ARTIFACTS` selects the directory retaining the disposable cluster/logs. The test harness
creates a new cluster, binds only 127.0.0.1, and shuts that cluster down at test JVM exit.
