# Isolated model execution candidate

Starting PR #21 revision: `27156ff257115acd1d345d27c7e52f107899a8c9`. This document describes implementation, not deployment or reference qualification.

## Deterministic publication and optional inference

The normal scoring process constructs a deterministic-only `PhysiologyShadowRunner`. Its `evaluate` method never discovers raw objects, prepares model jobs, loads optional configuration, or starts Python. The deterministic respiration estimate and HRV/sleep publication therefore do not wait for model timeouts, malformed model configuration, checkpoint loading, B2 retrieval, or learned output.

Deterministic attempts now have a 90-second deadline and owner-scoped JDBC cancellation, with 15-second statement and 20-second socket timeouts. Renewal stops at cancellation; another user's work and archive/input-gate connections are not aborted. Late output is fenced by lease/revision and remaining publication deadline. An attempt that ignores cancellation causes an explicit process exit after bounded cleanup; logging or shutdown hooks cannot hold the abandoned process alive. Real PostgreSQL regressions cover stalled input, stopped renewal, no late publication and successful publication by the next owner.

`--models-only` is a separate process mode requiring exactly one `PHYSIOLOGY_MODEL_ID`. It loads the configured verified assembler and checkpoint runtime, then claims independent durable model jobs. It does not initialize the canonical publication writer, scoring poller, or canonical service credentials. Run separate resource-limited processes for different models; do not attach inference to iOS timers or the deterministic scoring lease.

Migration `20260918233000_physiology_model_queue.sql` adds:

| State | Identity and behavior |
|---|---|
| Immutable activation | Model, activation revision, exact serialized activation SHA-256, checkpoint SHA-256; activation content also binds preprocessing, quality and installed-environment contracts |
| Model work | Owner, physical device, calendar day, input revision, model, activation revision; renewable token and bounded retry state |
| Model result | Immutable job-bound output, output digest, explicit shadow-only contract; no canonical projection writes |
| Selection | Active model revision; cancellation or activation changes revoke obsolete work |
| Acquisition contracts | Operator-supplied immutable digest-checked proof bytes, bound to owner/device/input revision/model/checkpoint/preprocessing/quality and exact request scope; app clients cannot provision proof |

`--activate-models` is an explicit operator action. It registers the configured activation and creates historical work; starting a worker alone does not activate anything. Repeating an already-active identical configuration is idempotent. Re-enabling or rolling back after a different selection creates a fresh activation revision, preserving historical identities and retryability rather than relabeling old results.

Projection revision triggers enqueue new model work and cancel obsolete leases. Claim-time reconciliation closes the race where a concurrent input transaction and activation transaction cannot see one another's uncommitted rows. Each model has at most one live leased job; separate models retain independent leases. A stale token, expired lease, disabled activation, superseded input revision, mismatched owner/device or checkpoint cannot publish a result. Successful abstention is distinct from execution failure: timeout, crash, corrupt output and temporary raw-object/catalogue failures retry with exponential backoff, at most four attempts per immutable job. New input or activation creates independent debt after exhaustion. No model waits while holding a deterministic input gate.

Missing qualified acquisition proof enters a durable 15-minute waiting state without consuming the failure budget. A newly registered matching proof wakes waiting work immediately; it does not require changing the checkpoint or pretending that source data changed. Contracts cannot be updated by the service, and ordinary deletion is denied. Existing account/device erasure retains its deletion cascade. Proof bytes remain subject to the assembler's object, ownership, scope, sampling, channel, timing and pipeline checks; inserting a row is not by itself sufficient qualification.

The full attempt, including database assembly before Python starts, has a 180-second watchdog. Dedicated model database connections also have a 15-second statement deadline and 20-second socket timeout. The watchdog stops renewals, aborts active JDBC connections, interrupts inference, and exits the isolated worker process after durably recording a retry when possible. If a process crashes first, lease-expiry handling applies backoff before allowing a retry, so one owner's hanging job does not immediately consume consecutive model slots ahead of other users. The deployment restart policy starts a fresh bounded process; deterministic scoring and other model processes remain independent.

The authenticated `physiology_shadow_model_for_day(model,day,device)` RPC requires an owned device and returns only the selected activation/current input revision. It includes explicit `publication_mode: shadow`, `canonical_outputs_allowed: false`, job status and immutable identities. It does not participate in canonical feature selection. The app does not silently replace its canonical output with this research readback.

## Resource and deployment controls

