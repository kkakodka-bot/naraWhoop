# Validation and rollout gates

Status: candidate implementation in progress. Nothing in this document authorizes deployment,
production writes, phone installation/reinstallation, data restore or deletion. Obtain separate
approval for those operations. Keep original DB/WAL/SHM, preference and pending-file backups before
any approved device migration. Do not attach private health payloads or credentials to public reports.

## Capture a comparable run

Pin the worktree and full commit, app version/build, Release configuration, SDK/Xcode, device model/OS,
account namespace hash, source-device hash, timezone and actual refresh rate. Record the effective
endpoint, network policy, Low Power Mode, thermal state, charging/signal conditions and history size.
Do not compare a different branch or installed binary and call it evidence for this candidate.

For each canary retain one opaque record/job correlation through these distinct observations:
local commit, strap ACK submission/completion, intake acceptance, verified archive receipt, indexed
input revision, immutable score revision and the displayed revision. A local commit can authorize
strap ACK; upload acceptance is not permission to prune the sole archive source. Keep UTC timestamps
and the result-day timezone. The first missing transition is the stalled boundary; a green dashboard
does not establish all-stream durability.

## Physical iOS procedure (unexecuted)

1. With separate installation approval, build and install the exact Release candidate on a physical
   60 Hz iPhone and a ProMotion iPhone. Preserve existing containers. A simulator or unsigned build
   is not physical-device evidence.
2. Capture baseline and candidate runs under matched conditions. Use Instruments Time Profiler,
   Hangs, Animation Hitches/SwiftUI and energy tooling. Record tool/OS versions and the metric's scope
   and denominator. Measure actual refresh rate; the device's advertised maximum is insufficient.
3. Repeat cache-only launches and warm Today/Sleep/detail navigation. Retain enough independent runs
   for p95; report OS launch separately from first usable cached content. Gates: warm content <=100 ms,
   cold cached dashboard <=1 s; no network dependency for valid cache.
4. Scroll and tap during BLE backlog, immutable upload preparation, network recovery, cache hydration
   and result replacement. Inspect every reproducible main-thread stall >=250 ms. Deadlines are
   16.67 ms at 60 Hz and 8.33 ms at actual 120 Hz, with rendering-pipeline headroom.
5. Use Apple's aggregate all-animation Hitches metric: <=10 ms/s is good; >10 through 25 warning;
   >25 through 50 critical; >50 immediate attention. The old fixed 33 ms callback counter and
   MetricKit's scroll-only hitch ratio cannot certify this gate. [Apple guidance](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app).
6. Exercise at least a 72-hour ordinary backlog, low storage without deleting pending records, Wi-Fi
   interruption, Wi-Fi-only versus explicitly enabled cellular, expired login and upload URL,
   normal backgrounding, OS termination/restoration, reboot/first unlock, Low Power Mode and thermal
   constraints. Record pending/retained bytes and monotonically advancing acknowledged jobs.
7. Run two-hour locked reconnect and overnight-through-wake tests. Force quit is separate: record
   the paused interval and catch-up after reopening, not an uninterrupted-capture claim.
8. Switch A to B during cache load, token refresh, byte upload and receipt settlement. Confirm immediate
   removal from app/widget presentation and no cross-account upload. Retain A's pending bytes. A
   disconnected watch cannot be remotely cleared immediately; verify delivery of the latest empty
   context when it reconnects and keep this platform limit explicit.

MetricKit diagnostics are opportunistic, local and bounded under the app cache directory
`SyncPerformanceEvidence` (16 files, 8 MiB aggregate, 2 MiB per payload). Missing payloads are not a pass.
Export them only with explicit user approval. A `ProductionSync` signpost shows a software stage,
not proof of server durability or an actual rendered frame without the corresponding trace.

## Staging and production evidence (unexecuted)

