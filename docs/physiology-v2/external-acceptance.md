# External acceptance and rollout gates

These gates are **NOT_READY** until their own evidence exists. The implementation and local synthetic tests do not satisfy them. This task did not launch an app, interact with a strap, replace a phone database, deploy migrations/services, promote a model, or enroll a cohort. The instructions below are a handoff, not an action already performed.

## 1. Authorized acquisition and locked-phone soak

Obtain explicit approval for the exact phone/strap and test session. Record the tested source commit, signed build identity, phone OS, physical device identifier, strap family/firmware, battery levels, acquisition settings and existing preferences. Preserve a recoverable DB/WAL/SHM and preference snapshot before any later data restoration; restoration requires separate permission. Do not reset a database or change undocumented BLE commands for this test.

Use only the existing supported acquisition controls. Include a prespecified daytime resting period and full overnight locked-phone/background period, followed by disconnect/reconnect and completed history backfill. Record actual event-time density, battery change, pauses, off-body intervals, incoming packet identity/counters, durable local receipts, receiver projection revisions and server observed-through/computed times. Retain raw evidence and exact settings restoration. Duplicate/late replay must not lose same-second PPG identities, double-count original intervals, erase overrides, or create an apparently current score from stale inputs.

No five-minute background-delivery SLA is assumed. A host build, ACK, enabled toggle or elapsed overnight interval is not acquisition continuity. The iOS raw compression path needs a supported-device round trip. Current missing corpus/private-phone-copy test fixtures remain separate acceptance inputs, not successful skips.

## 2. Beat clocks, raw channels and per-night inventory

Run the [read-only signal inventory](acquisition.md#executable-ownernight-inventory) on explicitly authorized data for each owner/device/night. Keep the report and input snapshot identities. The tool reports event-bin occupancy and catalogue claims separately from verified observed time. Unknown sample rate, wavelength, clock error, IMU units/orientation or alignment must stay unknown.

For raw-dependent models, independently retrieve the exact referenced bytes with bounded reads, verify the proper compressed/uncompressed digest convention, decode every record, retain observed masks and qualify clock/channel/alignment semantics. A catalogue `verified` flag is not proof that an object is currently readable or that local pruning was safe. Do not enable a waveform candidate until the local-retention/archive guarantees required by that candidate are demonstrated.

The new checked WHOOP packets preserve original word identity and local adjacency; they do **not** establish subsecond beat endpoints or cross-packet continuity. Supply a synchronized, auditable acquisition-clock mapping with measured uncertainty and original beat linkage before asserting five-minute HRV or RSA coverage. Neither numerical interval sums nor a firmware catalogue entry can supply that proof. Unqualified historical data remains unavailable; do not retroactively convert unknown WHOOP 5 units or manufacture timestamps.

## 3. Independent physiological reference evaluation

Supply reviewed, consented datasets and hashes: adjudicated synchronized ECG R peaks/NN reference for HRV, scored PSG epochs plus independently timestamped opportunities/quiet-wake behavior for sleep, and synchronized airflow/capnography or qualified effort reference for respiration. Vendor imports and the app's own labels are secondary agreement only. Identify each original participant across aliases and recordings, uncertainty/scorer agreement, device/site/firmware/placement and intended-use subgroups.

Use [the benchmark harness](../../Tools/physiology-bench/README.md) to split people before windows, purge sequence-context overlap and audit training-only fitting. Keep untouched held-out people and an external cohort where feasible. Freeze study-specific accuracy, wake-detection, retained-coverage, subgroup, sample-size and resource budgets **before** reading held-out results. The draft templates intentionally contain null study choices; no scientific thresholds or power calculation are supplied by these code changes.

Compare the repaired baseline and candidates on identical reference time, reporting common-window errors and each candidate's native retained coverage. Run the same-input censor-only/Malik/Lipponen experiments and the 80/90/95% observed-time/correction-burden sweeps on development data; preserve original versus corrected metrics and pair masks. Include clean-high-HRV, mixed-context and ambiguous-rhythm strata. Report end-to-end episode/nap detection separately from staging in supplied windows, participant-level uncertainty, stage risk/coverage, respiratory harmonics/out-of-range behavior and unknown time. None of these gates is an apnea, arrhythmia or clinical diagnosis claim.

## 4. Model rights, immutable environment and target resources

Every activation needs separately reviewed code, checkpoint and training/evaluation data rights with meaningful evidence. Obtain and hash the exact applicable local checkpoint, preprocessing and quality contract; do not replace missing weights with invented hashes or imply a source license also licenses weights/data. All eight supplied candidate manifests remain inventory-only and shadow; no reviewed activation is supplied.

Current optional execution gaps are specific: wav2sleep released checkpoint/config execution, RR_Estimation's external preprocessing and TensorFlow/evidential environment, SleepECG's local released classifier, and Octave/RRest execution. CorrEncoder has a synthetic train/reload experiment, not a reproduced real cohort; the compact feature learner is not LightGBM and the serial Walch comparator is not its published ensemble. Their exact boundaries are in [the inference README](../../scoring-service/inference/README.md).

Capture and independently qualify the immutable Linux interpreter/package/import environment using the supplied environment-manifest tool. The macOS functional dependency list is not a wheel-origin supply-chain lock or Linux qualification. Pin approved native dependencies and source/checkpoint assets; environment capture itself never grants qualification.

Run the supplied bounded resource benchmark on the actual authorized VPS with representative immutable inputs, the reviewed activation and a frozen numerical tolerance. Retain host identity and CPU/RAM limits, repeated child latency including p95, throughput, CPU, RSS, output reproducibility, failures and concurrency. Measure aggregate JVM/model/ingestion/Postgres headroom separately; child RSS alone is insufficient. Begin with one model slot; do not infer live capacity from the repository's nominal 4-vCPU/8-GB template. No target-VPS resource measurements were made here.

For external processes such as Octave, use the dedicated Linux cgroup-v2 accounting path. Freeze `process_tree_memory_peak_bytes` and its budget explicitly if using kernel charged-memory peaks; they are not process RSS and must not be relabeled as such. The benchmark verifies its actual cgroup membership and requires a dedicated scope. Lifetime peaks include prior warmup and other charges, so preserve the scope's full history and the measurement semantics. Unsupported accounting remains unavailable. Host/container primitives and synthetic process tests do not qualify the actual model or VPS.

## 5. Deployment, explicit opt-in and rollback

Deploy only after separate authorization. Apply the additive migrations using the normal reviewed migration process, preserve the pinned v1 numerical kernel and user data, and build its token-aware transport artifact before migration `20260918120000`, and validate the exact deployed service/API/client combination. The local official Supabase PostgreSQL-image test does not cover the complete deployed Auth, Storage and PostgREST stack. Exercise authenticated readback, token refresh, sign-in/configuration errors, offline account switching, selected-device changes, stale revisions, boundary correction/tombstones and archive failure/retry against the deployed build.

Keep canonical defaults on `frwhoop-server-1` while the new worker publishes `frwhoop-physiology-2` shadow snapshots. Approving one feature does not qualify another. The offline promotion command returns only eligibility for human review; it does not write production selection. An authorized human must review the signed evaluation/custody, rights, device-soak, reference and target-resource artifacts before any small opt-in cohort selection.

Roll back per feature to the retained baseline selection and, if old computation must resume, the separately built baseline image containing the pinned kernel plus its fenced transport patch; the unpatched binary fails closed after migration `20260918120000`. Keep the independent archive worker running. Do not relabel the v2 binary as v1, drop additive tables, overwrite source history or erase immutable result/archive evidence. Recheck the selected source in both clients after rollback.
