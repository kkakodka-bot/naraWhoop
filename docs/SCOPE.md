# FRWHOOP_v2 scope

This repository is a **fork** of upstream [NOOP](https://github.com/ryanbr/NOOP). This fork requires
an enrolled tester account on Apple and Android. Bluetooth collection and a durable, account-owned
upload buffer remain on the phone; authenticated server results supply the cloud physiology view.
The production-sync specification adds account-scoped cloud ingestion and server-owned derived
results. This is an implementation target, not a claim that deployment or device gates passed.

## What differs from upstream NOOP

FRWHOOP_v2 operates a **hosted Supabase + Backblaze B2 receiver** and VPS scoring workers for enrolled
testers. Personal installation credentials determine the owner; the shared fleet credential only
authorizes a build. Ordinary clients authenticate as individual users. Upstream NOOP's "no server"
rule does **not** govern this fork's `supabase/` tree, Edge functions, or hosted migrations. See
[tester enrollment](TESTER_ENROLLMENT.md). The effective installed endpoint and running server
revision must still be verified.

| Layer | Path | Role |
|---|---|---|
| On-device apps | `Strand/`, `StrandiOS/`, `android/`, `Packages/` | BLE, owner-scoped durable staging, upload state, bounded result cache, server readback; live HR stays local |
| Push wire | `Tools/push-conformance/`, `docs/PUSH_PROTOCOL.md` | Contract between apps and receiver |
| Hosted receiver | `supabase/functions/push` + workers | WAL → B2 → Postgres projections |
| Server analytics | `scoring-service/` | Versioned, device-specific snapshots, fenced queue leases and independent archive retries |
| Ops | `Tools/monitor-fleet-push.mjs`, `supabase/functions/ingest-verify` | Fleet health, pipeline verification |

There is **no Node API** in this fork. The retired Node server tree was removed in Phase 6
(see `MIGRATION.md`).

## Privacy

The hosted stack stores health records uploaded by enrolled installations. Capture, upload and
readback must use the same validated project/account namespace. New and upgraded installations must
enroll; unassigned legacy local health history is retained separately and never automatically
assigned to a new account. Pairing metadata is preserved without rerunning strap reset. Logout hides
local health data and fences old operations; pending bytes remain associated with their original
owner. HealthKit consent is explicit per account; existing system permission is not consent to
import into another account. No third-party telemetry is added beyond what Supabase/B2 hosting
inherently logs. Performance diagnostics remain local and bounded.

Account deletion is a resumable worker (`account-deletion`) that wipes B2 prefixes and Postgres
rows before Auth. It is not a troubleshooting or migration shortcut.

## Activation and evidence

Each visible derived metric needs one authoritative producer. Capability and activation must be
confirmed before suppressing its local producer. Once activated, outages show cached/stale status,
not repeated whole-history local rescoring. Unsupported or absent physiology is not zero-filled.

The complete scope and open verification gates are recorded in
[`IMPLEMENTATION_STATUS.md`](../production%20sync%20docs/IMPLEMENTATION_STATUS.md).
Code/build success, local integration tests, staging deployment, physical-device performance and
physiological validity are separate claims. Production writes, deployment and phone data replacement
are not authorized by this implementation task.
