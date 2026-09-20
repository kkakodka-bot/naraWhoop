# Phase 3 gate investigation notes (working) 

## gate_run_1
cd scoring-service && ./gradlew :analytics-kernel:test :service:test :service:installDist --no-daemon -> BUILD FAILED

## gate_run_1_findings
- analytics-kernel: 771 tests, 1 failed (CurrentHrvTest.midWindowEctopicIsGapAware: expected 0.8 but was 1.017391304347826), 5 skipped (fixture-backed)
- service: 6 tests, 1 error (PostgresClientTest.normalizesPostgresqlUrlToJdbc -> InvocationTargetException: real Hikari connection to localhost)
- installDist: SUCCEEDED (service/build/install/service/bin/service exists)

## gate_run_2
cd android && ./gradlew testFullDebugUnitTest --tests com.noop.analytics.CurrentHrvTest --no-daemon -> BUILD FAILED

## gate_run_2_findings
- :app:compileFullDebugKotlin FAILED in ImuContinuousRecorder.kt (lines 500,505,575,579,596,725) + ImuSessionFileStore.kt (318,320,321,323)
- Imu files committed at 0da055e7 'Add Developer Options continuous 100 Hz IMU recorder for WHOOP 5/MG.' — NOT on main (829ee1d7)
- => branch-specific Android baseline compile failure; unit tests cannot compile at all
- Sept-12 prior run XML shows identical CurrentHrvTest failure on Android (expected 0.8 but was 1.017391304347826 at CurrentHrvTest.kt:47) => Android baseline failure, extraction is faithful

## gate_run_3
infra/vps/scripts/phase3-acceptance-checks.sh -> stops at step 1 (set -e on kernel test failure); VPS checks run manually

## vps_findings
- SSH OK (deploy@DROPLET_IP)
- migration applied: all 5 scoring tables exist (scorer_state, scoring_service_heartbeats, scoring_work_items, server_daily_scores, server_sleep_nights)
- supabase-scoring-1 container: Restarting (1) — crash-looping
- container log: HikariPool 'jdbcUrl is required with driverClassName' at PostgresClient.kt:15
- container DATABASE_URL set and byte-identical to .env SCORING_DATABASE_URL (sha match), starts jdbc:postgresql://postgres:...@db:5432/postgres
- deployed PostgresClient.class (3633 B) differs from local build (3595 B); deployed bytecode shows jdbcUrl = jdbcUrl (self-assignment getJdbcUrl/setJdbcUrl) => stale image built from buggy intermediate revision
- local code (jdbcUrl = resolvedJdbcUrl) works: local run reaches HikariPool Starting... then connection refused (expected)
- heartbeat row exists, last_poll_at/last_score_at NULL (container never polled successfully)
- VPS data: 26 users, 26 profiles, 29 devices, 1,575,456 noop_hr_samples, 115,018 noop_rr_intervals, 1,663 noop_signal_windows, 209 daily_metrics, 6 ingest tokens

## code_investigation
- DayScorer.score uses AnalyticsEngine.dayStartUtcSeconds(inputs.day) [UTC midnight] while discovery (discoverLocalDays) keys by user local day via profiles.timezone -> UTC/local mismatch (known failure #4)
- ScoringWorkQueue.discoverLocalDays/upsertWorkItem/selectDue/claimOne: keyed by (user_id, day) only — no device dimension (known failure #5)
- SignalSampleReader.loadDay picks loadPrimaryDeviceId = most recently seen device (order by last_seen_at desc limit 1) and reads all samples under that device (known failure #5)
- EngineIngestWriter.buildPayload: dailyMetric has no source_device_id; ServerScoreBundle has no deviceId -> score output lacks producing device (known failure #6)

