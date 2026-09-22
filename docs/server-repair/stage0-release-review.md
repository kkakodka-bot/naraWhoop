# Independent Stage 0 release and lineage review

Reviewed 2026-09-22, using local Git objects, current source and preserved artifact bytes. Original checkout and both input worktrees were not modified. Merge resolution work is confined to the separate server-repair worktree.

## Verified inputs

- Integration worktree: `/Volumes/Untitled/WHOOP NARA-release-integration`, clean, `release/integration`, tip `e499162b4a0ce340b564e0232af14b5af355d6f1`.
- Frozen executable source: `33a38c5167afec5beeadd700be714e89fa25fb57`, tree `ac214a04747732cbd0a7aa14208eddd8b0c360dd`.
- Tip `e499162` has exactly that frozen commit as its parent; `git diff --stat 33a38c e499162` contains only the 574-line added `HANDOFF_release.md`. No executable change intervenes.
- PR22 worktree: `/Volumes/Untitled/WHOOP NARA-persistent-sync-followup`, clean at `a972493212f2eae29f01ecaddf9182260153400f`.
- Actual merge base is `97704bdf8e4ab802083070d8d45664ade51c1f6c`; actual integration has 213 unique commits, PR22 has 46. The supplied public PR28 count is not this integration's count.
- `git merge-tree --write-tree --name-only e499162 a9724932` gives 42 conflicts and preview tree `f6d73022eeeb4242438181023e3ee96a229d2ba6`. This preview has conflict markers and is not an accepted source. Integration changed 1,564 paths since the base; PR22 changed 263, with 80 overlapping paths.

## Independent artifact checks

Artifact root: `/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57`.

Reran the source's real offline verifier:

```sh
node Tools/release/release-artifact-manifest.mjs verify \
  --repo-root '/Volumes/Untitled/WHOOP NARA-release-integration' \
  --artifact-root '/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57' \
  --manifest '/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/release/release-artifact-manifest.json'
```

Result: `ARTIFACT_MANIFEST_VERIFIED`, semantic fingerprint `f9e01e1d5214883e2041ac592cf9c1f5ce6cfc34fae22597ea7b4e52a5ca7af3`.

Independently hashed the following bytes and matched receipts:

| File | SHA-256 |
| --- | --- |
| Integration `HANDOFF_release.md` | `1dd89d886e5a72800fb5ccfee1a8796ecabdfdfb7563ba39adb22072ca8462c0` |
| `release/finalization.json` | `1f1c97a2c9b90bd234a05bb7e47ae41f219437f64d0e0d9f273d1ad1d7ccb744` |
| `release/release-artifact-manifest.json` | `2a1a8177643f38a63b942e3d4e5673fb943bc46ed93c1cfabbc2700436270581` |
| `migrations/artifacts/migration-manifest.json` | `6c54aa047fbdb2e7da2b1412d06a69e5b82603c8501c3c061559cd5b57205ac2` |
| `capacity/capacity-measurement-summary.json` | `84be3011a02ae195f31e410495509cb8ff354667f8a20c4d0e94607a2a147de0` |
| `capacity/launch-capacity.json` | `2ae722f093476f9143c93dad4eb260b5fe049857b6883dabc9dc6619c9f09bae` |

Also independently verified all 288 capacity inventory entries, plus finalization's handoff validation, final verifier log, capacity environment and capacity inventory references. Existing iOS inspection binds build 371 / version 11.1.1 to source `33a38c...`, with final-hosted mode enabled. A build number alone does not prove this artifact is installed.

These checks verify preserved local artifacts. They do not verify current production worker identities, project binding, phone installation, or physical results. The recorded release explicitly says no worker/Edge deployment, no migration apply, no phone install, no main merge, no 24/72-hour soak. Capacity evidence remains a local scalar fixture: 1,000-owner live p95 80.753 seconds exceeds its 60-second SLO; target VPS capacity is NOT_MEASURED. The 10-owner/20-device/four-worker conditional canary policy is not a target-VPS throughput measurement.

## Complete PR22 semantic groups to preserve