Use synthetic accounts on a separately approved staging environment first. Migrate additive receiver
compatibility before the scorer, then the app cache/readback contract, then individual validated
metric activation. Never rewrite deployed migration identifiers. Verify user UUIDs/device mappings
before managed-to-self-hosted migration; database restore alone does not move Edge functions or B2
bytes. Reauthentication is required if signing keys change. Quarantine ambiguous legacy ownership.

Record applied migration ledger, Edge revision, scorer commit and immutable image digest. Sample the
heartbeat twice and require advancement. Use a normal user JWT for the canary and RLS checks, not
service role or a fleet token. Confirm a fresh upload advances input/result/display revisions. Repeat
more than 100 updates, duplicates, two workers/lease expiry, late evening corrections, two-device
processing order, index failure and derived-archive failure with recovery without a new phone upload.

The phase-1 restore drill and phase-2 conformance script perform writes and require explicit opt-in
flags plus separate operator approval. Do not execute them during this task.

### Offline and native gates

`infra/vps/scripts/phase3-acceptance-checks.sh --preflight` validates the supplied evidence packet
offline. Missing evidence fails before native or remote commands. It does not require a JDK, SSH
identity or deployment configuration. Success means `EVIDENCE_VALIDATED`, not release readiness.
No mode sources `droplet.env`, `secrets.env`, a user SSH configuration or other deployment shell files.

`--local` requires an explicitly supplied Java 17 `JAVA_HOME` and the Android SDK settings used by
the integration lead. It runs kernel tests, Android CurrentHrv/analytics checks, service tests and
installDist, then the source gate. Successful local checks still exit **3 (`NOT_READY`)**, with
`LOCAL_CHECKS_PASSED`; any command or source-gate failure stops before that marker. Only root runs
the combined native command while the shared Gradle workspace is reserved. Do not race a scorer or
Android build to reproduce a script test.

The source gate scans the four handwritten Kotlin main/test roots and both generated kernel roots
after Gradle sync. Missing/unreadable roots fail. It allows only the 17 named pure `com.noop.data`
symbols in `check-sync-sources.mjs`, never `com.noop.data.*`, Android, AndroidX or ingest imports.
Aliases and leading whitespace do not bypass the rule. The existing two exact fully qualified
SharedPreferences.Editor shim references are the only Android-reference exceptions. This scanner
is a dependency check, not a Kotlin compiler or a general source-security analyzer.

The shared required migration list lives once in `sync-evidence-contract.mjs`: IDs
`20260918010000` through `20260918080000` in increments of `10000`. Local checking requires exactly
one readable nonempty SQL source per ID plus the older scoring-service-state base migration.
`server.migrations` requires all eight as distinct canonical 14-digit strings, plus every other
applied migration ID. Also retain the observed, unmodified ledger array in
`server.migrationLedgerRaw`. The strict adapter in `sync-migration-ledger.mjs` accepts native
14-digit IDs or only the exact supported basenames that the checked-in `apply-migrations.sh`
writes. It does not strip arbitrary suffixes/paths, trim whitespace, accept numeric IDs or rewrite
the database. Its explicit basename catalogue is pinned to the checked-in SQL sources by a test;
adding or renaming a source requires a reviewed catalogue update.

Canonical IDs must be unique even across mixed ID/basename representations, and the complete raw
ledger must canonicalize to the complete recorded ID set. Live inspection independently validates
and compares its **entire** canonical set, including extra migrations, to that evidence. Raw order
and representation are retained in the result's `migrationLedger.observedRaw`, alongside
`canonicalIDs` and the packet's `recordedRaw`; representation differences are permitted only when
the complete canonical sets agree. Retain the result as collection evidence, not just its PASS
marker. An unsupported basename is NOT_READY and requires review, never silent truncation or a
ledger rewrite. Source presence is neither SQL execution nor permission to apply migrations.

