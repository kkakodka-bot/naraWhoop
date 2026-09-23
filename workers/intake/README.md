# Continuous durable intake

This service runs the existing exact-byte verifier, archived scalar projection and legacy repair through three independent, serial lanes. A slow waveform COPY/GET does not occupy the projection lane. Each poll claims at most one object. Durable PostgreSQL leases, immutable receipts and atomic projection settlement remain authoritative after process interruption. Physiological inference remains in the separately selected scoring workers.

`20260922120000_intake_service_contract.sql` must precede the service and matched Edge `push`. It repairs verified metadata only after actual byte verification, preserves per-installation observations and conflict exclusion inside the atomic archive/debt/ACK transaction, and fixes whole-row JSON extraction for gravity's `x` channel. Applied migrations stay immutable. The raw-input trigger still invalidates decoder qualification when object metadata changes; byte verification alone does not qualify a model input.

New asynchronous completion requires both `NOOP_ASYNC_OBJECT_VERIFICATION=1` in Edge configuration and an actual successful verification queue poll from a compatible contract within 30 seconds. The flag defaults off. Existing debt can still be polled and drained with the flag off. A current empty poll establishes consumer liveness only; it does not establish throughput, storage health, capacity, or phone continuity.

Build from the reviewed clean combined SHA using `infra/vps/templates/Dockerfile.intake`, with `SOURCE_REVISION` set to that SHA. Record the resulting immutable image digest; do not promote a dirty fixture image. `docker-compose.intake.yml` uses an explicit immutable image, a dedicated deployment instance UUID, CPU/memory limits, no ports, a read-only filesystem and a five-minute stop grace period. The packaged revision, supplied revision and expected hosted project must agree at startup. Startup fails if the migrated contract differs.

The service requires these private environment values in the configured intake/B2 environment files:

- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`; the URL must exactly match `https://<INTAKE_EXPECTED_SUPABASE_PROJECT>.supabase.co`.
- `B2_S3_ENDPOINT`, `B2_BUCKET`, `B2_KEY_ID`, `B2_APPLICATION_KEY`, optional `B2_REGION`; the endpoint must use HTTPS.
- Deployment inputs `INTAKE_WORKER_SOURCE_REVISION`, `INTAKE_WORKER_INSTANCE_ID`, `INTAKE_EXPECTED_SUPABASE_PROJECT` and `INTAKE_WORKER_IMAGE`.

Use the same image with `--once` for a bounded three-lane poll, or `--status` for the read-only sanitized status RPC. Status includes a bounded pending-count sample (explicitly marked if truncated), oldest debt age, and actual polls/claims/completions/failures from the last 15 complete minutes. A newly started service will have no completed-minute rate yet. Queue rows and minute work aggregates, rather than log heartbeat messages, provide the readout. Raw objects, owner/source IDs and physiological values are absent from status output. The existing six-hour reconcile schedule remains maintenance; it is not the continuous consumer.

Deployment remains approval-gated and coupled to the migration, selected baseline worker, Edge functions and exact phone build. Before opt-in, verify project/source/image identities, actual queue drainage, exact-byte receipts, settled projections, selected work revisions, immutable results and authenticated native readback. Measure locked-phone continuity and target-VPS capacity separately. No 1,000-user claim follows from local tests or an empty queue.

Rollback: disable the Edge async flag first, retain this compatible consumer until all admitted debt is drained, then stop only this owned service. Keep durable queue/receipt tables and the forward migration. A stale client requesting new async work receives a retryable unavailable response; existing debt retains its receipt/pending response. Do not roll back to an Edge completion implementation that bypasses debt fencing, revert applied migration files, discard object versions, or reset phone storage.

Local validation uses `PIPELINE_TEST_INTAKE=1 scoring-service/scripts/test-server-pipeline.sh` on the dedicated local Docker context. It exercises real PostgreSQL/PostgREST and signed streaming S3 calls against an explicitly synthetic loopback object server. This is source/runtime integration evidence; provider storage, target VPS and physical phone acceptance remain separate.
