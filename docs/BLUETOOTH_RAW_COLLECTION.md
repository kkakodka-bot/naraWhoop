# Bluetooth raw collection for the enrolled WHOOP

This change is based on `94fdced0`, the Event Recorder code used for the installed
NARA build 348. It preserves the serial historical offload actor, storage failure
circuit breaker, reconnect fixes, and bounded sensor-capture controller.

## Collection policy

- The explicitly enrolled research strap defaults to optical collection enabled.
  A per-device saved Off overrides the default and survives reconnects.
- Request the known raw producer and candidate optical-enable command once per
  connection. Opcode 107's effect on this firmware must be verified from data;
  no guessed AFE configuration or sample-rate payload is sent.
- **100 Hz optical is a requested target, not a demonstrated hardware mode.**
  Existing v20 records carry native per-slot sample counts (often 25); v26 carries
  24 samples. Channels are never added together or upsampled to claim 100 Hz.
- Keep the existing history chunk protocol. Native optical v20/v26 packets are
  written and fsynced before the chunk acknowledgment. Failure holds the ack and
  participates in the existing consecutive-write-failure circuit breaker.
- The continuous IMU recorder accepts only CRC-valid, complete 100 × 6 realtime
  packets (types 43/51) whose strap second is within -2/+5 seconds of receipt.
  Type 47 is always historical, including replay by another Bluetooth client.
  Historical IMU cannot fill continuous capture gaps, the enrolled strap's bounded
  IMU session windows, or its archive-repair path. Ordinary history stays enabled.
- The continuous command owner can issue only the evidenced 81/82/106 payloads,
  only for the enrolled strap, while bounded capture/cleanup is idle and the
  command lane is not tainted. It does not bypass bounded capture ownership.

## On-phone storage

- `Library/Application Support/OpenWhoop/RawOpticalBluetooth/optical-<hour>.jsonl`
  retains full checked frames in base64, device identity, native sample counts,
  strap time for known history layouts, and phone archive time (`recorded_at_ms`).
  This timestamp is the chunk commit time for history, not the original sensor time.
- Unknown non-IMU realtime payloads are labeled `live_raw_unclassified`. They are
  retained for decoding; their receipt is not proof of optical identity or rate.
- Optical files append by arrival hour. Replay duplicates are possible: readers
  must deduplicate using device, record index/timestamp, and exact frame contents.
  Files are not automatically pruned or uploaded. Disk failure is surfaced.
- Live IMU uses the new `RawImuLive` directory and `imu-live-windows-v2` registry.
  Previous `RawImuContinuous` recordings are left intact and are not presented as
  newly verified live coverage. Existing IMU retention limits still apply.
- The Test Centre optical card reports requested state, command response, packet
  counts, native sample counts, and write errors. A command ack is not recording.

## Verification

Tests cover native optical byte preservation, rejection of corrupt packets,
per-device defaults and opt-out, command acknowledgment without samples, disk
failure before trim ack, and IMU rejection of stale/history/corrupt frames.
Physical verification must separately check the native optical rate, actual live
IMU files, and successful ordinary history completion after installation.

No cloud destination or credentials are configured in the device build. This
request changes Bluetooth collection and local storage only.

## Physical verification — 2026-09-19, build 349

Installed and launched NARA `com.rahulvijayan.noop` on the paired iPhone 15 Pro Max.
The enrolled WHOOP reported firmware 50.41.1.0.

- Opcode 107 returned `FAILURE(0)` at 15:43:27 PDT. **100 Hz optical is not enabled
  or demonstrated on this firmware.** The app exposes the failed response and
  retains native data; completing that target requires an evidenced firmware
  control or another supported mode, not a UI setting or synthetic resampling.
- Copied and decoded 434 saved optical history frames, covering 433 unique seconds
  (`1789857463` through `1789857895`). All had native per-slot counts
  `[25, 0, 0, 25, 25]`; no frame was labeled verified 100 Hz.
- The archive advanced 432 sensor seconds over 92.118 wall-clock seconds, about
  **4.69× history progress**. This was mixed on-wire history with live IMU running,
  not an isolated optical bandwidth benchmark or a guaranteed rate. At that
  sustained total rate, net backlog reduction would be about 3.69 seconds/second
  while new data continues to accumulate.
- Normal history reached `HISTORY_COMPLETE` at 15:45:01 PDT, persisting 994 decoded
  rows (431 skin-temperature rows); the immediate follow-up completed with 6 more.