**Separate required whole-day parity gate: NOT_READY while corpus/runner repair is active.**
`:service:test` explicitly excludes WholeDaySwiftParityTest. Neither generic service tests,
synthetic script fixtures nor a terminated whole-day run establish semantic parity. Root must run
the separate non-skipping `:service:wholeDaySwiftParity` task against the exact reviewed Swift
corpus, retain its input manifest/hashes and successful native result, and review declared tolerances.
The interrupted v2 run (exit143) has no parity verdict. No ops-script success closes this gate.

### Evidence schema 2 and exact binding

Schema 1 is rejected rather than silently upgraded. The complete synthetic shape is in
`infra/vps/scripts/sync-evidence-fixtures.mjs`, for shape/testing only; never submit that fixture
as collected device/deployment evidence. Required fields include:

| Fields | Meaning and restrictions |
|---|---|
| `environment`, `endpoint`, `target.sshHost`, `target.bindingArtifact` | Staging/production, canonical HTTPS **project origin** without path/query/credentials, explicit DNS/IPv4 SSH host without user/port/options, reviewed artifact mapping that host to the effective endpoint/environment. IPv6/custom SSH ports require a separate reviewed extension. |
| `collection.startedAt`, `collection.completedAt` | Canonical UTC timestamps with milliseconds; positive duration no longer than seven days, completed within 15 minutes of validation, at most 60 seconds clock skew into the future. Longer soaks need separately reviewed packets, not an unbounded freshness waiver. |
| `build` | Exact 40-character lowercase app commit, installed version/number, Release configuration, Xcode/SDK. Device evidence still needs independent installed-binary review. |
| `server` | Exact server commit, Edge revision, `imageDigest` (registry repo digest), **separate** `dockerImageId` (Docker `.Image` config ID), explicit `containerId` (exact64 lowercase hex from Docker `.Id`, not a name, short ID or `sha256:` image ID), full canonical `migrations`, unmodified `migrationLedgerRaw`, advancing heartbeats. Do not compare a registry/index digest to a Docker image ID. |
| `canary` | `credentialKind:userJWT`, lowercase UUID `ownerUserId`, `deviceId`, `objectId`; exact positive safe-integer `inputRevision`, `resultRevision`, matching `displayedRevision`, `day`, `algorithmVersion`. Revisions above JavaScript's safe-integer range are unsupported and fail closed. |
| Canary correlation | `ownerNamespace` remains an opaque lowercase SHA-256-shaped identifier. No namespace derivation is guessed. `recordDigestScope:object-content-sha256` explicitly defines `recordDigest` as the raw object's verified **uncompressed content** SHA-256, as in its durability receipt. No inferred single-record or payload canonicalization hash. `inputBindingArtifact` documents that object's link to the indexed input and result. |
| `canary.stages` | Committed, accepted, archiveVerified, indexed, computed, displayed: each has `at`, `artifact`, and identical ownerNamespace/recordDigest/ownerUserId/deviceId/objectId/inputRevision/resultRevision correlation. Correlation fields may be joined after collection; they do not claim the server revision was known at local commit. |
| Observations | Every heartbeat and stage lies inside the collection window. Heartbeats strictly advance at **every** entry. Last heartbeat and displayed canary observation are at most 15 minutes old. Physiological sample dates may be historical; these bounds apply to observations, not the backlog's sample timestamps. |
| Performance and reports | Every supplied trace is checked, including duplicate refresh rates; at least physical Release 60 Hz and 120 Hz traces are required. Each records matching `buildCommit`, `observedAt`, device/OS, measured Hz, metric/tool/denominator, Hitches <=10 ms/s, zero unresolved >=250 ms stalls. Scenario, latency, energy and security reports each have `observedAt` inside the window and an artifact. |

All artifact references must resolve inside the evidence folder, name regular files and match
their SHA-256; duplicate artifact names fail. The validator checks consistency and bytes, not
artifact authenticity, real-user RLS execution or reviewer approval. Private UUID mapping artifacts
must stay in controlled evidence storage, not public logs or PRs.

### Remote read-only checks (not executed by this implementation task)

Remote mode requires separate operator approval, all the local checks, and these explicit inputs:

