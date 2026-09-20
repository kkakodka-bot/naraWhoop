# FRWHOOP implementation agent instructions

## Mission

Implement `spec.md` against https://github.com/kkakodka-bot/naraWhoop. Deliver reliable BLE ingestion, resumable account-correct uploads, server-owned derived computation, instant cached display and measured iOS responsiveness. Start with the confirmed PR 15/16 defects. Preserve data while changing ownership and transport.

This file is intended for the repository root beside `spec.md`. Read existing root and nested agent instructions, `CLAUDE.md`, `docs/SCOPE.md`, the current code and this specification before editing. The user's requested server/multiuser architecture supersedes older owner-only/local-compute product assumptions; update stale documentation as part of implementation. Preserve established protocol and data-safety rules.

## Establish truth before edits

- Fetch current branch/PR metadata and record SHAs. Audit baseline: main `34fc950f`, PR 14 `293fd6b8`, PR 15 `331f339b`, PR 16 `5caa3168`. Reconcile later changes instead of blindly applying this historical diff.
- PR 15 is stacked on PR 14; PR 16 is separately based on main. Ensure the integration branch contains both lines and their regressions. Never assume PR 16 includes the PPG migration or session fixes.
- Read migrations and actual schema before altering an installed database. Preserve migration IDs and previously stored values. Use additive repairs for deployed schemas.
- Separate source facts, PR-author reports, locally reproduced behavior and verified deployed behavior in all updates.
- Record app build, endpoint, account/device ownership, local schema, server image/commit and server migrations. Do not infer deployment from repository files.
- Keep the retired Node backend retired. Extend the existing Supabase Edge/Postgres/JVM stack.

## Delegate in bounded workstreams

Use independent worktrees or explicit file ownership. The integration lead owns contract decisions, shared migrations, integration and release evidence.

| Agent | Scope | First output |
|---|---|---|
| BLE/ingest | W1: PR 14/15 integration, migration compatibility, ACK ordering, session fences, record identity | Reproducer and fixtures for legacy/research schemas and disconnect/crash transitions |
| Identity/upload | W2 and W5: per-account credentials, outbox/cursors, OS-managed upload lifecycle | Ownership/receipt protocol and account-switch regression tests |
| Server | W3: queue retries/leases, invalidation, object index repair, result generation and archive retry | Disposable-Postgres reproducer for eighth-success cutoff and stale-worker race |
| Analytics/readback | W4: metric ownership, server DTOs/RPCs, sleep/details, account-safe cache and observation | Metric/consumer inventory plus versioned snapshot contract |
| Performance | W6: main-thread work, bounded presentation, instrumentation and traces | Repeatable on-device workload and baseline profile |
| Independent reviewer | Cross-workstream correctness and adversarial recovery review | Findings with exact file/line evidence and reproduction conditions |

Identity and server work can proceed alongside BLE repair. Readback and upload must agree on identity and receipts before integration. Performance instrumentation starts early; remove work only after the replacement contract exists. The reviewer must inspect final integrated code, not only agent summaries.

Each implementation agent reports changed files, reproduced defect, chosen fix, test commands/results, pending risks and commit. Do not let agents concurrently modify the same migration or core lifecycle file without coordination.

## Non-negotiable behavior

1. **Commit before ACK.** Persist supported records and necessary recovery material before instructing the strap to discard history. No network wait on BLE ingestion; no ACK that erases the only copy.
2. **Durable local buffering stays.** Keep an outbox and bounded read cache. Prune raw data only after the required server durability receipt; do not delete unsent data to meet a cache limit.
3. **Preserve identity.** Retain recordIndex, sample units, source channel, device, account, timestamps and relevant timezone. Do not deduplicate distinct same-second records or combine WHOOP/Apple streams without an explicit policy.
4. **One owner per derived metric.** No silent blend of stale local and server results. Do not disable a metric's producer before a verified replacement is available. A temporary cloud outage shows cached status, not a whole-history local compute storm.
5. **Account isolation includes local state.** Scope cache, auth, upload cursors and pending files. Fence responses on logout/project/account changes. An old queue does not inherit the next logged-in user.
6. **Retries are idempotent.** Successful scores do not exhaust failure budgets. Lease ownership and input revisions protect result writes as well as queue settlement. Preserve new arrivals during a running job.
7. **Completeness is explicit.** Separate captured, committed, upload accepted, archive verified, indexed, computed and displayed states. Unknown or missing physiology stays unavailable/partial, never zero-filled.
8. **Background execution is opportunistic.** Use supported CoreBluetooth restoration, background URLSession and BGTask APIs. No busy loops or fabricated continuous-sync guarantee after force quit.
9. **Main actor renders.** Move database scans, sorting, compression, fsync and sustained analytics off the main actor. `async` or low-priority `Task` is not proof of isolation. Keep view payloads and UI publication bounded.
10. **No credentials in app builds or logs that grant fleet-wide/server access.** Server/service secrets remain server-side. Use validated user or scoped device credentials and enforce RLS.

## Required verification

Select tests for actual risks; avoid tests that only assert source strings or mirror the implementation. Run relevant existing suites, then targeted new regressions against real components.

- Swift: protocol, WhoopStore migrations, PPG identity, backfill/session/ACK and score-cache/readback tests; app compile and physical iPhone lifecycle tests through the available Xcode toolchain.
- JVM: from `scoring-service`, run `./gradlew :analytics-kernel:test :service:test :service:installDist --no-daemon`. Add disposable-Postgres integration tests for queue and result semantics.
- Edge: from `supabase/functions`, run `deno test --allow-all tests/` in an isolated test environment; verify auth/RLS using normal user tokens and fault-injected object completion.
- Android: compile the applicable variant and run protocol/analytics/cache parity tests when shared contracts change. Fix or explicitly report the existing continuous-IMU build blocker; do not remove failing gates and call the product green.
- End to end: trace one real supported record through local commit, receipt, input revision, scorer, result revision and UI. Test more than eight successive updates, late overnight data, multi-device source selection, duplicate input, network loss, expiration, account switch, process death and low disk.
- Device performance: Release builds; 60 Hz and ProMotion; cache-only launch, scrolling during backlog, sleep details, reconnect and upload. Use Apple's aggregate Hitches bands from `spec.md`, actual frame deadlines and Instruments/MetricKit evidence. Availability-gate metrics and record SDK/OS/tool versions; older scroll-only/XCTest metrics cannot independently certify the current aggregate Hitches measure. Do not substitute the app's fixed 33 ms display counter.
- Deployment: verify effective endpoint, migrations, image digest, advancing heartbeat and canary results. A skipped remote check is not a pass. Require locked-phone and overnight-through-wake evidence before broad activation.

If toolchains, hardware, credentials or network access prevent a gate, state the exact blocker and provide a reproducible command/procedure. Continue authorized work that does not depend on that gate. Never invent a passing test, device trace, measured speedup or production verification.

## Integration and handoff

Use small reviewable commits with source/transport compatibility first. Keep deployment and irreversible data operations within the user's actual authorization. Do not reset production, clear a phone container or delete pending data as a troubleshooting shortcut.

The final PR description must state: defect and affected conditions; changes; migration/compatibility behavior; tests actually run; before/after performance measurements; deployment/canary evidence; rollback; and remaining unverified items. Include which metrics are server-owned and which remain deliberately local during migration. Update `docs/SCOPE.md` and operational instructions to match the implemented state.

Stop optional testing once the required evidence is sufficient. Do not claim production readiness until the specified correctness, isolation, overnight and performance gates pass.
