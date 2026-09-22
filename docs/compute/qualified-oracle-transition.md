# Qualified physiology oracle transition

The reconciled server-pipeline base `cfb94434b1b4ed4dba587e5c4e7af405e782e560`
already implements strict RR timing qualification and explicit unknown sleep epochs. Several older
tests still demanded pre-qualification HRV, inferred wake in unobserved gaps, or the old DTO shape.
The migration does not restore those unsafe numerical expectations.

The original `w4-whole-day-swift-v1` and `w4-whole-day-swift-v2` files, manifest hashes, immutable Git
source-blob checks, selected row identities and raw input assertions are retained. The separate
`Tests/Fixtures/qualified-physiology-base-v1.json` pins all 26 complete current DTO digests (13 recipes
under each raw-byte version), their expected-output digests, and the corresponding historical hashes.

This receipt was produced from the actual native Swift reconciled-base execution, not hand-edited
values. The offline `Tools/compute/qualified-oracle-receipt.swift` reads a current-corpus export plus
the independent base compatibility log. It refuses any source revision other than the reconciled
base, any changed capture hash, any promoted untimed RR measurement, missing cases, or any DTO hash
that differs from the independent native compatibility run. Tests never regenerate or bless it.

The live assertions additionally restrict the historical/current differences:

| Changed fields | Deliberately replaced contract |
| --- | --- |
| Daily/session HRV, SDNN, HRV windows and clean beats | Coarse WHOOP RR without verified beat spans cannot become a physiological measurement or baseline input. The current-corpus gate retains separate qualified synthetic ECG positive controls. |
| Sleep stages, efficiency, duration, stage minutes, disturbances | Staging cannot use unqualified HRV; missing observations remain unknown. An unobserved split-night gap is not observed wake, and unknown sleep is not measured zero. |
| Rest and Rest confidence | These depend on the qualified sleep result, including explicit unavailable sleep. |
| Session provenance and episode metadata in seam tests | The qualified DTO includes main/nap/uncertain identity, grouping and estimated-opportunity provenance. Full literal expected DTO equality remains in the seam tests. |

Every other result field, raw input, selected row identity, clock, device identifier, direct resting
HR, calorie/workout field and non-Rest score must remain byte-identical to the historical artifact.
The complete current DTO hash also rejects any unreviewed change within the allowed field groups.

The S11 late-correction control now changes a small, supported thermal input as well as retaining
the raw RR correction. It must invalidate the historical lineage and change the thermal baseline
after a 103-day replay; unqualified HRV remains absent and never warms its baseline. Cold/warm
restart equality, source inventories, original row counts and stale-predecessor rejection remain.

Same-environment evidence is recorded under the task evidence directory:

- `swift-base-expanded-oracles.log`: 74 tests, 55 inherited assertions (2 unexpected errors caused by the failing exporter assertions).
- `swift-base-current-corpus-direct.log`: actual base current-corpus generation, 1 test passed, including qualification positive and negative controls.
- `qualified-base-corpus.xP8Pe4/w4-whole-day-current-v2`: captured actual base outputs and source-hash manifest.
- `repaired-context-oracle.log`: 3 repaired context tests passed.
- `repaired-qualified-seams.log`: 72 repaired seam/core tests passed.

The current JVM pipeline continues to consume its fresh `WholeDaySwiftCurrentCorpus` export. This
historical-transition receipt neither replaces that production parity gate nor grants canonical
authorization, sensor validation, or physical-device acceptance.
