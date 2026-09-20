# PR21 iOS and server physiology candidate

Starting PR21 head: `27156ff257115acd1d345d27c7e52f107899a8c9`, branch `feature/physiology-v2-complete-pr21`.
Repair branch: `fix/pr21-ios-server-physiology-production`. The issue-creation SHA was not substituted for the fetched head. The original checkout and its untracked documents were preserved.

PR21 advanced during implementation. The integration also includes its later head `28a6b32e0140507dc75ece23286db4c814bbd5bc`; the original starting SHA above is unchanged. Final whitespace and PR comparison use that actual target-branch base, not `main`.

The missing `Algorithms.txt` was resolved by the user to `/Volumes/Untitled/FRWHOOP/ALGORITHMS.md`. That document describes an older Node implementation. Its reconstructed interval times, value clamps, and vendor/synthetic comparisons are historical context, not permission to reconstruct acquisition or claim validation. The specification and this issue's evidence requirements take precedence.

## Publication and rollback

Migration `20260918230000_physiology_signed_promotion.sql` restores all default and existing nonlegacy feature selections to `frwhoop-server-1`. It removes the `published` shortcut. HRV, sleep, and respiration have separate gates; no release-signing keys, approvals, or qualified v2 features are seeded.

A v2 feature needs an immutable feature manifest, immutable checkpoint/source digest, preprocessing and quality identities, reference evaluation and prespecified policy hashes, participant-disjoint held-out evidence, and an immutable signed human approval. Application roles cannot provision or read release-signing keys. Qualification-row edits alone cannot authorize selection. Changing a manifest requires a new registered algorithm version; approvals and revocations are append-only. The read RPC checks authorization again and requires the snapshot's feature-manifest hash to match the approved release. Old v2 snapshots cannot inherit a later release's qualification.

The build generates a source fingerprint over the server, shared analytics/protocol/pure-data inputs, and Gradle build/wrapper contracts. `:service:algorithmManifests` exports the exact distribution's three manifests, recorded in [candidate-algorithm-manifests.json](candidate-algorithm-manifests.json). Exact-head verification compares that artifact with the built distribution. For deterministic methods, `checkpoint_kind=deterministic_source_not_learned_weights` makes explicit that the checkpoint digest identifies source, not trained weights. Learned checkpoints have their own actual weight-file digests and independent shadow activations.

The native client rejects prequalification v2 caches without server qualification metadata. In server mode, unavailable HRV, sleep, and respiration do not fall back to experimental local values. Retained legacy results remain independently identifiable; rollback selects the retained legacy service/results and never runs v2 under the v1 label. No deployment or production database mutation was performed by this work.

Production rollout must retain the actual legacy image/worker and its result path while v2 is shadow. This candidate explicitly refuses to run its new computation under the legacy version. A retained historical value is not a promise that an unobserved legacy worker is currently processing new days. Apply the additive migrations before the updated receiver/scorer; deploy-time verification and legacy-worker continuity remain operator acceptance gates.

## Implementation boundaries

- Five-minute HRV is server event-time computation. Candidate R-R transports survive acquisition readback and are selected independently per completed window. Both endpoints, original shared beats, source/firmware/clock identity, rejection topology, and observed duration are checked. Missing acquisition cannot be repaired into coverage. Zero and high values remain evidence, while extreme alternation can cause rhythm ambiguity rather than a false clean result.
- The versioned quality layer consumes available motion and off-body evidence and preserves explicit absence of optical, contact, or detector-agreement evidence. Context eligibility and past-only independent-night baseline eligibility are separate from measurement validity. Unknown capture firmware cannot silently become the current device-catalog firmware.
- Nightly HRV and respiration require accepted duration and temporal distribution, not one dense early island. Source/processing identities remain separate. The respiratory estimator rejects impossible IBI before interpolation, motion contamination, gaps, ambiguous harmonics, and unsupported rates; it does not infer respiration from mean HR.
- Sleep opportunity, binary state, stage, and attributed context are separate. Accepted binary duration determines main sleep, including daytime and rotating schedules. Unsupported long or frozen-sensor episodes abstain. Naps, other sleep, and uncertain episodes remain distinct. A stage-wake prediction cannot revoke independently qualified binary sleep. Full-day awake/off-body/unknown/context epochs survive serialization and native cache storage. Manual edits and tombstones are reapplied to both episode and full-day context.
- Optional learned inference uses a separate durable, versioned model queue and process, not the deterministic publication deadline. Per-model activation/checkpoint identity, owner/device/input revision, leases, retries, cancellation, historical backfill, bounded raw reads, and output validation are independently enforced. Model results remain shadow.

