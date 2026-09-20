# VPS and shared physiology follow-up

This audit starts from PR 21 commit `28a6b32e0140507dc75ece23286db4c814bbd5bc`.
The original algorithm baseline remains `5caa31689da0023e111beb36850d3f81d67e1be2`,
and the original implementation was `5250912e5647108c548afa31b048ee4f4f6df133`.
See [the original independent audit](independent-audit.md) for the cumulative algorithm findings.
The repair ending SHA is the commit containing this report, recorded in the PR and final handoff.

## Confirmed operational cause

SSH was restored and independently verified as `deploy` on port 22 using the repository deployment
key at 2026-09-20 00:17 UTC. Earlier refused connections are historical, not a remaining blocker.
No root SSH login, password authentication, key replacement, or Recovery Console operation was used.

The only running scorer is `supabase-scoring-1`, image `frwhoop/scoring-service:latest`, image ID
`sha256:27041c79f8cb8e7fdab47eda6d32f6ff49a8232600062105c0da4d6102568590`.
It identifies itself as `frwhoop-server-1`, connects to local `db:5432` and `rest:3000`, has no OCI
revision label, and uses a process-only healthcheck. The local database has no v2 queue/result tables.
Its v1 poll advanced at 00:21 UTC; its last score was September 17. These are separate from the
hosted Supabase database used by the phone.

Hosted read-only inspection at September 19 23:53 UTC found 71 pending v2 jobs, no recorded poll,
and no score heartbeat newer than September 18 22:40:46 UTC. The VPS has no v2 container/image,
no `/opt/frwhoop/scoring.env`, and none of the dedicated hosted `SCORING_*` credentials in its
secrets file. Thus the hosted queue has no installed worker. Missing physiological inputs cannot
explain the absent poll: `ScoringPoller.pollOnce` records that heartbeat before reading inputs.

The host has four CPUs and approximately 8 GiB RAM, with roughly 5.9 GiB available during inspection.
The existing scorer used approximately 120 MiB in one sample. This is no evidence of CPU/RAM
exhaustion and is not a load benchmark. No Python executable exists inside the scorer, no model
mounts are attached, and no model checkpoint/activation files were found under `/opt/frwhoop`.
The current deployed service is not running a large learned sleep, respiratory, or step model.

A bounded hosted-data check for the connected test strap, September 19 22:00–22:05 UTC,
found 300 HR rows, 300 temperature rows, 300 original R-R packet receipts, zero projected R-R
intervals and zero SpO2 rows. Of the receipts, 279 declare zero interval words, 17 declare one
and four declare two: only 25 declared words across five minutes. All carry
`sensor-second-unmapped` clocks with one-second precision. This confirms that successful
second-by-second HR/temperature upload does not establish dense, timed beat observations or
oxygen measurements. This one bounded sample is not a claim about every time or device.
The actual production decoder validated all 300 stored receipts and recovered 25 nonzero,
numerically in-range intervals through `RrPacketObservationBridge`, despite the empty projected
interval table. Those intervals form four valid packet-local pairs but zero verified spans.
Running the actual estimators on these receipts returned HRV `timing_coverage_unverified` and
respiration `timing_unverified`. Thus zero **verified coverage** does not mean zero received
packets or intervals; sparse acquisition and unqualified timing are distinct remaining defects.

## Findings and disposition

No data breach, data loss, or unsafe physiological percentage was demonstrated in this incremental
pass. Safe abstention remains required. "Fixed" below means source repair with the stated tests;
it does not mean the running VPS or phone was changed.

