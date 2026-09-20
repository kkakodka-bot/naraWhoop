# FRWHOOP_v2 scope

This repository is a **fork** of upstream [NOOP](https://github.com/ryanbr/NOOP). This fork requires
an enrolled tester account on Apple and Android. Bluetooth collection and a durable upload buffer
remain on the phone; authenticated server results supply the cloud physiology view.

## What differs from upstream NOOP

FRWHOOP_v2 operates a **hosted Supabase + Backblaze B2 receiver** and VPS scoring workers for enrolled
testers. Personal installation credentials determine the owner; the shared fleet credential only
authorizes a build. Upstream NOOP's "no server" rule does **not** govern this fork's `supabase/`
tree, Edge functions, or hosted migrations. See [tester enrollment](TESTER_ENROLLMENT.md).

| Layer | Path | Role |
|---|---|---|
| On-device apps | `Strand/`, `StrandiOS/`, `android/`, `Packages/` | BLE, owner-scoped buffers, server readback, existing local ancillary features |
| Push wire | `Tools/push-conformance/`, `docs/PUSH_PROTOCOL.md` | Contract between apps and receiver |
| Hosted receiver | `supabase/functions/push` + workers | WAL → B2 → Postgres projections |
| Ops | `Tools/monitor-fleet-push.mjs`, `supabase/functions/ingest-verify` | Fleet health, pipeline verification |

There is **no Node API** in this fork. The retired Node server tree was removed in Phase 6
(see `MIGRATION.md`).

## Privacy

The hosted stack stores health records uploaded by enrolled installations. New and upgraded installations
must enroll; unassigned legacy local health history is retained separately and never automatically
assigned to a new account. Pairing metadata is preserved without rerunning strap reset. No third-party telemetry is added beyond
what Supabase/B2 hosting inherently logs. Account deletion is a resumable worker (`account-deletion`)
that wipes B2 prefixes and Postgres rows before Auth.
