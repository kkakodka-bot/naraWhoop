# VPS resource report

Status: **NOT_RUN / NOT_READY**. No measurement in this task establishes actual VPS capacity or authorizes model concurrency in production.

| Required evidence | Result |
|---|---|
| Authorized target host/session | Unavailable |
| Deployed exact-head JVM/model image digest | Not deployed |
| Reviewed Linux model environment | Build recipe/bundle tooling implemented; target image not executed |
| Representative verified target inputs | Unavailable |
| CPU, whole-process memory, p95 latency | Not measured on the VPS |
| Throughput and concurrency | Not measured on the VPS |
| Ingestion, database and deterministic-worker headroom | Not measured |
| Resource-budget qualification | Blocked |

Read-only checks found neither `infra/vps/droplet.env` nor `infra/vps/keys/frwhoop_deploy` in the isolated production-candidate worktree or its original PR16 checkout. No SSH attempt or production operation was performed. The repository's provisioned host description is not live hardware inventory.

Implemented evidence tooling:

- Serial and 1–4-slot concurrent inference benchmarks over immutable input/activation/checkpoint identities.
- Dedicated Linux cgroup-v2 CPU and charged-memory accounting, with unavailable values when the scope cannot be proven.
- Bounded processes, input/output sizes, 180-second complete-attempt watchdog and independent durable model queue.
- Opt-in deployment template capped at 1 CPU, 3 GiB memory and 64 PIDs per worker. These are unqualified engineering limits, not measured throughput recommendations.

The concurrency harness's three local synthetic tests passed; they establish control-flow and fail-closed reporting only. Released-checkpoint host execution, where separately reported by the model workstream, does not substitute for VPS measurement.

To unblock: provide the explicitly authorized target session, install the exact reviewed Linux image/checkpoints, supply representative acquisition-qualified immutable jobs, allocate an exclusive benchmark cgroup, and freeze resource budgets before running the serial/concurrent harnesses. Preserve host/image identity and measure co-resident ingestion/database/JVM headroom before approving any concurrency increase. See [model execution](model-execution-production-candidate.md) for the command and isolation contract.
