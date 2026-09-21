# PR28 receiver integration repair

Status: source repair with local evidence; NOT DEPLOYED and not handset accepted.

## Observed incident

The deployed hosted `push` receiver returns legacy successful responses without the durability receipt required by build 364. Its database lacks `object_manifests.durability_receipt`, intake reservations and projection debt. Preserved phone journals show HTTP 200 followed by `receipt_mismatch`, with source progress retained instead of falsely acknowledged. Fleet authentication is present in those requests.

The VPS is not idle or disconnected from hosted Supabase. At 2026-09-21 03:25 UTC its worker heartbeat was current with no reported error; the selected-device result remained at input revision 296, computed at 00:51 UTC. The selected device had 15,000 HR samples, 5,002 RR rows and 16,000 gravity rows for September 20 UTC. The computed daily result contained 48 usable five-minute HR windows and 240 insufficient-sample windows. Most daily metrics were null. These counts do not establish beat continuity, sleep accuracy or physiological qualification.

## Source defects repaired

- Remove a premature reference to the archive result before initialization.
- Resolve the canonical device before reserving the durable batch, and pass it into the reservation RPC. Previously the reservation received no canonical device.
- Preserve the server-resolved device in projection settlement instead of recomputing the pre-enrollment unscoped identity. Database owner/device checks and exact returned-receipt comparison remain enforced.
- Record enrollment upload receipts after atomic projection settlement, including the retry path.
- Remove the obsolete object-intent retry shortcut that returned ready without a durability receipt. Retries now use manifest reservation and verification.
- Remove an undefined manifest-store export and duplicate step mapper; pass negotiated protocol version into scalar validation.
- Preserve negotiated object protocol versions in the HTTP handler instead of duplicate object-literal fields.
- Reconcile the two step-table definitions without dropping counters or replacing the table. Existing camel-case and new snake-case activity readers agree through a compatibility trigger; conflicting values are rejected. Immutable measurement protection remains in place.
- Seed the populated migration test only once when multiple migration filenames share a timestamp. Seed a historical step row before the schema merge and verify its original values afterward.

## Local verification

`enrolled_durability_integration_test.ts` runs actual PostgreSQL, PostgREST and loopback object storage. It checks canonical enrolled identity through reservation/archive/projection, stored HR, completed projection debt, idempotent retry, source mismatch refusal, receipt substitution refusal, object completion/intent retry receipts, both step column spellings and immutable-value protection.

The focused suite with `ingest_identity_test.ts`, `push_diagnostics_test.ts` and `devices_test.ts` passes 19 tests. `deno check supabase/functions/push/index.ts` and `git diff --check` pass. Both fresh and populated full migration chains pass, including original source-row preservation, historical step compatibility and unchanged physiology promotion defaults.

Evidence is retained outside the repository at `/Volumes/Untitled/pr28-systemic-link.D4yfWE`: `enrolled-receiver-final.log`, `cloud-chain-populated-final.log`, and the individual disposable database directories. The migration runner records the detailed migration hashes and logs in the directory printed by its result.

The full Edge suite is not an acceptance pass: 132 tests passed and 19 failed (7 passed steps and 42 failed steps). It still includes incompatible legacy identity/receipt fixtures, fault assertions that expect unmasked internal exception text, and unavailable cross-language fixture files. Their failures must be resolved or independently classified, not silently skipped for rollout. Full output is in `edge-suite-final.log`.

## Remaining deployment and recovery work

1. Build a uniquely numbered, reviewed forward upgrade for the actual hosted schema. The deployed migration ledger contains timestamps also used by different merged production migrations. A passing fresh combined chain does not make `db push` safe against that ledger. Preserve the newer deployed set-based projection optimization and existing scoring authority.
2. Test upgrade with existing legacy ACKs/manifests and installation provenance. Legacy inline ACK lookup and completed-debt replay still need a verified receipt upgrade without replaying stale corrections over newer data.
3. Roll out the compatible hosted receiver/schema together. Preserve a source/schema backup and verify receipt, projection, invalidation and readback separately.
4. Add bounded recovery for uploads paused by the old receiver's missing receipt. Never release phone rows on a legacy ACK or retry every terminal integrity error indiscriminately.
5. Install a verified new phone build only after the cloud contract is compatible; prove real retained-queue progress, new server computation and rendered values. Build 364 remains the last verified installed build.
6. Address enrolled profile/calendar synchronization and genuine physiological input/qualification gaps. Do not force the user's reported sleep boundaries, fabricate metrics, or treat raw row counts as validated coverage.

No production migration/function deployment, account reset, app deletion, physiological promotion or phone install was performed for this repair increment.
