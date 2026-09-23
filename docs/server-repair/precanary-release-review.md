# Independent pre-canary source review

Scope: dirty repair worktree based on 76f2d70f621de91268e295ebcb6c6da29162991f. Source review only; no production approval, physical acceptance, numerical promotion, or capacity claim.

## Findings sent to integration owner

1. Resolved: hosted migration postverify now matches the actual disposable SQL fingerprint catalogue: eighteen functions, eleven triggers and twenty-four policies. The prior eight-function/six-trigger expectation rejected the upgraded schema. The fresh wrapper test and independent hosted verifier tests passed.
2. Resolved: standalone hosted migration verification now recomputes the schema fingerprint from validated catalogue rows. A negative regression rejects coherently reauthored catalogue data.
3. Existing launch-capacity evidence covers the historical scalar scheduler fixture and six scoring connection pools. Intake adds one CPU, 2 GiB memory, and three concurrent REST lanes. REST demand must not be represented as three measured PostgreSQL connections or absorbed into previously measured capacity. The matched topology needs separate target measurement.
4. New per-family execution states correctly retain incomplete numerical parity and distinguish missing engineering producers from hardware limitations. Legacy canonicalNumericalProducer fields pointing current v2 DayScorer conflict with the selected frozen baseline and shadow-only route descriptions; reconcile these metadata fields. Positive night_hrv family evidence explicitly covers resting HR only, not RR-derived HRV.

## Accepted implementation review

Raw model assembly pins one parsed acquisition receipt before selecting a complete required object set. Metadata is read in repeatable-read pages of 128 IDs and released before object fetch. Required identities must match exactly; wire and decoded bytes are bounded to 64 MiB and records to 100,000 before model execution. Existing timing, gap, channel, mask, preprocessing and checkpoint guards remain. No model promotion or hardware qualification follows from this source change.

Android repository commits now consistently acquire the account session lock before the publication lock; generation, token and source checks remain. The concurrent retirement/read regression exercises the former lock-order deadlock. Science reviewer reports 37 Android and 43 Swift local tests passing, plus 70 raw JVM tests. These are local source/runtime evidence, not phone readback.

Intake artifact binding received an independent runtime review. It checks actual OCI descriptor/config/layer hashes, BuildKit metadata, source revision, contract version 1, role, pinned base, platform, cached nonroot command, and strict compiled Compose limits. Actual Compose rendering found and corrected an unquoted tmpfs flow-list bug. The deployment must use emitted compiled JSON; it must not re-resolve the source template under ambient overrides.

The committed-127 artifact suites passed at 9b51bfd42150f04f705b1aaf31da2b758aed2bcd, and its exact-source intake OCI was built and inspected locally. Subsequent CA trust, capacity/scope and physical-counter export changes require a new source freeze and new artifacts. Current capacity declaration preserves the old scalar fixture separately, retains unknown safe admission for global queues, and binds the unmeasured ten-second publication target. Initial intake/baseline resource caps are proposed, not approved or measured capacity. Matched approved deployment, phone readback and elapsed physical continuity/capacity tests remain separate.