Detailed policies: [HRV](hrv.md), [sleep](sleep-production-candidate.md), [respiration](respiration-production-candidate.md). These are conservative engineering policies, not held-out physiological calibration.

The [independent audit](production-candidate-independent-audit.md) records repaired findings and remaining external gates. [Model execution](model-execution-production-candidate.md), [released checkpoints/input contracts](learned-model-production-candidate.md), [reference evaluation](reference-validation-production-candidate.md), [receiver provenance](motion-input-provenance.md), and [VPS resources](vps-resource-report.md) provide the detailed evidence boundaries.

## Signal and input availability

| Input | What can be established | What remains unavailable |
| --- | --- | --- |
| WHOOP R-R projection and raw packet identity | Original words, source channel, packet-local order, owner/device, coarse event timestamp; rejected endpoints are retained | Verified subsecond beat acquisition clock, cross-packet continuity, capture-time firmware. Packet identity is not timing proof. Current unqualified inputs correctly return unavailable HRV/RSA. |
| Sampled HR | Timestamped sampled HR and plausibility; sleep-context features when coverage is sufficient | ECG-adjudicated NN truth, beat timing, respiration from mean HR |
| Gravity and dynamic acceleration | Receiver-attested numeric orientation and dynamic acceleration in g; plausible gravity checks and observed-second contamination | Historical receiver-coerced scalars have no proof and remain unavailable to v2. Missing seconds, impossible vectors, conflicting duplicates, or unproven IMU respiratory mechanics are not stillness/respiration evidence |
| Wrist/contact/optical evidence | Explicit wrist-off events or attributed off-body annotations can reject contaminated intervals | Absence of wrist-off is not verified optical/contact quality; no invented perfusion or detector-agreement score |
| Raw NPB1 PPG objects | Verified object bytes/digest, ownership, indexed raw records | Container timestamps alone do not prove waveform clock, channel separation, wavelength, units, synchronization, or capture firmware. A separately reviewed immutable acquisition receipt is required. |
| Sleep context | Binary engineering detector, manual opportunity/boundary edits, persistent tombstones, reported reading/phone use, event-time calendar ownership | Passive phone-scrolling detection, PSG stages, or confirmed bed occupancy from wrist stillness |
| Learned stages | Executable adapters, pinned checkpoint/environment contracts, model probabilities and gap abstention where supported | Target-device calibrated probabilities, target-domain accuracy, and canonical permission without held-out qualification |

## Validation and retained coverage

No synchronized target-device ECG with adjudicated R peaks/NN intervals, PSG plus independently timestamped opportunities, or respiratory-reference cohort was supplied. Target physiological bias, MAE, RMSE, limits of agreement, stage confusion/macro-F1/kappa/calibration, beat precision/recall, and retained valid-time coverage are **NOT_MEASURED**. Synthetic test performance and released-checkpoint execution are not estimates of those quantities. Vendor agreement is not ground truth.

The reference harness enforces participant-level partitioning, development-only fitting/calibration, frozen promotion policy, reference custody/modality, end-to-end opportunity matching, separate binary/stage evaluation, representative nightly coverage, and per-person/subgroup statistics. Thresholds in promotion templates remain unset until prospectively specified. No missing result is replaced with zero or light sleep.

## Release matrix

Each row describes this source candidate, not the deployed service. Exact-head command results and remaining audit items accompany the final handoff.

