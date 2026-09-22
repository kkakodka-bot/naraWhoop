# Independent acquisition/science and native contract diagnosis

Reviewed baseline: clean `/Volumes/Untitled/WHOOP NARA-release-integration` e499162 candidate; merge review performed in `/Volumes/Untitled/WHOOP NARA-server-repair`. Read `04_VPS_ALGORITHMS_SPEC.md`, integration server/compute handoffs and production pack `evidence/sensor_algorithms.md`. `02_SHARED_CONTRACT.md` and exact named `evidence/algorithms.md` not located in Downloads search. No production actions, reference qualification or physical acceptance claimed.

## First computed slice defect

`supabase/functions/tests/server_pipeline_sql_test.ts:209-269` real-worker fixture inserts 600 constant device-HR samples at noon; executes frozen v1 and physiology-v2, then asserts immutable revisions and three available feature envelopes while explicitly permitting null measurements. It does not assert one computed number from the real workers. Hand-created signed v2 fixtures earlier in this file exercise numerical decoder admission, not real worker computation. Add an existing baseline positive sleep/strain fixture with sufficient actual input and compare a non-echo computed metric through SQL, both authenticated routes, and both production native decoders. Keep baseline identity unchanged. The runner is `scoring-service/scripts/test-server-pipeline.sh` with BOTH real executable paths; omission tests SQL/API/decoder only.

## Actual remaining producer/input defects

* Registry has 27 families/80 outputs but only 8 numeric-capable families; 19 use nonnumeric disposition publication. `ComputeContractPublisher.kt` explicitly publishes nonnumeric state; this is useful missingness, not producer completion.
* `ppg_hr` has `canonicalNumericalProducer: null`, and registry details say historical worker reads previously phone-derived estimates. Final hosted mode retires phone estimator. A versioned raw-PPG server producer is implementation debt, distinct from optical timing/channel qualification.
* `VerifiedModelJobAssembler.kt` limits models to wav2sleep/neurokit, one PPG channel, and eight objects. `PhysiologyShadowRunner.kt:205-224` breaks after eight decoded objects/64 MiB and records a reason; there is no provenance-preserving paginated complete assembler. It can pass a partial list into preparation, where mapping presence often causes abstention. More small uploads can therefore block an otherwise complete night.
* `SensorAcquisitionProof.kt` requires every individual 300-second receipt to contain independent reference capture hashes and per-beat independently supplied endpoints. `VerifiedModelJobAssembler.kt` binds human review to exact owner/device/input revision. Neither is the required versioned cohort qualification plus deterministic ordinary-job adapter. Do not weaken timing checks or invent beat timestamps; missing target-device acquisition evidence remains real.
* RR_Estimation synchronized PPG/ACC production assembler remains unimplemented. 1 Hz gravity must not be upsampled to pass it. SpO2 remains blocked without suitable calibrated optical hardware/model/reference.

## Primary source check

Browsed pinned author source on 2026-09-22:

* https://raw.githubusercontent.com/kazemikianoosh/RR_Estimation/e429f1cc7fa25b56c2bd8d6674d7c25be25764b1/sample_code.py loads external preprocessed pickle arrays, transposes PPG/three ACC channels, rounds to four decimals, creates `(2048,4)` and declares 64 Hz. It does not define raw normalization. The local Python adapter matches tensor/rate/rounding and correctly requires the missing preprocessing contract. Full named paper preprocessing remains unverified.
* https://raw.githubusercontent.com/kazemikianoosh/RR_Estimation/e429f1cc7fa25b56c2bd8d6674d7c25be25764b1/tf_model.py exposes `Multi_class_CNN`, loaded by local adapter; no executed released checkpoint or target-reference proof was found in this review.
* https://raw.githubusercontent.com/joncarter1/wav2sleep/278e30463c8149c4e6899b8784da492fec695bd9/src/wav2sleep/data/preprocessing.py targets first grid sample at one sample interval, interpolates inside observed bounds, fills remaining missing with zero. Local adapter matches first-grid convention and explicitly abstains on gaps/downsampling without qualified antialiasing instead of reproducing fill/pad behavior. This is a declared adaptation, not exact complete paper reproduction.
* https://github.com/joncarter1/wav2sleep distinguishes cardio-respiratory four classes from EOG five classes; local adapter preserves four-class retrospective PPG task. https://github.com/harryjdavies/correncoder_ppg_respiration remains reconstruction/training rather than a calibrated RR producer.

## Merge review and checks

Resolved assigned BLEManager, IntelligenceEngine, VitalSignsSummary, StrandTests and Android UpdateStore conflicts semantically. Preserved account-bound capture/IMU bootstrap and onboarding/owner callbacks; adopted PR22 detached read-only restoration before archive/bootstrap, transport driver, setup leases, notification controller, batched post-commit presentation. Exact validated restoration identity is accepted before full registry bootstrap; other device callbacks remain rejected. Kept cancel/nil of integration startup task on disconnect, retirement and forget alongside new setup-lease completion. Removed duplicate wrist callbacks; the new raw-intent controller owns raw producer writes. IntelligenceEngine keeps final-hosted inference guards/counters plus PR22 resource-budget/pressure interruption gates and provenance-preserving timestamp-heal deferral. Test conflicts preserve strict receipt/object identity and explicit single-job resolution while using PR22 SQLite metadata and trailing injected budgets.

`swiftc -frontend -parse` passed all StrandTests and assigned Swift production files. Production BLE transport/notification/setup runner passed 47/47 with zero skips; `/Volumes/Untitled/server-repair-ble-native.log`. This runner does not compile the entire BLEManager app host or prove a physical device link. Full native build and combined-source tests are still required.

## Independent cross-review of other owners' merge

