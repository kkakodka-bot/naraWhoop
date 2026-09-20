# CLAUDE.md — working on FRWHOOP_v2

Read [`docs/SCOPE.md`](docs/SCOPE.md) first. This fork **differs from upstream NOOP**: it ships a
account-scoped Supabase/B2 push receiver (`supabase/functions/`) and a JVM scorer. The `supabase/` tree
and Edge workers are **in scope** — not an upstream violation.

For upstream app architecture (Swift packages, Android parity, BLE safety, CI), the parent project's
guidance still applies to `Packages/`, `Strand/`, `StrandiOS/`, and `android/`.

## Hosted stack (FRWHOOP-specific)

| Component | Path | Notes |
|---|---|---|
| Push receiver | `supabase/functions/push` | Bearer = Supabase JWT or opaque `noop_` ingest token; `verify_jwt = false` in config.toml |
| Workers | `retention-sweep`, `reconcile`, `account-deletion` | Auth = `WORKER_SECRET` or service-role bearer; scheduled via pg_cron |
| Ops verify | `supabase/functions/ingest-verify` | Slim pipeline report; ops-only auth (not user-scoped) |
| Migrations | `supabase/migrations/` | Never reset linked prod; additive only |
| Conformance | `Tools/push-conformance/` | `BASE_URL=…/functions/v1/push PUSH_PATH=` for Edge |
| Edge tests | `cd supabase/functions && deno test --allow-all tests/` | Gate: green after every Edge edit (baseline 38, +ingest-verify/auth tests) |
| Fleet monitor | `Tools/monitor-fleet-push.mjs` | Read-only Supabase probes |

There is **no Node API directory**. Do not reintroduce a Node API for push or scoring.

## Cutover record

Phases 0–7 are documented in [`MIGRATION.md`](MIGRATION.md). Key decisions:

- No relocation of vo2/math/metrics into a surviving Node layer — backend deleted wholesale.
- `ingest-verify` is a slim Edge rewrite (no diagnoseDay / replay accounting / persistSidecars).
- Coach tables (`coach_sessions`, `coach_messages`, `coach_memories`) remain as dead schema; apps call AI providers directly.
