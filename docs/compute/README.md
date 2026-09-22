# Compute ownership and cutover

The executable inventory is [metric-ownership.json](metric-ownership.json). It covers every
`ServerScoreMetric` plus current/spot sessions, PPG HR, live inferred HR, events, baselines and inference outputs.
Each family records its phone producers, required inputs, real server entrypoint where one exists,
output units/details/series, read contract, consumers, validation and removal state.

`node Tools/compute/check-cutover.mjs` verifies inventory completeness against the application enum,
source paths, matching Swift/Kotlin ownership maps and the daily kernel's output dependencies.
`--require-final` additionally verifies the full producer/consumer inventories and twelve executed
gate receipts. Receipts bind clean source content, the exact command, output and log hash. Static
contracts and runtime evidence are labeled separately; a registry entry alone cannot prove zero
phone inference. See [HANDOFF_compute.md](../../HANDOFF_compute.md) for the verified revision.

Ownership and availability are separate. A qualified, revision-bearing publication accepted by the
phone can establish a claim for only the metrics in its exact serialized contract. Claims persist
under project/account/canonical-device identity. Empty historical days, errors, revocation and
pausing reads do not restore a claimed local metric. Every displayed value must still pass current
qualification checks; the claim does not grant permission to display revoked data.

Final hosted mode includes all 27 families and 80 outputs, not only the original narrow physiology
overlay. Eight families admit qualified numeric results; nineteen currently retain explicit
server-owned states. These are intentional missing results, not numeric-producer or scientific
qualification claims. The global overlay bit is not hosted-mode authority. Daily/session producers,
imports and indirect reconstruction entrypoints are guarded before physiological work begins.

Raw upload has separate admission: captured runtime identity, raw database/source/endpoint checks,
durable transport selections and the current upload job token. It does not depend on local rescore
or preference projection. Health, widget, watch and export admission instead requires canonical
result identity, current authorization and freshness. It does not inherit raw-upload admission.

## Repository and external verification

Account and enrollment authentication surfaces share validated selection and serialization. Actual
production worker publications pass through SQL and real Edge routes into production Swift and
Kotlin decoders, persisted ledgers and consumer selection. Historical shadows do not become
canonical. Durable session requests/results preserve event time, input identity and consent;
unqualified optical input remains explicit, and expired coaching decisions cannot replay.

The registry distinguishes code that runs in a worker from a result that is qualified, selected,
delivered and consumed. Live deployment, real sensor/reference qualification and physical phone
instrumentation remain separate evidence requirements. The retained baseline is not a new
scientific validation, and an unavailable qualified window is not a license to fabricate a value.

The additive Xcode project in `Tools/compute/project.yml` hosts changed-path tests in the real
Strand application and includes the complete original `Strand` test scheme. Inherited Explorer
compile blockers were repaired. The final gate requires the complete macOS suite, generic iOS
and watch builds, full Android application compile/tests and all Swift packages.

Run changed app paths with `bash Tools/compute/run-app-checks.sh` and shipped-policy runtime paths
with `bash Tools/compute/run-final-hosted-checks.sh`. The latter exercises zero-inference counters;
neither focused command substitutes for the complete application suites. Physical-device, deployed
VPS, permission, battery/soak and independent-reference checks remain separate acceptance evidence.
