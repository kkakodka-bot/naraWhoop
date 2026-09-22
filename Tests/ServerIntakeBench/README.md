# Local intake phase benchmark

Run from this checkout with the pinned Deno cache and local PostgreSQL/PostgREST tools already
used by `supabase/functions/tests/README.md`:

```sh
zsh Tests/ServerIntakeBench/run.sh \
  /Volumes/Untitled/nara-persistent-followup-20260922/server-intake-benchmark-final 30 3 \
  > /Volumes/Untitled/nara-persistent-followup-20260922/server-intake-benchmark-final.log 2>&1
```

The positional arguments are an external artifact directory, measured repetitions per case,
and warmups per case. Defaults are 30 and 3 for all six cases. No production URL, credential, env file, deployment,
or real sensor capture is accepted. Services bind only loopback/private Unix sockets and are
stopped afterward. Disposable PostgreSQL evidence is retained under a short `/Volumes/Untitled/nara-ib.*`
directory (Darwin Unix socket path limit), recorded in the JSON report. The benchmark writes
`intake-benchmark.json`; the command log includes `/usr/bin/time -l` process statistics.

Six bounded cases exercise production `createPushObjects`, `completeDurableObject`,
`createPushIngest`, and `commitArchivedBatch`: approximately 64 KiB, 1 MiB, 4 MiB decoded NPB1 v2 PPG
objects (at most 2,000 synthetic rows; gzip level 3), and 50, 500, 2,000-row inline batches using the
production server gzip defaults. Binary sample values/entropy are artificial, not hardware
captures. The three sizes represent preparation/transfer budgets, not firmware framing proof.
NPB1 length and identity framing follows the current sender codec. No health values or identity
fields are written to the benchmark report.

Measured phases include intent, loopback PUT, staging HEAD, immutable COPY, GET headers,
streamed verification/decompression/hashing, receipt/index RPC, scalar projection RPC, complete
request, and duplicate complete request. Verification begins at the production GET call and
ends immediately before its receipt RPC. Nested inclusive durations must not be summed.
Duplicate completion is measured separately because current production code re-reads/verifies
the saved immutable object. Normal repetitions are independent jobs; fault-injection tests and
artificially aged sweeper records are not used as latency samples.

The fixture applies all current intake prerequisite migrations through080000 plus the copy-intent
migration, with a 120-second PostgreSQL statement timeout to bound failed experiments.
The database, PostgREST sockets, signing client, stream decoder/digests, and SQL receipt/index
transactions are real. Object storage is a RAM-backed HTTP fixture emitting 64 KiB chunks; its
buffers are evicted outside each measured window. HTTP handler authentication/gateway dispatch
is replaced by direct production service calls. Process CPU includes Deno and the object fixture,
but excludes PostgreSQL/PostgREST child CPU. RSS is sampled at phase boundaries and every 20 ms;
this is neither an exact peak nor phone memory. `time -l` describes the whole harness, including
setup/teardown. Process phases are descriptive under concurrent host work, not isolated regression
baselines. No benchmark case uses thermal or energy measurements.

The report includes source SHA plus a SHA256 manifest of server functions, migrations and this
harness, verifies that fingerprint stayed stable, records payload sizes/counts and all individual
phase observations, and reports p50/p95/p99/max. At 30 observations, p99 is simply the maximum;
it does not establish a fleet tail. Copy metrics are ledger estimates, not a bucket census.

`NOT_MEASURED`: actual phone-to-B2 latency, HTTP gateway/auth overhead, TLS/public network,
production storage permissions, physical object durability, server fleet scheduling, PostgreSQL
child CPU, iOS CPU/RSS, battery/energy/thermal, real waveform compression ratios, and server zstd
phase comparison. This harness supports a later async-verification design decision; it does not
change production endpoints, receipt semantics, or worker scheduling.
