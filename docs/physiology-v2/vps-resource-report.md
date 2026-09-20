# VPS resource report

Status: SSH and native combined-image packaging are verified. **Production capacity and model activation remain NOT_READY** without acquisition-qualified jobs, sustained mixed load and independent resource approval. Earlier no-access statements are superseded by this continuation.

| Required evidence | Result |
|---|---|
| Authorized target host/session | Verified deploy-key SSH on port 22; native Linux x86_64, 4 vCPU, 8,326,934,528 bytes RAM |
| Deployed exact-head JVM/model image digest | Not deployed |
| Reviewed Linux model environment | Combined image built; non-root read-only execution found a cache defect, repaired and rerun separately |
| Representative verified target inputs | Unavailable |
| CPU, whole-process memory, p95 latency | Frozen synthetic probes bind their own source/image/runtime/checkpoint; results below and final-head ledger |
| Throughput and concurrency | Synthetic serial/two-child cases are not sustained production capacity |
| Ingestion, database and deterministic-worker headroom | Resource observations only; representative mixed-load capacity not established |
| Resource-budget qualification | Blocked |

The target had approximately 6.3 GB available RAM and 144 GB free root-disk space before candidate work. A separate BuildKit instance was capped at one CPU/3 GiB/no additional swap and stopped before probes. Existing services were retained. The [read-only diagnosis](vps-continuation-20260919.md) distinguishes the observed local scorer from the hosted database receiving phone uploads.

Implemented evidence tooling:

- Serial and 1–4-slot concurrent inference benchmarks over immutable input/activation/checkpoint identities.
- Dedicated Linux cgroup-v2 CPU and charged-memory accounting, with unavailable values when the scope cannot be proven.
- Bounded processes, input/output sizes, 180-second complete-attempt watchdog and independent durable model queue.
- Opt-in deployment template capped at 1 CPU, 3 GiB memory and 64 PIDs per worker. These are unqualified engineering limits, not measured throughput recommendations.

## Native image and initial failure

Committed source `fa7fe6b1f0161011a9481cb52630ec5586b52cb0` built as image `sha256:a11e74e0909935516b91bd2fe38e0c0a1f867a7cf6a9711987fd1142905476c0`. Its JVM manifest export matched the commit's recorded manifests byte for byte. All 33 hash-pinned wheels installed offline and `pip check` passed.

The first four frozen probe cases attempted twelve records and completed none, without OOM. Upstream Numba's cached decorator had no writable cache under numeric UID 65532 and a read-only root filesystem. A scoped temporary-cache diagnostic then executed the actual 20-epoch checkpoint successfully: 4.70 process CPU seconds and 422,649,856 bytes peak process RSS. This diagnostic is not a complete benchmark pass. Production and probe child environments now use private per-job cache directories without making model assets writable or inheriting credentials.

## Frozen synthetic measurement contract

All four plans are frozen before inference: 20 epochs (ten minutes) with four repetitions, and 960 epochs (eight hours) with two repetitions, each at concurrency one and two. Each record starts a fresh child and loads the actual released checkpoint. Plans bind source, image, probe, runtime, checkpoint/config, generated-input recipe and budgets. Engineering limits are 120 wall seconds per record, 60 aggregate CPU seconds per completed record, and exact within-environment output repeatability; they are not production acceptance thresholds.

Each fresh container has a private cgroup, no network/credentials/ports, read-only image filesystem, UID 65532, two-CPU cap, 3 GiB charged-memory cap, zero swap and 128-PID cap. Only bounded `/tmp` and a task-specific evidence directory are writable. Whole-cgroup CPU and kernel-charged peak memory include all descendants. Charged memory is **not aggregate RSS**. Latency includes startup, input generation, hash checks, import/load/inference and output, excluding executor waiting. Two/four repetitions cannot establish stable tail latency. JVM assembly/activation/queue work, ingestion and database load are excluded.

Retained initial evidence: `/Volumes/Untitled/physiology-build/pr23-vps-continuation.XAneBg/` contains frozen plans, failed reports, native build log, JVM manifests and cache diagnostic. Remote scratch `/var/tmp/physiology-pr23-benchmark.riqlDJ` contains only committed build inputs, verified public model assets and synthetic evidence. Repaired-image measurements and final acceptance identify their own source/runtime/image, never inherit the initial image's identity.

## Repaired native checkpoint measurement

On 2026-09-20 01:01–01:03 UTC (September 19 local time), all four cases completed with exact repeated output hashes and passed their predeclared diagnostic budgets. No container OOM occurred. These are pre-final-integration measurements; the final-head handoff binds its own rebuilt image and rerun evidence.

| Identity | Value |
|---|---|
| Source commit | `aac2ca05921f688ff907e0a591fc5c96c84620aa` |
| Combined image | `sha256:e5ff2531bcd33032b13cf1e9cdaba0ce5228d5d654845dc10962c4534c60b1d6` |
| Python runtime | `adf6d8ede5e0bfaa7ec2be132fb5d39d4cdead8d02b9c51b30af6456f8559f2f` |
| Offline bundle | `169ddabaefc1161a42a7899449c1edf4b20e5ac1fe498e0bfa18fac6c6af7367` |
| Probe source | `cd8b151ab83cd4c23a869740baebd6638b7eada16d10eb5b295d89e1319cca66` |
| Released checkpoint | `ea6fb4410315cf6cce406fe1ffd44cba83e8dc69be6a69101aff62cc2cbee0bc` |

| Synthetic input | Concurrency | Completed | CPU seconds/record | Observed p95 seconds | Charged peak MiB | Observed records/hour |
|---|---:|---:|---:|---:|---:|---:|
| Ten minutes | 1 | 4/4 | 5.77 | 6.41 | 257.6 | 617 |
| Ten minutes | 2 | 4/4 | 5.73 | 5.95 | 467.8 | 1,221 |
| Eight hours | 1 | 2/2 | 9.20 | 9.67 | 517.9 | 390 |
| Eight hours | 2 | 2/2 | 8.81 | 8.96 | 939.4 | 804 |

The hourly figures are arithmetic extrapolations from two/four cold-child executions, not sustained throughput guarantees. Shared file-backed pages need not be charged to this cgroup; charged peak is not total resident memory. Each report also retains per-child RSS diagnostics without summing them into a fictional process-tree RSS. The JVM manifest export in this image matched the source commit byte for byte. Plans, reports and container image/exit/OOM records are retained in `evidence-cache-fixed/` and `probes-cache-fixed.log` under the evidence directory above. Co-resident resource observations are in `co-resident-cache-fixed.log`; the existing incorrectly targeted legacy worker was not exercising representative hosted scoring load.

A separate functional check also completed both ten-minute and eight-hour inputs with the production child 2 GiB virtual-address-space limit inside a one-CPU/3 GiB/64-PID, non-root/read-only container. This checks execution under the configured limits, not the missing acquisition, rights or activation contracts. Evidence: `production-limits-cache-fixed.log`. The CPU library used its available fallback when NNPACK reported unsupported hardware; no GPU or acceleration claim is made.

To unblock production resource approval: supply representative acquisition-qualified immutable jobs, freeze budgets independently, and measure sustained ingestion/database/JVM/model headroom and historical backfill cardinality on the exact reviewed image. No production deployment, model activation, source-selection change or canonical approval was performed. See [model execution](model-execution-production-candidate.md).
