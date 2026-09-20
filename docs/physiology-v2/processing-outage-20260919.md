# September 19: uploads without physiology results

Updated by [the VPS audit](vps-systemic-audit-20260919.md): SSH access was restored and verified
as `deploy` on port 22 at 2026-09-20 00:17 UTC. The previous access blocker is resolved. The live
machine runs only the old v1 worker against its separate local database; no hosted v2 worker is
installed. The observations below describe the earlier investigation before guest access.

This follow-up starts at PR 21 revision `715df5b7dc74aa3730f087792b9ab8ca0ee7af43`.
It repairs shared worker configuration and deployment behavior. It does not add a user-specific
exception, relax physiological quality requirements, or establish functioning WHOOP HRV/SpO2.

## Confirmed live state

Read-only inspection at 2026-09-19 19:08 UTC found 71 pending physiology jobs, no claims or recorded
failures on those jobs, and a null `physiology_service_heartbeats.last_poll_at`. The most recent
score heartbeat was 2026-09-18 22:40:46 UTC. There were ten immutable v2 snapshots in total, the
latest computed at 22:40:42 UTC the previous day, and no snapshot for the tested device/day.
The connected phone still had NARA 11.1.1 build 354 installed.

`ScoringPoller.pollOnce` records its poll before reading physiological data. Missing R-R timing
cannot explain the absent poll. The `awaiting_result` RPC state correctly reflects absent published
results; the phone was not hiding a calculated September 19 sleep/HRV snapshot. At that inspection,
the VPS image, environment and logs had not yet been observed. The subsequent SSH investigation
linked above establishes the actual deployment mismatch. No production deployment or data write
occurred in this earlier follow-up.

A bounded aggregate coverage query exceeded its eight-second read-only timeout and returned no
coverage result. This investigation does not infer current input coverage from that uncompleted query.

## Findings and changes

| Finding | Evidence and reproduction | Repair | Status |
|---|---|---|---|
| P1: shared scorer is not processing hosted debt | Live pending queue and absent poll above; no new-day published result | Restore the persistent worker with matching hosted configuration, then prove poll and publication progress | Operationally blocked on guest access and release approval |
| P1: an environment variable silently selects one-shot mode | `ScoringApplication` previously chose replay whenever `REPLAY_USER_ID` was set, even with no arguments | No arguments always mean persistent service; `--replay-day` explicitly selects replay. Tests cover complete, partial, blank and invalid leftover replay variables | Fixed in source; not proven to be the deployed cause |
| P1: encoded database credentials are sent literally | `PostgresClient.parseUserInfo` previously passed `%40`, `%2F`, etc. unchanged to JDBC | Decode URI userinfo once, preserve literal `+`, sanitize malformed escapes | Fixed in source; not proven to be the deployed cause |
| P1: deployment mixes hosted destinations with a self-hosted key | VPS provisioning creates generic `SERVICE_ROLE_KEY` for its own Supabase; deployment used it with `SCORING_DATABASE_URL` and hosted REST URL | Require dedicated hosted service-role and ingest credentials. Candidate checks project binding, migrations/functions, secret and authenticated REST access before cutover | Fixed and tested |
| P2: deployment can remove a worker before discovering invalid Compose/env configuration | Independent reviewer reproduced missing `b2.env`: preflight passed, worker removed, then Compose failed | Preflight uses both final env files; validate Compose with candidate env before changing the old env or removing containers | Fixed; failure tests preserve worker/config |
| P2: ingest verification hides absent v2 scoring | Prior report used only the legacy heartbeat and ingestion `complete` | Add owner/day-scoped `physiology_processing`; retain `complete_scope: ingestion_only` | Fixed; exact never-polled/awaiting-result case covered |

`--check-config` uses a read-only database transaction and one bounded authenticated heartbeat GET.
It does not initialize the worker, claim jobs, publish results or update a heartbeat. It rejects
unproven custom-domain binding, mismatched projects, missing migrations/functions, invalid auth,
redirects and oversized/malformed responses. Failures expose fixed stage codes, not credentials,
response bodies or raw database exceptions. The actual built candidate passed this read-only check
against the hosted project using the supplied credentials. This verifies the candidate from the
development machine, not the VPS environment or continuous operation.