1. Capture pressure and durability: shared FIFO/storage/cloud admission `95cf154`, atomic raw/quarantine maintenance `dc110f9`, historical evidence single commit `ef8cbdd`, 10,000 FIFO chaos `c6e8507`, deferred-maintenance/retirement tests `b77494d` and `260ee57`, bounded receipt-gated pruning `8cdab7e`, measured writer/durability phase separation `b848c11` and final label tests `a972493`.
2. BLE lifecycle: scripted transport and current intent `f082596`, finite setup completion lease `3c89e79`, account-fenced sync presentation `6f9a03c`. Integration sensor acquisition/reset/final-hosted gates must survive these edits.
3. Cloud durable control and streaming: retry/terminal control state `cad084b`; bounded wake rows/bytes/duration `829e6d8`; pinned portable zstd `7b5af01`; streamed compression `c0a15d8`; SQLite debt `1968dbb`; immutable file-backed selections `3104913`; retired packing-directory fence `2c4a565`; pressure rechecks `014583d` and `1b93188`.
4. Mutable identity and source settlement: atomic mutation/deletion journal `c051551`; no-skipped-ties paging `b40659b`; indexed source membership `443c56c`; exact replay/device rotation `e5aee21`; immutable wire representation identity `1926038`; rotation/recovery fences `a81b119`; real receiver replay/compression tests `e66e5b5` and repeated replacement tests `bf0aaea`.
5. Server object lifecycle: leased copy intents across account deletion `36d3a31`; async verification leases and exact receipt polling `d971034`; preserve integration enrollment, canonical device/source identity, fleet admission and final-hosted publication contracts.
6. Full CI/source fixture evidence, localization and calendar-day caption correction: all remaining unique followups belong to the full merge, not a headline cherry-pick.

## Common-base construction and assigned upload merge decisions

Construct a full two-parent merge in an isolated worktree from integration e499162 with PR22 a9724932, resolve semantic groups independently, then rerun changed contracts and publish only that reviewed merge SHA to the BLE workstream. Do not replace integration with PR22 or select one side globally.

The uncommitted merge includes 126 migration filenames, preserving the integration's 124 and adding `20260922010000_object_copy_intents.sql` and `20260922020000_async_object_verification.sql`. Release code currently hardcodes 124/117 and the prior manifest fingerprint; regenerate the complete source catalog and release expectations from final files. Preserve duplicate timestamp identities using complete filenames and hashes. Do not present this 126 count as the final repair count if later migrations are added.

Assigned `Packages/NoopPush/**` and `Strand/Push/**` conflict decisions:

- Keep full PR22 file-streamed immutable object upload and wake-byte admission, combined with integration destination-current checks before refreshed PUT.
- Keep exact integration object-key/owner receipt assertions and use PR22 `wireSHA256`/`wireBytes` without materializing streamed payloads.
- Keep `CloudRuntimeIdentity` enrollment/account fencing and fleet authorization; add fleet header to PR22's new persisted control-request route, which otherwise silently loses enrollment authorization.
- Keep PR22 SQLite rotation/checkpoints; remove superseded UserDefaults rotation helpers, while retaining enrollment-scoped capability cache validation.
- Keep integration receipt-upgrade/fleet/retry recovery fields together with PR22 signed-URL-renewal state.
- Keep integration credential refresh refusal for enrollment, plus durable control queue routing, streaming preparation, exact async completion mode and PR22 pressure lanes that permit old debt to drain a full queue.
- Normalize duplicate auto-merged `ResourceBudget` members and constructor arguments to the final trailing injected argument. The native tests must retain their specific deterministic budget while adopting this one argument location.
- Production wrappers preserve trace events and current-owner checks around PR22 file uploads.

No Git add or commit was performed by this reviewer. Final common-base acceptance is pending the root's independent review and source-bound combined tests.

## Upload/package validation

`swift test --package-path Packages/NoopPush --scratch-path /private/tmp/server-repair-nooppush --jobs 4` passed 141 tests, zero failures, after reconciling integration-only test accesses with PR22's throwing payload getter and making PR22 positive receipt fixtures conform to integration's stricter owner/device/stream object-key shape. The first merged fixture run failed those checks; production receipt admission was not weakened. Final log: `/private/tmp/server-repair-nooppush.log`.

`swiftc -frontend -parse` passed the seven edited production CloudUpload/Push Swift files. `git diff --check -- Packages/NoopPush Strand/Push` passed. App-linked runtime compilation and the native cloud queue harness remain the independent native reviewer's responsibility; package tests alone do not establish the phone path.