| ID / severity | Requirement and exact evidence | Reproduction and impact | Narrow repair / required regression | Status |
|---|---|---|---|---|
| V1 / P1 | Hosted v2 must process durable arrivals. Live container identity/endpoints above; hosted `physiology_service_heartbeats.last_poll_at` is null. | Compare live Docker identity with hosted heartbeat and queue; phone gets `awaiting_result` despite successful ingestion. | Install the exact v2 image with hosted project-bound credentials; prove advancing poll and immutable publication, then owner-scoped client readback. | Deployment still required. |
| V2 / P1 | Other owners must progress during contention. `ScoringPoller.pollOnce` and `ScoringWorkQueue.peekOne`. | Original real-PG test: A holds a device gate, B receives zero input reads. First bounded repair still starved a ninth owner behind eight busy devices for two polls/32 seconds. | Skip active device leases and contended devices; retain an exact timestamp/identity cursor across cycles, then wrap. Tests hold all eight gates while ninth owner progresses; revising earlier jobs remains discoverable. | Fixed and tested. |
| V3 / P1 | Every canonical dependency must invalidate results. `SignalSampleReader.loadSkinTemp` and `CanonicalScorePayload.skin_temp_c` read/publish temperature; original revision migration omitted its table. | Actual migrated PG: temperature INSERT/UPDATE/DELETE left revision 1 unchanged; HR positive control advanced it to 2. Stale temperature could remain current indefinitely. | Add `20260919010000_skin_temperature_dependencies.sql`; existing shared gate/revision triggers, atomic catch-up of published v2 days. Test no-ops, old/new owner/date, rollback, contention and preserved snapshots. | Fixed and tested; migration not applied to production. |
| V4 / P1 | Optional shadow work must not stop canonical scoring. `PhysiologyShadowRunner.fromEnvironment` is called before heartbeat/poller construction. | Missing config raises `NoSuchFileException` during startup; malformed activation/Python settings likewise stop the worker. | Disable optional models with `shadow_configuration_unavailable`, keep deterministic lanes, redact configuration. Tests cover bad files/activation/Python, owner/revision flags and continuing respiration. | Fixed and tested. |
| V5 / P1 | Internal database ports must remain private. Live Docker and external TCP connect-only checks expose both 5432 and 6543. Existing `acceptance-checks.sh` prohibits public database bindings. | Both ports accepted TCP connections despite UFW permitting only 22/80/443. No authentication or database access was attempted. | Restore and verify effective loopback-only pooler bindings across explicit Compose overrides, then verify external connections fail. Do not rotate credentials or run unrelated legacy repair actions. | Source repair and 13 regressions passed; read-only plan passed against actual VPS files; live bindings unchanged. |
| V6 / P2 | Archive retry must remain independent and keep up with publication. `ArchiveRetryWorker` originally did one object per eight-second cycle. | At zero upload time, ceiling was 450 snapshots/hour; 38 users with one snapshot every five minutes already require 456/hour. This is a ceiling, not measured live archive debt. | Drain up to 32 ready objects per cycle, stop on idle/error, retain single bounded lane and per-object retries. Backlog/batch/failure tests plus real-PG outbox tests. | Fixed and tested. |
| V7 / P2 | Deployment must not depend on unrelated local stack variants or destroy rollback before acceptance. `deploy-scoring-service.sh`. | Original script assumed Caddy/Envoy overrides absent from fresh provisioning and removed previous workers before proving progress. Current VPS happens to have those overrides. | Standalone Compose project, immutable source/image tag, serialized cutover, retained old containers/env, project-scoped selection, rollback on failed acceptance. Stateful subprocess tests cover preflight/start/rename/acceptance failures. | Fixed and tested. |
| V8 / P1 | Cutover must preserve another project's worker. New rollback path was independently challenged during review. | Foreign container owns the fixed name; candidate name conflict could cause cleanup to delete that foreign container. No live action occurred. | Refuse foreign fixed names before cutover; remove only containers with this invocation's unique Compose project identity. Foreign-container regression preserves all workers. | Fixed before deployment. |
| V9 / P2 | Readiness must fail stalled/exhausted work, not merely observe a process. `verify-scoring-runtime.sh`, formerly inline in `phase3-acceptance-checks.sh`. | Exhausted/delayed rows were excluded so poll advancement could pass with no completed output. URI-only PGDATABASE also failed actual connections; mocked tests alone missed it. | Parse credentials into private PG environment, query read-only, require new score plus immutable publication for debt, report exhaustion/delay, enforce elapsed deadline. Real-PG connection/classification plus failure/privacy tests. | Fixed and tested. |
| V10 / P2 | A stalled input socket must not monopolize the serial worker after its separate input gate expires. `PostgresClient`. | Original driver socket timeout was zero. Actual test expires a separate gate then stalls on `pg_sleep`; deadline closes the input connection and a fresh backend succeeds. | Explicit connect/read/cancel defaults 10/60/5 seconds; operator URL options still override. This is an idle-read bound, not a whole-job deadline or guaranteed server-side cancellation. | Fixed and tested. |
| V11 / P1 capability gap | Five-minute WHOOP HRV and RSA need verified observed-time coverage. `PhysiologyQuality.checkedPackets` never supplies `verifiedSpan`; `HrvWindow` and `RespirationEstimator` correctly require it. | Actual serialized WHOOP packet test abstains with `timing_coverage_unverified`. Receipt ordinals/whole seconds do not prove beat clock or loss-free adjacency. | Qualify a sensor timing/continuity adapter against independently captured beat timing; retain original words and gap tests. Do not weaken coverage checks or invent timestamps. | Open acquisition work. |
| V12 / P1 capability gap | A displayed SpO2 percentage needs a verified source/calibration. `AnalyticsEngine` emits null; `Interpreter.swift` keeps optical byte82 diagnostic-only. | Dense HR and repeated scoring still produce no strap oxygen percentage. Imported valid readings are a separate supported path. | Verified/calibrated decoder or waveform source with device/reference validation; preserve unsupported state until then. | Open source/calibration work. |
| V13 / P2 | Requested frequent thermal series and learned steps are not implemented. `AnalyticsEngine` calculates nightly in-bed temperature and approximate cumulative steps; `CanonicalScorePayload` omits steps. | No five-minute server temperature series; server call supplies no personal thermal baseline, so deviation remains null. | Separate bounded thermal series/readback work; establish sensor interpretation and step reference measurements. Do not describe current estimates as learned-model outputs. | Open feature work. |
| V14 / P2 | Learned inference needs qualified inputs, installed pinned assets, rights and a matching assembler. `ScoringApplication` supplies no `JobAssembler`; deployed image has no Python/checkpoints. | Merely configuring a model returns `verified_model_input_adapter_not_configured`. Current sleep is an HR/motion engineering detector with fixed-coefficient staging. | Qualify clock/channels, checkpoints, preprocessing and license; execute only in shadow, then reference-test before any promotion. | Open model integration/validation. |
| V15 / P2 | Spec section5.2 requests immutable feature caching and affected-window recomputation. `SignalSampleReader.loadDayWithZone` and `DayScorer.score` reload/recompute full preceding/current day. | Every dirty revision repeats that work. No target-VPS sustained multi-user benchmark proves five-minute latency. | Add revision-bound window feature cache and measure fleet queue age, compute time, CPU/RAM and upload delay before sizing replicas. | Open architecture/performance work. |
| V16 / P3 | Model tests should handle macOS temporary-directory symlinks. `inference/tests/test_inference.py:test_asset_hash_and_path`. | `/var/...` vs `/private/var/...` failed equality despite correct resolved asset/hash checks. | Compare with `path.resolve()`; preserve traversal/hash assertions. | Fixed; 30 passed, 3 optional skips. |
| V17 / P2 | A failed network repair must preserve prior configuration. Fresh review of `14-pooler-network.py`. | Persistent disk exhaustion after the first edit also prevented allocation of a rollback temporary file. Disposable fault injection reproduced incomplete restoration; no live write occurred. | Fsync all private backups before edits; restore by renaming existing backups, preserve uid/gid/mode, retain and report any unrestored backup. Persistent-ENOSPC and rollback-failure tests. | Fixed before deployment. |
| V18 / P2 | Editing pooler bindings must not affect unrelated YAML aliases. Fresh review of `14-pooler-network.py`. | A service tagged as `!!map &shared` escaped the original anchor guard, allowing shared-node modification. Disposable Compose fixture reproduced it. | Check parsed node identity and reject ambiguous tags/anchors before writing. Tagged-anchor and unrelated-service preservation tests. | Fixed before deployment. |

