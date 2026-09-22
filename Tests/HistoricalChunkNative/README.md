# Historical chunk process-death probes

```sh
zsh Tests/HistoricalChunkNative/run.sh /external/artifacts 10000
```

The runner builds the current production `WhoopStore` package and links its objects into a small
macOS executable. Each crash child creates its own synthetic store and calls `commitHistoricalChunk`.
Temporary SQLite triggers stop before/after the cursor statement; a GRDB transaction observer stops
before commit and after durable commit but before the API returns. Other stops cover transaction
admission and scripted ACK submission/ATT completion. Every stop uses an actual `SIGKILL`, with no
producer cleanup before the parent opens the database, verifies exact evidence and replays twice.

ACK/ATT witnesses are a file-backed scripted transport boundary. They are written only after the
production commit returns and the durable rows, raw evidence, debt and cursor have been verified.
They do not exercise `BLEManager`, Core Bluetooth callback ordering, UIKit expiration, or a real strap.

The full-disk case sets SQLite's real `max_page_count`, forces `SQLITE_FULL` during a production chunk
transaction, and verifies complete rollback followed by lossless replay after capacity is restored.
It does not claim host-filesystem `ENOSPC` or power-loss coverage.

The 10,000-chunk run uses bounded sequential production commits while one concurrent scripted
transfer action records an exact receipt, attempts a mismatched receipt, or leaves source data intact
for simulated transient/terminal responses. Duplicate replays preserve debt tokens. Revoked store
fences and wrong-account writes must fail before commit; the original owner reopens the same store.
There are no real requests, credential reads, background URLSession tasks or production HTTP retry
classifiers in this harness. Host RSS is reported as diagnostic data, not a phone memory gate.

Artifacts retain all synthetic databases, transport witnesses, build/test logs, a JSON test manifest,
and before/after source fingerprints. The runner never deletes its artifact directory. Fingerprint
changes fail the run. A dirty-source result remains working-tree evidence even when HEAD is recorded.
Physical tests, genuine iOS restoration, filesystem/power failure, radio throughput, thermal, battery,
Instruments, MetricKit and phone RSS gates remain `NOT_MEASURED`.