Root Database review: existing integration's 59 SQLite migration registrations/bodies/prefix remain in position; four PR22 v55-v58 migrations append after legacy aliases. Both oracle migration lists append those exact names. Do not infer actual existing-phone migration acceptance from registration identity alone.

Edge review: merged object creation/completion retains integration owner/source/auth-mode checks before synchronous or async receipt access; SQL current-receipt reader validates actual owner, manifest, byte/hash identity and matching indexed window. No new merge regression found in reviewed paths. Existing PR22 defect remains: `objectCompletionResponse` accepts an `async-v1` request header regardless of disabled `cfg.asyncObjectVerification`, allowing fresh durable verification debt when no continuously serviced consumer exists. Repair with explicit fresh-async admission gating while keeping old debt polling/draining available during rollback. This is queue/capability implementation work after the base freeze.

CloudUploadNative first compile found standalone fixture missing integration's strict objectKey helper. Repaired the fixture helper/default path/schema semantics without weakening production validation. Rerun PASS: 84 tests, zero failures, `/Volumes/Untitled/server-repair-cloud-native-rerun.log`; build/source receipts live in artifact directory printed on first line. Earlier first-compile log remains `/Volumes/Untitled/server-repair-cloud-native.log`.

Inspected retained synthetic worker artifact `/Volumes/Untitled/fwp/server-pipeline.hbaLfQ/decoders/worker-0.json`: all daily scalar values are null, with only available empty sleep-session array. This independently confirms the positive-worker-proof gap; that prior artifact cannot establish actual computed scalar readback.

## Design checkpoint: first computed positive slice

Executed a source-only design probe against the retained v1 binary packaged in frozen release `33a38c5167afec5beeadd700be714e89fa25fb57`, not a production service. External driver/result: `/Volumes/Untitled/server-repair-design-probe/SleepProbe.java` and `sleep-result.json`. It calls actual `DayScorer` and original `EngineIngestWriter.buildPayload`.

Use 2026-09-14 UTC, exactly 10,800 rows at one-second spacing from 01:00:00 through 03:59:59; HR bpm=52+floor(n/60)%3, gravity=(0,0,1) g. Empty RR, respiration, events, no invented beat clock. Default existing profile, WHOOP5. Actual frozen output: `sleep_total_min=179.98333333333332`, `resting_hr_bpm=53`, `sleep_efficiency=1`; sleep bounds 01:00:00 to 03:59:59. This is synthetic computational proof and is not observed/reference sleep. The v1 mapper intentionally discards strain/recovery/rest and cannot prove those as a retained-v1 slice.

Implementation plan after common base freeze:

1. Replace one worker-fixture's noon-only 600-HR input with the above HR+gravity data through existing `noop_project_append_batch` in bounded batches. Keep other three owned-device fixtures to preserve isolation checks. Retain duplicates-do-not-dirty assertion per source/batch.
2. Assert real default selected baseline job exists, execute actual frozen v1 executable, assert immutable publication's `sleep_total_min` equals the frozen oracle and >0. Never insert a synthetic result or approval for this case; retained legacy manifest/qualification stays as is.
3. Read selected SQL device-day result, actual enrolled handler and account handler; assert equal metric value, device, algorithm and immutable revision. Serialize those unchanged bytes to separate fixture artifacts and add `expectedValues.sleep` and canonical `sleep_total_min`/`sleep_efficiency` (percent=100) expectations.
4. Run production Swift/Kotlin decoder+cache selection runner. It already supports these expected numeric fields. Require identical persisted immutable family revision and selected duration, plus existing local-inference counter checks.
5. Label account-provider limitation: current disposable fixture stubs `/auth/v1/user` to owner; actual account handler+SQL execute but Auth provider validation does not. Hosted account auth and actual phone UI remain later authorized acceptance. Enrolled fixture uses real installation/fleet token lookup.

## Design checkpoint: complete bounded raw assembly

Current source has two independent truncation boundaries: generic `RawSignalCatalogue.discover` silently limits 256 rows (2,048 for explicit IDs), and shadow runner stops after eight decoded objects. Its byte cap is 64 MiB; incomplete-budget reason does not categorically prevent assembler/executor.

Preferred repair uses acquisition contract as immutable input plan before storage I/O. Resolve and validate exact owner/device/revision/model/checkpoint/preprocess/scope once; extract its required object IDs and physical mappings. Query all required manifests through indexed bounded pages, on one short repeatable-read metadata snapshot (no network reads inside transaction). Require found IDs equal planned IDs, reject duplicates/missing/invalid manifests, and retain exact key/digest/source/size/window evidence. Existing revision/activation/lease finish fences remain unchanged and reject inputs superseded during asynchronous I/O/inference.

Read/verify one object at a time into existing bounded arrays/assembly, preserving physical-record dedup, declared gaps and ordered time grid. Remove the object-count-eight limit; retain maximum decoded byte/sample/payload/time budgets and fail the whole model request explicitly when a budget prevents completeness. Do not execute on the first page/list prefix. The existing bounded 2,048-ID evidence contract can remain a declared admission limit until a measured spool/stream extension is needed; do not silently ignore extra contract records. Unrelated sensor objects must not consume a model's selected-input budget.

Tests: positive identical tensor from 1, 9, 257 small objects; adversarial duplicate physical packet with same/conflicting bytes, missing middle page, scope/firmware/wavelength mismatch, equal sort-time pagination tie, object-key/digest change during read, budget overflow returns explicit incomplete input with executor count zero, cancellation frees slot, newer input revision during slow fetch/inference fails publication while ingestion succeeds. Record max resident memory/elapsed bytes and object counts for these fixtures; no target-VPS capacity conclusion. Keep deterministic producer independent and all optional models shadow.