Docker documents why published container ports can bypass UFW; the finding above additionally has
direct reachability evidence. [Docker firewall limitations](https://docs.docker.com/engine/install/ubuntu/#firewall-limitations)

## Storage, migration, isolation and scientific boundaries

The temperature migration changes triggers/queue revisions only. Raw samples and immutable
snapshots remain intact. Its pre-mutation guard refuses more than 10,000 distinct published
owner/device/days; larger installations need reviewed batch catch-up. Lock timeout is five seconds
and statement timeout sixty seconds. Active gate contention aborts atomically; quiesce scoring or
retry. Reapplying fails before duplicate catch-up. Tests verify these behaviors and both queue versions.

Queue tests use actual PostgreSQL functions for claim/renew/finish/publication. Busy rows remain
unchanged while another owner advances. Cursor tests preserve microsecond ordering, owner/device/date
tie-breakers and revision revisitation. Publication/lease/tenant guards were retained. No account-
specific fallback, measurement substitution or physiological threshold change was added.

Learned model results remain separate `modelResults` with owner/device/input-revision equality,
`publication_mode=shadow` and `canonical_outputs_allowed=false`; canonical metrics do not consume
those results. Deterministic experimental respiration is a separate code path. Missing observations
are not converted into zero HRV, sleep, sleep stage or oxygen percentage.

Five-minute windows describe event-time analysis. They do not establish five-minute BLE acquisition,
iOS background transfer, hosted upload completion, queue latency or valid measurement availability.
These repairs improve durability, fairness and operational visibility, not demonstrated physiological
accuracy. No ECG, PSG, respiratory reference or oxygen calibration dataset was validated in this pass.

## Verification and release gates

The final handoff records exact commands/counts and the repaired ending SHA. Durable evidence is under
`/Volumes/Untitled/physiology-audit/`; isolated PostgreSQL XML/data are retained in each harness directory.
Infrastructure tests use disposable files/processes and real Compose parsing; runtime SQL tests use
real PostgreSQL. No test requires production writes or copied credentials in fixtures.

Commands below ran from the repaired worktree. Gradle commands used
`JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home` and the
`scoring-service` directory. PostgreSQL harnesses retain their XML and disposable data directories.

| Command | Result and limits |
|---|---|
| `./gradlew :service:test :service:installDist --no-daemon --max-workers=2` | 220 discovered: 99 passed, 121 database cases skipped by this invocation, zero failures; installDist passed. Those database cases were run by the following harnesses. |
| `bash scripts/test-physiology-queue.sh` | 115/115 passed against real disposable PostgreSQL, including two socket-deadline cases, queue fairness, thermal migration, publication, tenant and archive behavior. |
| `bash scripts/test-runtime-preflight.sh` | 11/11 passed: five HTTP and six real PostgreSQL preflight cases. |
| `python3 -m unittest discover -s infra/vps/tests -p 'test_*.py'` | 39/39 passed: network 13, deployment 6, runtime acceptance 20; includes real PostgreSQL URI/debt checks and real Compose parsing. Fresh review independently reran the network and deployment suites. |
| `python3 -m unittest discover -s tests -p test_inference.py -v` from `scoring-service/inference` | 30 passed, three skipped: optional pinned NeuroKit ECG/PPG sources and Walch source were unavailable. No model reference validation is implied. |
| `swift test --filter HrvWindowTests` from `Packages/StrandAnalytics` | 7/7 passed; real serialized WHOOP packet still abstains without timing proof. No Swift production source was changed by this increment. |
| Shell syntax, Python compilation, `git diff --check` | Passed. Real Docker Compose parsing verified resource limits, no scorer ports and pooler loopback plans. |

Independent final review found and verified repairs for two defects introduced in the network
helper: persistent disk exhaustion during rollback, and a tagged YAML anchor affecting an unrelated
alias. Backup restoration now renames prewritten, fsynced files while preserving ownership/mode;
ambiguous anchors fail closed. Fault-injection tests cover incomplete rollback reporting. The final
VPS plan left checked configuration and credential files byte-identical and restarted no containers.

| Gate | State for this candidate |
|---|---|
| Systemic source repairs | Bounded worker, revision, deployment and network repairs implemented and reviewed |
| Unit tests | Passed for repaired worker/model/deployment paths |
| Integration tests | Disposable PostgreSQL queue, migration, publication, tenant and runtime checks passed |
| Target VPS inspected | Yes, SSH/containers/config/resource/model inventory read-only |
| Candidate worker on target VPS | Not deployed |
| Candidate phone readback | Not exercised against a running candidate |
| Sustained multi-user five-minute latency | Not measured |
| Overnight/device soak | Not run for this candidate |
| Reference validation | Not performed; required HRV/oxygen/model inputs remain incomplete |
| Deployed | No new service, migration, Edge function or network binding applied in this pass |

Recommendation: **needs another engineering pass**. Restore the hosted worker and verify actual owner-
scoped publications/readback, then qualify the missing physiological sources. Repository tests and
spare VPS capacity do not establish readiness for beta claims of frequent HRV/SpO2 or accurate learned sleep.
