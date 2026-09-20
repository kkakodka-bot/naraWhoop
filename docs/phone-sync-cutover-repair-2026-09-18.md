# Phone sync repair after server-scoring cutover

## Cause and scope

The connected iPhone 16 was running NARA 11.1.1 (331). GitHub PRs 14 and 15
were still open; the server-scoring branch at `5caa316` did not include their
history pipeline and installed-schema repairs. The phone had already applied
the research/PR15 PPG migrations, including `recordIndex` in its primary key.
Build 331 still wrote `ON CONFLICT(deviceId, ts)`, which SQLite rejected because
that was no longer a unique key. The phone log repeatedly held trim 128163 after
this error. Live standard-HR collection continued; history offload was blocked.

The old writer failure was reproduced against a private database copy. The
phone's database and preferences were preserved before installing the repair.
The definitive pre-install snapshot was copied while the app was launched
stopped; its `PRAGMA quick_check` returned `ok`. An earlier copy raced automatic
CoreBluetooth relaunch and is not the integrity baseline.

The dedicated branch `fix/phone-sync-after-server-cutover` starts at `5caa316`.
It restores the relevant PR14/15 Swift changes using a three-way application,
preserving the newer WHOOP 5 R-R corrections and the server-scoring path:

- PPG record identity survives writes, reads, same-second records, and replay.
- Migration `v48-ppg-record-identity` follows the cutover's existing v46/v47
  migrations. Already widened PR15/research schemas are adopted without
  rebuilding their table; legacy rowids and data are preserved.
- FIFO history and control delivery, session fencing, commit/ACK watchdogs,
  background reconnect, and actual inserted-row progress accounting are restored.
- Timestamp-range skipping defaults off, so out-of-order history cannot be
  silently skipped. SQLite handles replay deduplication.
- Local rescore admission and settlement safeguards remain available when local
  scoring is selected; the server-scoring bypass remains in place.

There are no server, deployment, Android runtime, or server-database changes.
The shared Android schema test fixture and its interpretation were updated to
reflect the restored iOS schema. The original worktree and the separate server
database branch were left untouched.

## Off-wrist investigation

The user confirmed that green LEDs remained on after 30 seconds off-body with
the optical face unobstructed. At that time the old app was receiving invalid
HR notifications and rejecting those samples. The saved standard-HR contact
events reported `unsupported`; the sampled live log contained no fresh
`WRIST_OFF` event. These observations do not establish why the firmware leaves
its LEDs running.

An independent app-side defect was found: live-stream demand did not include
wear status, and wrist events only drove shortcuts. The repair now gates
realtime demand by the firmware's reported wrist state and reconciles on those
events. User intent survives wrist-off, allowing wrist-on to resume a requested
stream. Repeated off-body requests do not re-arm it, and failed stop submission
does not falsely mark it stopped. During history offload, reconciliation defers
until the normal keep-alive can run, preserving the history transfer.

This releases the app's telemetry request. It is not a validated optical-power
command. No persistent wear-detection flags or speculative sensor commands were
changed. Physical LED shutdown remains to be verified.

## Verification

Source commit: `397a190` (documentation added separately).
Installed replacement: NARA 11.1.1 (343), built and signed for the connected
iPhone, bundle `com.rahulvijayan.nara.noop`.

- Protocol: 60 selected tests, 59 passed and one optional capture test skipped.
- Storage: 50 selected tests passed, including mixed-history persistence and
  idempotent replay against a fresh disposable copy of the frozen phone backup.
- App: 153 selected tests passed, covering the history pipeline, session
  lifecycle, commit/ACK ordering, reconnect, rescore handoff, server-scoring
  bypass, and the three new realtime-wear regressions.
- Signed iOS build succeeded and build 343 installed and launched.
- The frozen post-install snapshot at 11:28 local time returned
  `PRAGMA quick_check = ok`. Compared with the frozen pre-install snapshot:

| Stream | Additional durable rows |
| --- | ---: |
| Heart rate | 4,207 |
| R-R intervals | 23,703 |
| PPG waveforms | 909 |
| Skin temperature | 27,407 |
| Gravity | 27,407 |
| Total sensor rows above | 83,633 |

The saved trim cursor advanced from 128159 to 130081. The history-only skin
temperature/gravity frontier advanced from 1789629612 to 1789657019 (over seven
hours of previously blocked history). Live HR alone therefore cannot explain
the progress. The new PPG records demonstrate that the original failing writer
path actually succeeded on the phone.

After the snapshot/restart, CoreBluetooth restored the peripheral, a new
history session started at 11:28:51, and the first acknowledged trim was 130081,
followed by advancing trims. This confirms bounded observed-session restart
recovery, not an overnight background guarantee.

At this handoff, the old backlog is still draining. `lastSyncedAt` has not yet
advanced to a terminal completed burst, and durable downstream jobs were still
owed in the mid-transfer snapshot. Full catch-up, terminal debt settlement,
and physical off-body LED shutdown are **not yet verified**. The app is left
running on build 343 to continue its normal sync.

Private evidence is outside the checkout at
`/Volumes/Untitled/WHOOP NARA-phone-sync-evidence/2026-09-18/`.
It contains the frozen pre-install DB/WAL/SHM, preferences, test/build logs, and
post-install log snapshots. No private health database is checked into git.

Long locked-screen/range-loss reliability and remote score publication are
separate acceptance checks and are not established by this run.
