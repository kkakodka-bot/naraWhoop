# Independent pre-canary source review

Scope: dirty repair worktree based on 76f2d70f621de91268e295ebcb6c6da29162991f. Source review only; no production approval, physical acceptance, numerical promotion, or capacity claim.

## Findings sent to integration owner

1. Hosted migration postverify still expected eight selected functions and six triggers while the new SQL verifier fingerprints eighteen and eight. This prevents a real successful upgraded schema from passing hosted verification. Integration owner must update counts and check the actual disposable SQL receipt.
2. Standalone hosted migration verification compares the declared schema fingerprint to its constant but must recompute that fingerprint from the validated catalogue rows. Aggregate verification already does this. Add matching recomputation and a negative regression.
3. Existing launch-capacity evidence covers the historical scalar scheduler fixture and six scoring connection pools. Intake adds one CPU, 2 GiB memory, and three concurrent REST lanes. REST demand must not be represented as three measured PostgreSQL connections or absorbed into previously measured capacity. The matched topology needs separate target measurement.
4. New per-family execution states correctly retain incomplete numerical parity and distinguish missing engineering producers from hardware limitations. Legacy canonicalNumericalProducer fields pointing current v2 DayScorer conflict with the selected frozen baseline and shadow-only route descriptions; reconcile these metadata fields. Positive night_hrv family evidence explicitly covers resting HR only, not RR-derived HRV.

## Accepted implementation review

Raw model assembly pins one parsed acquisition receipt before selecting a complete required object set. Metadata is read in repeatable-read pages of 128 IDs and released before object fetch. Required identities must match exactly; wire and decoded bytes are bounded to 64 MiB and records to 100,000 before model execution. Existing timing, gap, channel, mask, preprocessing and checkpoint guards remain. No model promotion or hardware qualification follows from this source change.

Android repository commits now consistently acquire the account session lock before the publication lock; generation, token and source checks remain. The concurrent retirement/read regression exercises the former lock-order deadlock. Science reviewer reports 37 Android and 43 Swift local tests passing, plus 70 raw JVM tests. These are local source/runtime evidence, not phone readback.

Intake artifact binding received an independent runtime review. It checks actual OCI descriptor/config/layer hashes, BuildKit metadata, source revision, contract version 1, role, pinned base, platform, cached nonroot command, and strict compiled Compose limits. Actual Compose rendering found and corrected an unquoted tmpfs flow-list bug. The deployment must use emitted compiled JSON; it must not re-resolve the source template under ambient overrides.

Final source freeze, unfiltered committed-127 migration binding test, exact-source image/mobile packaging, matched approved deployment, phone readback and elapsed physical continuity/capacity tests remain separate.