- `SYNC_ACCEPTANCE_EVIDENCE`: schema-2 evidence JSON path.
- `SYNC_ACCEPTANCE_TARGET`: independently reviewed JSON selector, **not generated from the packet
  being checked**. Exact fields: `schemaVersion:1`, `environment`, `endpoint`, `sshHost`, `appCommit`,
  `serverCommit`, `edgeRevision`, `imageDigest`, `dockerImageId`, `containerId`, `ownerUserId`, `deviceId`, `objectId`,
  `ownerNamespace`, `recordDigest`, `inputRevision`, `resultRevision`, `day`, `algorithmVersion`.
  Every value must exactly match the evidence. Missing, extra or mismatching fields fail before SSH.
- Absolute paths `SYNC_ACCEPTANCE_SSH_KEY`, `SYNC_ACCEPTANCE_KNOWN_HOSTS`: explicitly selected
  operator identity and preverified host-key file. The helper never reads key contents itself;
  SSH is batch-only, uses strict host checking, no agent and no ambient SSH config. No trust-on-first-use.

The legacy `DROPLET_IP`, `EXPECTED_SCORER_IMAGE_DIGEST` and `CANARY_*` variables are not inputs to
this gate. SQL uses the validated packet's exact UUIDs/revisions/day/algorithm and read-only sessions
with a statement timeout and `ON_ERROR_STOP`. Every SSH/Docker/psql exit status is checked before
parsing bounded JSON; empty output or failed inspection never proves absence of ports/objects.
Host networking and shared-container network namespaces also fail the scorer port-isolation gate.
The scorer is inspected by the reviewed full `containerId` and the returned Docker `.Id` must match
exactly. Compose service names are not container identities: a generated `project-scoring-1` name
is supported through its exact ID, while a different project's scorer or an unrelated literal
`scoring` container cannot substitute. No broad name search, first-match selection, rename or
deployment change occurs. An absent/replaced instance is NOT_READY; collect/review a new exact ID
in both packet and independent selector after an approved recreation, rather than auto-following
whatever container happens to expose the same name or image. The binding artifact must identify
the intended project/environment; an ID alone does not prove endpoint routing.
The running scorer must have `org.opencontainers.image.revision` matching the server commit, the
exact Docker image ID and a RepoDigest matching the declared registry digest. Missing labels or
unavailable RepoDigests are blockers, not inferred equivalence. No deployment changes are performed
to manufacture these fields. Live heartbeat samples must advance and be recent with a bounded
server-clock difference. No raw payload or container environment is fetched or printed.

#### Required immutable scorer provenance (stricter schema 2)

Schema 2 now also requires `server.imageProvenanceArtifact`, a relative JSON artifact listed in the
packet's existing SHA-verified `artifacts`. Old packets lacking it are **NOT_READY**, not implicitly
upgraded. The file is a `scorer-image-release` schema-1 bundle manifest produced by the explicit
image helper; all its referenced regular files must remain alongside it and match their hashes.
Its source commit, registry digest and Docker config ID must equal `server.commit`, `imageDigest`
and `dockerImageId`, respectively. The independently reviewed selector keeps its existing exact
fields. Do not generate that selector from whichever container a deployment happened to create.

The bundle binds exported committed Android/JVM inputs and Dockerfile bytes, separate native-input
and report byte identity, pinned base references, explicit platform, builder metadata, exact registry
descriptor bytes and sanitized image inspection. Native report hashes do not prove test coverage or
successful execution; reviewers must inspect the actual results. OCI labels and internal artifact
consistency do not authenticate a builder. Dependency reproducibility/signing and registry access
are separate, unproven gates. See `scoring-service/README.md` for the input schema and operation modes.