The optional compose template is behind the `qualified-shadow-model` profile, uses one model per worker, a read-only filesystem/assets, 1 CPU, 3 GiB container memory, 64 PIDs, bounded temporary storage and no added capabilities. These are conservative engineering limits, not measured capacity recommendations. Python receives no database/B2 credentials; child execution has bounded input/output sizes, process lifetime and model memory. Its package/checkpoint/environment contracts remain independently checked. The combined image must be built from the pinned reviewed model bundle and identified by its immutable digest.

Each Python job receives a private temporary cache directory for libraries including Numba. It is removed after child completion, including failures/timeouts. Parent cache locations and credentials are not inherited; `HOME` is not rewritten and immutable checkpoints/source remain read-only. The native numeric-UID probe found the missing-cache failure that a root build-time import did not detect.

`scoring-service/Dockerfile.model` combines the pinned Linux/amd64 Python bundle with pinned JVM build/runtime images. Build with `--platform linux/amd64 --build-context model_bundle=/path/to/verified/bundle`; the Docker build verifies the complete bundle and performs an offline hash-required wheel installation. This is an executable build recipe, not evidence that the Linux image or target VPS has been qualified. Runtime environment review and acquisition/reference gates are still required.

Use the existing serial `physiology_inference.resource_benchmark` and the new bounded `physiology_inference.concurrency_benchmark` on the authorized actual VPS. The concurrency harness permits 1–4 slots and 2–100 iterations, reports latency/throughput/failures/repeatability, and requires a dedicated externally attested Linux cgroup for aggregate CPU/memory qualification. It never substitutes summed child RSS for whole-process memory or labels cgroup charged memory as RSS. Run increasing concurrency in separate dedicated scopes and compare ingestion/database/JVM headroom before changing deployment limits.

Example (paths and inputs must be supplied and reviewed; not an executed VPS command):

```sh
python -m physiology_inference.concurrency_benchmark \
  --job /qualified/job.json --activation /qualified/activation.json \
  --asset-root /qualified/assets --concurrency 2 --iterations 10 \
  --tolerance 0.000001 --process-cgroup /sys/fs/cgroup/qualified-benchmark \
  --output /evidence/concurrency-2.json
```

The tolerance and resource budgets must be frozen before examining benchmark results. Missing cgroup accounting yields `not_ready`, not a capacity claim. The benchmark replays identical immutable input to measure execution resources, not physiological accuracy.

## Verification and external blockers

Development verification passed the disposable PostgreSQL queue/publication suite after the independent review repairs, including the actual two-transaction activation/input race. Focused JVM tests exercise deterministic/model separation, malformed owner envelopes, catalogue outages, timeout, crashed child and corrupt child output. Python concurrency tests verify bounded parallelism and fail-closed reporting when aggregate resources are absent. The lead's exact-final-head ledger supersedes these development runs.

Actual VPS access is restored. Native combined-image execution and synthetic probes are recorded in the [resource report](vps-resource-report.md), including the initial cache defect and separate repaired-image evidence. No production activation, deployment, reference-dataset access or production migration was performed. Synthetic native timing does not establish representative target-input throughput, WHOOP signal compatibility, reference accuracy or production qualification.

The deterministic deployment script preserves previous v2 containers and configuration until the exact candidate demonstrates advancing hosted polls and publication when eligible debt exists. Actual database/REST destinations must match the intended configuration without exposing credential values. Migration `20260919010000_physiology_worker_heartbeats.sql` supplies process-attributed liveness: a fresh deployment UUID, a distinct random UUID per JVM boot, and the immutable image source revision. Another process's global heartbeat cannot satisfy acceptance; a watchdog restart gets a new process identity rather than inheriting old progress. The global heartbeat remains for compatibility, not release attribution.

Startup, identity, progress, restart-policy or rename failures trigger bounded ID-based rollback; legacy/model/archive processes are not replacement targets. Dedicated hosted configuration is required; missing configuration fails before cutover. Default acceptance returns `NOT_READY` when VPS evidence is missing; explicit `--local-only` does not claim deployment verification. SSH uses only the explicit deploy key on port 22, and the connection parser does not source console-password fields. These scripts were fault-tested, not executed as a production deployment in this task.

Activation is not scientific promotion. All learned results remain shadow. The independent feature promotion gate still requires immutable feature manifests and human-signed ECG/PSG/respiratory-reference evidence; merely changing model selection or a qualification row cannot bypass it.
