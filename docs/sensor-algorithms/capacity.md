# Sensor pipeline capacity report

Target VPS capacity: `NOT_MEASURED`. No host, database, fleet or production measurement was made. The local transport probe below exercises synthetic framing, gzip readback and hashing only; it does not benchmark the JVM decoder, qualification, physiology estimator, storage/network or model inference.

## Rate and storage model

For users `U`, each signal's qualified native rate `f`, bytes per sample `b`, channel count `a` and observed fraction `d`:

```text
raw_payload_bytes_per_day = 86400 * U * sum(f * b * a * d)
retained_bytes = bytes_per_day * retention_days * retained_version_or_replication_factor
local_spool_bytes = observed_bytes_per_second * required_offline_seconds * safety_factor + metadata
```

Illustrative assumptions, not measured WHOOP rates: six-axis 100 Hz i16 IMU gives 103.68 MB/user/day; one-channel 24 Hz i16 PPG gives 4.1472 MB/user/day. At 1,000 users this is 107.8272 GB/day before framing, retransmission/WAL amplification, metadata, compression or replicas. A 1 GiB payload-only IMU spool would hold about 10.36 days under that assumption. Reserve headroom and include all streams; do not make an offline-retention promise from this calculation.

Synthetic five-minute NPB1 fixtures contain 366,010 IMU bytes (360,000 sample bytes plus framing) and 23,110 PPG bytes (14,400 sample bytes plus per-record framing). Periodic and pseudorandom fixtures show different compression ratios; neither is a representative real-wrist compression distribution. Measure compressibility over actual authorized rest/activity/noise/off-body periods and retain p95/p99 object sizes. Count requests, egress, retries, raw and derived retention separately.

## Compute and revision amplification

There are 288 five-minute attempts per 24-hour UTC device day, even when an attempt produces only a reason. Current deterministic orchestration reads bounded day/context inputs and may revisit the day's windows after new input. Budget full-day reader work and up to 288 window attempts per successful revision until measured incremental reuse is established. For `R` revisions/day and `A` retry/reprocessing factor, attempted work can approach `288 * R * A` per device/day. Do not assume only one new window is recomputed on every upload.

The raw waveform path caches completed extraction by proof digest and raw-manifest identity, with owner/device/window inside the hashed proof. Changed proof, relevant bytes or algorithm dependencies must invalidate reuse; unchanged features may be reused across publication revisions. A cache hit cannot authorize another source or a changed qualification. Measure both cold and warm paths, late historical data, conflicting duplicates and object overlap. Report cache hit rate, bytes fetched/decoded per revision and deterministic day-read time separately. Check that repeated whole-day work progresses beyond early windows when the working set exceeds the cache, including multiple owners and the 576 possible PPG+IMU windows per day. Cache hit rate and starvation behavior under that workload are `NOT_MEASURED`. The optional raw/model executor must remain bounded and unable to delay scalar/HRV publication indefinitely.

The implemented raw feature cache holds at most 2,048 successful small summaries, not decoded objects; newest contracts are attempted first. Raw extraction uses one worker and one completion-handoff slot with explicit admission, so an active stalled fetch rejects subsequent uncached work instead of growing a backlog. Each caller waits at most two seconds on that executor. Contract parsing, database reads, deterministic computation and serialization are additional work, not included in a claimed two-second end-to-end SLA. Admission limits are 8 MiB of capture contracts, 1,024 receipts, 300 objects/8 MiB each of compressed and decoded bytes per raw proof and 300 mapped one-second records per five-minute proof. The object count is bounded by the mapped record count, and the full required object set and aggregate byte budgets are checked before download; splitting identical records into smaller transport objects does not change accepted features. The object decoder's independent per-object hard limit is 64 MiB, but this feature lane admits only the smaller aggregate.

Android inventory decodes at most 16 half-hour segments per slice and can upload the indexed prefix while discovery continues. Ordinary inventory continuation does not consume the transport failure budget. Exact file snapshots are bounded to 4 MiB/1,800 records; descriptors to 512 KiB; framed archives to 9 MiB; upload selection to 5,001 rows. The membership SQLite main file has a 128 MiB page-count cap. This is not a total-disk bound: WAL, delete markers, file-store metadata and raw capture files remain separate. Discovery still enumerates/sorts all registered file headers under the store lock before selecting the bounded decode slice. Its metadata latency, long-term index/tombstone growth, compaction, battery cost and multi-week storage behavior are `NOT_MEASURED`. Existing raw recording pauses at its configured storage cap; the change does not silently prune on receipt or infer a retention guarantee.

```text
required_cores = U * jobs_per_user_day * measured_cpu_seconds_per_job / (86400 * target_utilization)
slots <= floor((available_RAM - ingestion_database_JVM_reserve) / p95_peak_slot_RAM)
backlog_drain_seconds = backlog_jobs / (service_rate - live_arrival_rate), if service_rate > arrival_rate
```

Reserve headroom for Postgres/Supabase calls, deterministic scoring, object decode buffers, compression, model process creation, JVM GC, archive retries and operating system. Test per-user fairness and service time tails while new live users arrive during outage recovery. Thread count and memory admission must bound global work, not multiply independently across child pools. Revisions, backfill and retries belong in the job arrival model.

## Reproduce local bounded probe

```sh
python3 -m unittest discover -s Tools/sensor-qualification -p 'test_*.py'
python3 Tools/sensor-qualification/benchmark.py --iterations 16
```

The tool performs four scenarios, three warmups and 1–64 measured iterations each; each window is 300 synthetic seconds. It reports SHA-256, source hash, source base revision, platform/Python, compressed and uncompressed bytes, p50/p95/p99 wall time, mean CPU, a separate traced-allocation run and whole-process peak RSS. It opens no database, network or credentials and creates no physiological value. The checked-in [`capacity-local-fixture.json`](capacity-local-fixture.json) is a single local run; output latency and RSS are not target-VPS estimates.

Before any later deployment decision, run the exact committed image on the intended VPS with reviewed, qualified representative jobs and fixed CPU/thread/memory limits. Record p95/p99 service time and peak RSS under concurrent ingestion, empty-input reasons, cold/warm windows, bounded model failure, late data, 24-hour backlog and a representative overnight fleet. Require spare live-arrival capacity during drain and a prespecified freshness budget. Until then throughput, operating cost, battery/offline endurance and capacity-supported user count remain `NOT_MEASURED`.