Live acceptance additionally requires the container's configured image reference to equal the
reviewed digest pin, then inspects the immutable image by the container's exact config ID. The image's
own revision label, OS/architecture and exact repository@digest membership must match. A correct
container label cannot substitute for a missing/wrong image label. The registry/index digest,
selected platform-manifest digest, config ID and full container ID remain distinct. Sanitized
observed image facts and source/native-input hashes are returned in `imageProvenance`; preserve them.

The existing Compose template and no-argument deployment stay compatible, but mutable legacy images
remain unqualified. The explicit pinned deployment skips source synchronization/building and refuses
fallback to latest. It requires an already configured deployment, retains the override/manifest,
and never starts or recreates dependencies. It returns a selected container, not acceptance approval.
No registry, SSH, Docker or publish/deploy command may run as an offline test. Local preparation
cannot fetch missing Git objects and does not access deployment environment/credential files.
The phase3 shell, its documented `--local` command and its exit-3 NOT_READY result are unchanged.

The canary read verifies the exact snapshot owner/device/input/result/day/algorithm and raw object's
ready/server-verified receipt, including owner/device/object/content digest and indexing before
computation. **The schema has no per-result list of contributing raw object IDs.** These matching
rows are necessary but not sufficient proof that this object caused that result: independently
review `inputBindingArtifact`. Similarly, endpoint-to-host routing, Edge revision and the installed
app commit rely on the reviewed binding artifacts/selector; the helper does not introspect ingress,
Edge containers or a phone. It cannot certify those mappings from a caller-supplied label alone.

Successful remote checks return `READ_ONLY_CHECKS_PASSED` with explicit overall `NOT_READY` pending
independent artifact/candidate review and the separate whole-day, physical-device and deployment
acceptance gates. Evidence is revalidated after inspection to catch expiry during long builds.

### Offline script regression command

```sh
node --test infra/vps/scripts/verify-sync-evidence.test.mjs \
  infra/vps/scripts/check-sync-sources.test.mjs \
  infra/vps/scripts/phase3-acceptance-checks.test.mjs \
  infra/vps/scripts/sync-deployment-contract.test.mjs
bash -n infra/vps/scripts/phase3-acceptance-checks.sh
```

The subprocess suite copies scripts into a disposable synthetic repository and substitutes every
Gradle/SSH/sleep executable on an isolated PATH. It must not invoke real builds, secrets, accounts,
devices, migrations or network services. It tests gates and failure handling, not deployment.
The deployment-contract tests are closure versions of the independent filename-ledger and
Compose-name defect controls: those legitimate cases must now pass, while malformed/missing/
duplicate canonical ledger entries and wrong/missing container IDs remain NOT_READY. The earlier
independent diagnostic artifact is retained unchanged as pre-repair evidence, not relabelled a pass.

Additional image-provenance regression (offline synthetic fixtures/mocked Docker and SSH only):

```sh
node --test infra/vps/scripts/scorer-image-release.test.mjs
node --check infra/vps/scripts/scorer-image-release.mjs
bash -n infra/vps/scripts/deploy-scoring-service.sh
```

Set `TMPDIR` to the external evidence volume. These tests use local disposable Git repositories,
preserve binary bytes, reject unavailable/promisor objects and mismatched native evidence, and
exercise descriptor/config/label binding and the pinned deployment boundary through mocks. They
do not perform a real image build/push/pull, remote read/write, login, signing or deployment.

## Rollback and recovery

Keep the prior compatible binary, receiver and scorer image. Stop activation or move the controlled
algorithm pointer only after confirming client compatibility; do not clear caches or launch an
unbounded local rescore. Retain immutable prior result revisions and raw receipt associations.
Disable a failing worker while preserving its queue; a lease expires and can be safely reclaimed.
Archive debt retries independently. Retain current/previous account pending files in their original
namespaces and require reauthentication as that owner to resume. Never move them into a new account.

Do not roll back by dropping new tables, resetting a phone database, replaying all users or deleting
unsent data. Explicit deletion and verified legacy-data recovery require separate reviewed procedures.
Report source readiness, deployment readiness, runtime correctness and physiological accuracy separately.