| Feature | Implemented | Unit tests | Integration tests | Device tested | Overnight soaked | Reference validated | Shadow | Canonical v2 | Deployed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Five-minute HRV | Yes; acquisition gate explicit | Yes | Local service/SQL/readback | No | No | No | Yes | No | No |
| Nightly HRV/baseline | Yes; representative/independent-night gates | Yes | Local service/SQL/readback | No | No | No | Yes | No | No |
| Sleep opportunity/binary/context | Yes | Yes | Local service/SQL/readback | No | No | No | Yes | No | No |
| Fixed-coefficient four-stage baseline | Yes; unknown coverage retained | Yes | Local service/SQL/readback | No | No | No | Yes | No | No |
| Learned staging challenger | Executable with qualified inputs/checkpoint | Yes | JVM/PG/Python and released checkpoint; native combined-image/probe evidence separately bound | No | No | No | Yes | No | No |
| Overnight respiration | Yes; qualified RSA, guarded waveform adapters | Yes | Local service/SQL/readback | No | No | No | Yes | No | No |

Code completeness, acquisition readiness, scientific validation, deployment readiness, and canonical promotion are different acceptance decisions. iPhoneOS compilation is not a physical device test. Local CPU/model benchmarks are not actual-VPS capacity evidence. There is no supported claim of Apple, Fitbit/Google, Oura, WHOOP, clinical, or production accuracy.

The [Linux packaging preflight](linux-model-packaging-preflight.md) completed a pinned offline wheel installation and actual released-checkpoint execution. Following restored SSH, the combined JVM/Python image also built on the native VPS. Read-only-root execution uncovered and prompted repair of a non-root Numba cache defect; the [VPS report](vps-resource-report.md) records the failed initial probe and subsequent evidence without conflating synthetic execution with acquisition/reference qualification. The compact feature learner and additional respiratory-model inventory do not claim production input adapters where preprocessing or channel contracts remain unresolved.

The [live destination diagnosis](vps-continuation-20260919.md) found the observed legacy worker polling the VPS-local database while current app inputs and unattempted queues were in hosted Supabase. The candidate's deterministic attempt watchdog, scoped query cancellation and progress-checked rollback deployment address additional availability risks. No live worker, migration, source selection or model activation was changed. The deployed old v2 default remains an explicit rollout blocker until the signed-promotion migration is applied through a reviewed deployment.

## Reproducible exact-head checks

`scoring-service/scripts/verify-physiology-candidate.sh` records the candidate commit, actual PR base, commands, logs and exit status. It rejects tracked or untracked source changes before and after every gate, rebuilds the distribution before manifest comparison and preserves ordinary JUnit results before filtered database runs. Set paths for the pinned Python environment, Java 17, Gradle/TMPDIR caches, `PHYSIOLOGY_BUILD_ROOT`, `PHYSIOLOGY_PACKAGE_CACHE`, `PHYSIOLOGY_WAV2SLEEP_PYTHON`, `PHYSIOLOGY_WAV2SLEEP_SOURCE`, and `PHYSIOLOGY_CHECKPOINT_ROOT`, plus `PHYSIOLOGY_IPHONE_UDID` for an available paired iPhone; keep generated evidence outside the repository. The default gates cover Swift analytics/protocol/store/push, macOS application tests, unsigned simulator, generic iPhoneOS and physical-iPhone-destination builds (no install), analytics kernel/service/distribution, immutable-manifest comparison, disposable PostgreSQL and runtime preflight, fresh/populated migration chains, Edge, Python inference/reference/deployment tooling, released-checkpoint execution, and whitespace against the recorded PR21 base. Android application builds/tests are deliberately excluded.

The migration harness uses the digest-pinned official Supabase PostgreSQL image, no network, no published ports, no host binds, and the non-superuser `postgres` migration role. Populated-chain checks preserve baseline samples, legacy scores, and manual edits. Disposable containers are stopped and retained for inspection, not deployed.
