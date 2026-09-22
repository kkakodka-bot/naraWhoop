# NARA WHOOP scope

This repository is a **fork** of upstream [NOOP](https://github.com/ryanbr/NOOP). The cross-platform
apps (Swift packages, Android, macOS/iOS targets) preserve offline wearable capture and durable local
staging. The production-sync specification adds account-scoped cloud ingestion and server-owned
derived results. This is an implementation target, not a claim that deployment or device gates passed.

## What differs from upstream NOOP

The supported server stack is Supabase Edge/Postgres, a JVM scorer on the self-hosted/VPS deployment,
and Backblaze B2 object storage. Ordinary clients authenticate as individual users; a fleet-wide
ingest token is not the multiuser identity model. Upstream NOOP's no-server rule does not govern
this fork. The effective installed endpoint and running server revision must still be verified.

| Layer | Path | Role |
|---|---|---|
| On-device apps | `Strand/`, `StrandiOS/`, `android/`, `Packages/` | BLE, durable account-owned staging, upload state and bounded result cache; live HR stays local |
| Push wire | `Tools/push-conformance/`, `docs/PUSH_PROTOCOL.md` | Contract between apps and receiver |
| Hosted receiver | `supabase/functions/push` + workers | WAL → B2 → Postgres projections |
| Server analytics | `scoring-service/` | Versioned, device-specific snapshots, fenced queue leases and independent archive retries |
| Ops | `Tools/monitor-fleet-push.mjs`, `supabase/functions/ingest-verify` | Fleet health, pipeline verification |

There is **no Node API** in this fork. The retired Node server tree was removed in Phase 6
(see `MIGRATION.md`).

## Privacy

Capture, upload and readback must use the same validated project/account namespace. Logout hides local
health data and fences old operations; pending bytes remain associated with their original owner.
Legacy unowned files are preserved separately, not relabelled from the next login. HealthKit consent
is explicit per account; existing system permission is not consent to import into another account.
Performance diagnostics remain local and bounded; no external telemetry sender is added.

Account deletion remains a separate explicitly requested lifecycle. The server worker deletes object
prefixes and Postgres rows before Auth. It is not a troubleshooting or migration shortcut.

## Activation and evidence

Each visible derived metric needs one authoritative producer. Capability and activation must be
confirmed before suppressing its local producer. Once activated, outages show cached/stale status,
not repeated whole-history local rescoring. Unsupported or absent physiology is not zero-filled.

The complete scope and open verification gates are recorded in
[`IMPLEMENTATION_STATUS.md`](../production%20sync%20docs/IMPLEMENTATION_STATUS.md).
Code/build success, local integration tests, staging deployment, physical-device performance and
physiological validity are separate claims. Production writes, deployment and phone data replacement
are not authorized by this implementation task.
