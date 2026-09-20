# W3 core status

The repaired baseline emits unknown epochs for absent or insufficient feature coverage, breaks temporal inference across gaps, and carries independent state, coverage, reasons, computation mode and algorithm version. Probabilities remain null unless actually supplied; the heuristic output is not calibrated. Qualified binary `sleep_unstaged` contributes to sleep; `state_unknown` and off-body do not. All-unknown daily estimates are unavailable, not zero sleep.

Full IANA calendar days, plus the preceding local day, replace the server's noon cutoff. Historical zone segments support DST and within-day travel, including disjoint ownership, skipped dates and repeated dates. The bounded context limit is 76 hours. Episode endpoint timezone IDs survive into both clients, with explicit UTC fallback for unknown historical metadata. A later profile change does not relabel historical events.

## Automatic full-day opportunities

The server uses `full-day-binary-shadow-1`: automatic candidates begin at 15 minutes, using sampled HR/motion feature coverage and a retrospective HR reference. There is no fixed bedtime or daytime exclusion. Short candidates remain binary sleep_unstaged when stage architecture is unsupported. Main grouping requires 90 minutes of accepted binary sleep and retains separate naps. These are unvalidated engineering policies. Reading/phone-use tests use independent annotations, not passive phone surveillance. False episodes/day, quiet-wake error and nap sensitivity require labelled reference data before promotion.

Grouped main opportunities retain explicit awake/off-body/unknown interruption epochs. None contributes sleep-qualified HRV or respiration. Estimated sleep onset/final known sleep remain separate from opportunity bounds; explicit manual bounds are not extended. Tombstones survive late changes to detected boundaries.

The optional causal context path does not run the retrospective stage model. It uses only context available by each epoch end and reports `causal_stage_model_unavailable` for unsupported stages. A trained/validated causal stage model remains unavailable.

Server epochs now pass through both owner-scoped caches into the actual sleep screens, retaining source/version, observed/computed/fetched times, revisions, coverage and processing/archive state. Legacy v1 snapshots use an explicit limited adapter. Account/session/request-generation fences suppress stale-user results. Both views distinguish estimated/reported opportunities from measured bed occupancy. Boundary edits use authenticated optimistic server overrides, never local writes. Legacy continuation preserves the source row and exact timestamps, requires a current owner/device-bound optimistic token, and retains edit/delete tombstones; six real PostgreSQL tests, native token projections and a smoke test on the full official Supabase PostgreSQL migration chain passed.

Snapshot computation filters future-dated samples and incomplete verified spans and publishes only closed HRV windows, without mislabelling retrospective output causal. This is event-time fencing, not a reconstruction of historical ingestion-time availability.

The global implementation ledger owns current test counts and final application build status. Paired synthetic fixtures cover naps, shift sleep, missingness, interruption accounting and manual tombstones; they establish implementation behavior, not PSG accuracy, physical background continuity or a trained causal model.
