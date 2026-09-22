# Actual Swift receiver fixtures

From a clean checkout on macOS with Xcode selected:

```sh
zsh Tests/ServerFixtureNative/run.sh "$RUNNER_TEMP/edge-artifacts"
```

The output path must be fresh, absolute, and outside the checkout. The script creates it with
private permissions. It runs the two existing `PushAuxiliaryIdentityTests` export hooks and
`CloudImuPushSourceTests.testExportActualSwiftImf1FixturesForSessionAndContinuous`. All payloads
come from production codecs and actual canonical IMU files, membership SQLite and snapshot
adapters. Synthetic receipt helpers only compile the original test source; they do not produce
or replace exported object bytes. Authentication boundaries fail closed. The script runs no app,
BLE device, Keychain refresh, server request, or xcodebuild.

The native harness uses the production files also compiled by CloudUploadNative, plus the IMU
file store, index, exact archive and snapshot adapter. SwiftPM resolves the repository's exact
GRDB 6.29.3 dependency on a clean runner; warm caches are optional. Zstandard is the vendored,
pinned codec in NoopPush, not a Homebrew library. Swift source fingerprints must remain identical
before/after export. Package tests and the exact existing exporter test must succeed, and every
required output must exist. A failed export retains its directory and never overwrites evidence.

Outputs consumed by the Deno suite are `aux14-swift`, `aux14-swift-intake-v1` and
`imf1-swift-native-v1`. Source SHA, source fingerprints, fixture digests, SwiftPM build products
and separate test logs remain alongside them. They are synthetic codec/interoperability proof,
not physical strap captures, background behavior, thermal or production object-storage evidence.

The full server gate needs Deno 2.5.6, PostgreSQL and PostgREST (local evidence used 18.3 and 16.2).
Put `initdb`, `pg_ctl`, `psql` and `postgrest` in one tool directory, or symlink them there. For
example, CI can use `EDGE_TEST_PG_BIN="$RUNNER_TEMP/edge-bin"` after installing the tools. No
database URL or production credentials are accepted by the PostgreSQL fixture.

With the pinned Deno dependency cache prepared, run from `supabase/functions`:

```sh
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  EDGE_TEST_ARTIFACTS="$RUNNER_TEMP/edge-artifacts" \
  EDGE_TEST_PG_BIN="$RUNNER_TEMP/edge-bin" \
  DENO_DIR="$RUNNER_TEMP/edge-cache" TMPDIR="$RUNNER_TEMP/edge-tmp" \
  "$DENO_BIN" test --cached-only --frozen --lock=deno.lock \
  --allow-env --allow-read --allow-write="$RUNNER_TEMP/edge-artifacts" \
  --allow-run="$RUNNER_TEMP/edge-bin/initdb,$RUNNER_TEMP/edge-bin/pg_ctl,$RUNNER_TEMP/edge-bin/psql,$RUNNER_TEMP/edge-bin/postgrest" \
  --allow-net=127.0.0.1,localhost tests/
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  DENO_DIR="$RUNNER_TEMP/edge-cache" TMPDIR="$RUNNER_TEMP/edge-tmp" \
  "$DENO_BIN" check --frozen --lock=deno.lock push/index.ts reconcile/index.ts ingest-verify/index.ts
```

On an empty cache, first run `deno cache --frozen --lock=deno.lock tests/*_test.ts push/index.ts
reconcile/index.ts ingest-verify/index.ts` with the same DENO_DIR. That resolves public pinned
packages; test execution permits only loopback network traffic. Keep the artifacts path short
enough for PostgreSQL's Unix socket filename limit. The worker scheduling and B2 deployment
configuration remain separate release evidence.
