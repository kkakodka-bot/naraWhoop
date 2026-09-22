# Compute ownership and cutover

The executable inventory is [metric-ownership.json](metric-ownership.json). It covers every
`ServerScoreMetric` plus current/spot sessions, PPG HR, live inferred HR, events, baselines and inference outputs.
Each family records its phone producers, required inputs, real server entrypoint where one exists,
output units/details/series, read contract, consumers, validation and removal state.

`node Tools/compute/check-cutover.mjs` verifies inventory completeness against the application enum,
source paths, matching Swift/Kotlin ownership maps and the daily kernel's output dependencies.
`--require-final` additionally fails while any family lacks complete cutover evidence. This is a
source/registry check, not runtime instrumentation or proof that a phone performed no inference.

Ownership and availability are separate. A qualified, revision-bearing publication accepted by the
phone can establish a claim for only the metrics in its exact serialized contract. Claims persist
under project/account/canonical-device identity. Empty historical days, errors, revocation and
pausing reads do not restore a claimed local metric. Every displayed value must still pass current
qualification checks; the claim does not grant permission to display revoked data.

The narrow physiology contract cannot retire the daily kernel, because that kernel also produces
workouts, history, baselines and other outputs. The old global overlay bit is no longer consulted
for that decision. Removing a local producer requires a complete replacement of its output and
detail dependencies, including exports and background consumers.

Raw upload has separate admission: captured runtime identity, raw database/source/endpoint checks,
durable transport selections and the current upload job token. It runs before local rescore. Health
and widget exports still retain their existing preference barrier until their canonical result
contracts are fully migrated. They must not inherit the raw upload admission.

## Current limitations

Final hosted mode is **NOT_READY**. The historical worker invokes the broad producers, but its
snapshot remains a distinct shadow contract. The apps' account snapshot reader still targets that
contract; enrollment reads the qualified physiology endpoint. Full account/enrollment consumer
parity, all-consumer revision identity, server PPG-HR, session requests/results and removal of all
phone inference are unfinished. No readiness setting or local claim bypasses these prerequisites.

The registry distinguishes code that runs in a worker from a result that is qualified, selected,
delivered and consumed. Live deployment, real sensor/reference qualification and physical phone
instrumentation remain separate evidence requirements. The retained baseline is not a new
scientific validation, and an unavailable qualified window is not a license to fabricate a value.

The additive focused Xcode project in `Tools/compute/project.yml` hosts the changed-path tests in
the real Strand application. It does not replace the original test target or make its existing
`ExploreRangeGatingTests` compilation failure pass.

Run the changed app paths with `bash Tools/compute/run-app-checks.sh`. Running the entire additive
test target also executes broader preference tests; the handoff records those separately and
does not treat a successful filtered run as a successful full app suite.