The new diagnostic code was also executed locally against read-only hosted REST data. It returned
`worker_never_polled`, two pending owner/day work items, and `awaiting_result` for sleep, HRV and
respiration, with no computed timestamps. No physiological values or identifiers were printed.

The misleading process-name Docker healthcheck was removed. Deployment acceptance still requires
advancing database poll/publication timestamps. No algorithm, source-selection, tenant, revision,
lease or archive policy is weakened. There are no new migrations or stored-data rewrites.

## Feature limitations remain open

Sleep detection has an independent HR/motion path. The rerun sleep/scorer tests demonstrate that
empty R-R input does not prevent sleep detection and does not suppress publication of unavailable
five-minute HRV windows. This is implementation evidence, not a guarantee about a particular night.

Every current WHOOP R-R adapter still leaves `verifiedSpan` absent. Packet-local interval words and
host arrival time do not establish the subsecond sensor clock, missing-beat behavior or continuity
required by five-minute HRV and R-R-derived respiration. The retained paired hardware fixture has
synthetic timestamps and cannot qualify that contract. An experimentally qualified source adapter
remains necessary. No five-minute WHOOP HRV capability should be advertised as complete.

Calibrated WHOOP SpO2 has no supported source in the current decoder/analytics path. Unresolved
optical byte fields remain raw candidates. Imported saturation readings retain their existing
separate path. No fabricated percentage, waveform-derived guess, or learned shadow result was
promoted to fill the gap. All learned models remain shadow-only.

## Verification

- `./gradlew :service:test :service:installDist --no-daemon --max-workers=2`: 198 tests discovered;
  92 passed, 106 database cases skipped in this run, zero failures. Installed distribution built.
- `bash scripts/test-physiology-queue.sh`: 100 disposable PostgreSQL integration tests passed,
  zero skips, including revision/lease fencing, continued arrivals, publication, and isolation.
- `bash scripts/test-runtime-preflight.sh`: 11 tests passed, zero skips: five HTTP/binding cases
  and six actual PostgreSQL read-only/auth/schema cases. Database mutation attempts fail and
  sentinel rows remain unchanged.
- `python3 -m unittest discover -s infra/vps/tests -p test_scoring_deploy.py -v`: four passed,
  including missing hosted key, wrong-auth preflight, missing B2 env, invalid Compose and correct
  hosted-key selection. Invalid candidates preserve the old worker/configuration.
- Edge suite: 98 passed, zero failed.
- Independent input review reran 16 Swift HRV/respiration cases and four protocol cases. These
  confirm safe abstention and retained raw evidence, not valid device HRV/SpO2 measurements.
- Independent sleep review reran 12 sleep/scorer cases, zero skipped.
- `git diff --check` and Bash syntax passed. ShellCheck reports the existing SC1090 dynamic-source
  warning in the deployment script.
- Fresh reviewer reproduced the Compose cutover defect, verified its repair, reran deployment
  behavior tests and real Compose parsing, and found no remaining confirmed blocker in this diff.

Evidence is retained outside Git under `physiology-audit` and `readings-investigation-20260919`.
No credentials, application databases or raw user health fixtures are included in this change.

| Acceptance gate | State |
|---|---|
| Worker/diagnostic source repairs | Implemented and tested |
| Candidate read-only hosted configuration | Passed from development machine |
| Current VPS process/configuration inspected | Blocked on guest access |
| New worker/diagnostics deployed | No; original no-deploy instruction still applies to this revision |
| Sustained scoring and archived publication on real uploads | Not verified |
| Qualified five-minute WHOOP HRV / respiration | Incomplete acquisition adapter |
| Calibrated WHOOP SpO2 | Incomplete source/calibration |
| New phone build required by this patch | No; server/operations changes only |
| Overnight soak / independent physiological reference validation | Not performed |

Recommendation: **needs another engineering pass**. Restore shared processing for sleep and truthful
window results first, then qualify the acquisition inputs before beta claims about frequent HRV,
respiration or blood oxygen. Passing repository tests is not physiological or release acceptance.
