# Shared repair acceptance ledger

Authoritative shared ledger for BLE and VPS repairs. Root integration owns this file; independent reviewers contribute linked receipts. `PASS_LOCAL` does not imply deployment, physical acceptance, or scientific qualification.

## Source and edit ownership

- Frozen common base: `76f2d70f621de91268e295ebcb6c6da29162991f`.
- Server: `/Volumes/Untitled/WHOOP NARA-server-repair`, `repair/vps-server-20260922`.
- BLE: `/Volumes/Untitled/WHOOP NARA-ble-repair`, `repair/ble-sync-20260922`, created at the common base. No BLE implementation has been integrated yet.
- Chat A owns acquisition, local durability, lifecycle, mobile transport/auth and `AppModel`/`SyncEngine` changes. Chat B owns server schema, producer queues, results, native result consumers, and the combined release. Coordinate shared-file changes before editing.
- Current Chat B boundary edits include `CloudAuthClient` compare-and-clear for a result-read 401, and foreground/pause notification from Android `MainActivity` to the result reader. They do not grant new capture execution time.
- Preserved raw contract: local commit before BLE ACK; exact source/device/batch/digest verified-indexed receipt before release; pending verification is not release authority; projection settlement and physiological input qualification are separate states. Async remains disabled until a matched continuously serviced consumer and explicit capability enablement.
- Supplied BLE prerequisites: `/Volumes/Untitled/ble-repair-prerequisites.MhTsik/STAGE0_BLE_INPUTS.md` plus its lifecycle, performance and auth reports. Their synthetic clocks are not locked-phone observations.
- `01_EVIDENCE_AND_DIAGNOSIS.md` and `04_VPS_ALGORITHMS_SPEC.md` have been read. As of the latest filesystem check, `/Users/rahulvijayan/Downloads/FRWHOOP_Recovery_Pack/` is absent. Exact `02_SHARED_CONTRACT.md` and evidence-pack reconciliation remain pending; the preserved interface in `STAGE0_COMMON_BASE.md` is not represented as the missing document.

## Gates

| Gate | State | Evidence / remaining requirement |
| --- | --- | --- |
| Both full histories and frozen release identity | PASS_LOCAL | `stage0-receipts.json`, `stage0-release-review.md`; both parents retained, old artifact identity independently checked |
| Common base native/schema regression | PASS_LOCAL | Stage 0 logs and receipts; subsequent changes need final combined rerun |
| Current real outage trace | DIAGNOSED | Hosted selected-v1 work is pending with no compatible selected worker; client-claimed digest/projection debt also requires settlement repair. Trace must retain historical-phone-snapshot and privileged-read limits |
| Atomic projection and continuously serviced verification | PASS_LOCAL | Forward migration and full-chain intake seven-step test pass; no hosted mutation |
| Real computed fixture through selected worker and handlers | PASS_LOCAL | Joined NDJSON/storage/receipt/automatic selected queue/baseline/real GoTrue and enrolled API/native decoder/cache chain passed; final-source rerun required |
| Scoped native cache, retirement and bounded catch-up | PASS_LOCAL | Swift 43 and Android 37 focused tests passed, including bounded visited-day polling and actual lock-order regression; no installed phone claim |
| Complete bounded raw model assembly | PASS_LOCAL | Full-schema 70-test run passed without skips, including 1/9/257 shards and input-gate concurrency; acquisition qualification and models remain separate |
| Per-family numerical producer parity | INCOMPLETE | Existing shadow formulas and explicit missing states are not canonical producer closure |
| Zero local physiology with supported outputs | PARTIAL_LOCAL | Base app checks passed; exact final source and positive decoder/consumer evidence required |
| Final combined BLE/VPS source | PENDING_BLE_IMPLEMENTATION | BLE worktree exists at common base; merge actual completed BLE changes and retest |
| Matched artifact build and independent pre-canary review | NOT_READY | Freeze source and bind all migration/Edge/intake/worker/phone artifacts; no transferred old-build receipts |
| Deployment and phone installation approval | NOT_REQUESTED | Request only for a concrete reviewed matched plan |
| Actual enrolled/account phone readback | NOT_MEASURED | Normal authorized phone identity and connected phone required |
| Four-hour locked continuity | NOT_MEASURED | Actual elapsed capture, receipt and result continuity on matched phone/server release |
| 24-hour / 72-hour soaks | NOT_MEASURED | Actual elapsed workload, faults, durability and resource observations |
| Target VPS capacity | NOT_MEASURED | Measured real rates, raw-object sizes, inference mix and unfinished jobs; local 1,000-owner report does not establish capacity |
| Scientific reference qualification | NOT_MEASURED | Capability-specific synchronized independent reference; no fabricated beat timing, calibration or SpO₂ |

## Independent checkpoints

Diagnosis and common-base design were independently inspected by release, runtime, and acquisition/science reviewers. Implementation cross-review is in progress. Pre-canary and physical acceptance reviews have not occurred and cannot be credited from diagnosis reviews. Exact requirements in the missing shared contract remain to be reconciled.

No production deployment, model promotion, phone reset/installation, or main merge is authorized by this ledger. The original problem remains open until the supported deployed path and physical acceptance gates are measured.