- Independently decompressed the enrolled strap's new `.imus` file: 90 consecutive
  seconds, 100 samples/second × 6 axes, with receipt ages 2496–3513 ms. An initial
  three-second window used the app's pre-resolution `my-whoop` identity; it remains
  separately labeled and is excluded from the enrolled-strap count.
- The post-install database passed `PRAGMA quick_check`. All 384,486 pre-install
  HR rows remained intact; the post-install snapshot contained 385,685 HR rows.
- Signed iPhone build succeeded; 28 selected recorder, chunk durability, and IMU
  repair tests passed. `git diff --check` passed.

Local verification snapshots and build/test logs are under
`/tmp/noop-optical-implementation/`; these contain personal recordings and are not
part of the repository change.

## Front-page live diagnostic — build 350

Both Today layouts pin a Live Bluetooth card above their main content. Its state
comes directly from standard HR/R–R/contact and battery notifications, and from
CRC-valid realtime carriers (40/43/51). History, metadata, console output, and
command replies never enter its counters, regardless of the app's offload flag.
Unknown live raw layouts remain explicitly undecoded, including candidate type 51;
only the evidenced, fresh 100 × 6 layout is labeled live IMU.

The card refreshes once per second in an isolated view. It shows each stream's
latest value or shape, packets per second over the last ten seconds, connection
packet count, and freshness. Five seconds without a packet removes the Live
indicator; reconnect/disconnect clears previous connection data. R–R freshness
advances only when an R–R interval actually arrives, not when HR alone updates.
Optical history cannot light up a live optical indicator. This diagnostic does
not start additional sensors or alter collection or persistence.

Build 350 installed and launched on the paired iPhone. At 15:54:16 PDT its log
confirmed fresh standard HR (72 bpm) and verified live 100 Hz IMU; history started
separately at 15:54:19. All six diagnostic tests and the signed iPhone build passed.

## Developer toggle and transport rates — build 351

Settings → Advanced → Test Centre → Developer Options contains **Show live
Bluetooth diagnostic**. Visibility remains on unless explicitly disabled; the
choice persists across launches and applies to both Today layouts. Hiding the
panel does not stop Bluetooth collection.

The card's footer separates backfill from live sensor rows. It shows backfill
status, completed chunks per second, connection chunk count, last chunk age, and
combined incoming throughput in decimal kB/s and kbps (eight bits per byte).
Rates are ten-second averages, using one-second buckets. Chunk completions are
counted at the durable cursor/trim-ack boundary, including empty/control chunks;
individual history packets and failed writes do not count as completed chunks.

Throughput counts each incoming characteristic value once before frame reassembly
or storage. It therefore includes live data, backfill, control replies and device
reads, without double-counting reassembled frames. It measures app-visible payload
bytes, not ATT/link-layer overhead or the physical Bluetooth bitrate. Counters reset
with the connection, and idle rates age down to zero even without another packet.

The signed build and 14 targeted diagnostic/backfill-durability tests passed.
Build 351 was installed and launched on the paired iPhone.

## Live IMU 3D viewer — build 352

The Live IMU row has a **3D view** button. Its sheet shows a rotating sensor model,
RGB sensor axes, cyan acceleration and orange angular-velocity arrows, and numeric
roll/pitch/yaw, all six measured channels, and estimated gravity-removed acceleration.
Drag to orbit, pinch to zoom, toggle either vector, or use **Zero rotation** to set
the displayed orientation reference. The diagram remains fixed in position: it
does not integrate acceleration into a trajectory or claim anatomical wrist angles.

Only the existing CRC-checked, fresh live IMU path feeds the viewer. Historical,
corrupt, and stale packets cannot move it. Duplicate/reordered strap seconds are
ignored; a missing second begins a new orientation segment instead of integrating
across unknown motion. Disconnect clears both sample cache and reference.

While the sheet is open, quaternion integration processes every sample at 100 Hz.
The gyro is in degrees/second; accelerometer units are g, including gravity. A
gentle gravity correction (two-second time constant, only near a 1 g magnitude)
limits tilt drift. There is no magnetometer/absolute yaw reference or gyro-bias
calibration, so rotation and linear acceleration are explicitly estimates.

The most recent one-second packet plays at sample cadence in a 30 fps view. Packet
buffering adds latency, which is exposed as sample age. Silence holds the last
real sample, and after five seconds the UI stops labeling it live. Only the latest
packet is retained for display; closing the sheet stops attitude integration and
leaves normal collection unchanged.

Verification: 17 targeted IMU-estimator/diagnostic tests passed, including a native
SceneKit rendering with synthetic motion that was visually inspected. The signed
iPhone build succeeded; build 352 was installed and launched on the paired phone.
