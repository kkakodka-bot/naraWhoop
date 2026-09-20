# WHOOP identity switch and stalled sync

The reported 95% battery and stale sync occurred after NARA attached to a different physical
WHOOP and replaced the saved identity. The user's selected MG had a stored battery reading of
22.8%. The other connection identified itself as a WHOOP 5.0 and refused the encrypted handshake.

## Evidence

USB evidence was captured before restarting or updating the app, in the private local directory
`/Volumes/Untitled/WHOOP NARA-stale-sync-evidence/2026-09-19-1719/`.
The database copy passed `PRAGMA quick_check`. Original database, WAL, preferences, rolling logs,
installed-app metadata and file hashes were retained. No phone database was replaced.

September 19, 2026, Pacific time:

- 16:24:01: last completed MG sync; live HR/RR persisted until 16:28:20.
- 16:46:57: another WHOOP connected. The coordinator initially logged the identity mismatch and
  preserved the saved MG binding. The other strap refused encryption.
- 17:04:20: restoration replay reached the coordinator after `encryptedBond` had been set to true.
  The coordinator logged a supposed successful replacement and overwrote the MG binding, even
  though authentication failed immediately afterward.
- 17:10:19: Device Information identified the selected connection as serial prefix `5B0`, hardware
  `WG50_r52`, firmware `50.35.2.0`. The previous MG reported prefix `MGB`, hardware `WS50_r00`,
  firmware `50.41.1.0`.
- At capture, the sole `pairedDevice` row pointed at the other peripheral. Only the MG had a
  per-peripheral successful-sync stamp. The most recent stored battery row was 22.8%.

The user confirmed the MG is the intended device. The reported 95% screen value is consistent with
the unencrypted standard battery read from the other strap, but the original battery response byte
was not retained; that attribution is an inference, not a captured byte-level observation.

The installed app was build 355. The retained build-355 product points to the
`WHOOP NARA-pr21-production` workspace. The repair is based on commit
`fa7fe6b1f0161011a9481cb52630ec5586b52cb0`; the original binary did not embed a source SHA, so this is
not an assertion of exact installed-source attestation.

## Cause and change

Startup launched store bootstrap asynchronously and immediately began Bluetooth selection. The
saved peripheral filter could therefore arrive after a nearby strap had already won the scan.
Restoration then chose the first peripheral and assumed it was encrypted. A late subscriber to
the UUID publisher observed the replayed UUID with that Boolean already true. The coordinator
treated this as authorization to overwrite a different saved physical identity.

### Why another strap was selected, and why the mistake persisted

The original source represented both "saved identity has not loaded yet" and "no selected strap"
with `preferredPeripheralUUID == nil`. `isPreferredPeripheral` accepted any WHOOP in that state,
and the discovery handler connected to the first supported advertisement. `poweredOn` started
store bootstrap in a separate task and immediately entered that connection path. Meanwhile,
`AppModel` wired `SourceCoordinator` only after awaiting the repository refresh and a downstream
sync drain. Saved-device selection therefore depended on unrelated startup work completing first.

This particular incident used the scan path: the retained log shows a new launch scanning at
16:46:52, accepting an advertisement at 16:46:53, and reporting the existing-MG/different-connected-
device mismatch at 16:46:57. The MG binding was still present at that point. Loading the preferred
UUID afterward did not cancel an already-started connection; the old setter only changed a field.

The later 17:04:20 restoration made the temporary wrong connection persistent. It picked the first
restored peripheral and set `encryptedBond = true` without a successful new handshake. When the
coordinator subscribed, the current-value publisher replayed that peripheral's UUID. The
coordinator's older automatic stale-pairing recovery rule treated the Boolean as permission to
replace the saved strap. Its message claiming that the old strap "refused to bond" was fixed text
in that branch, not independent evidence that the MG had refused. The actual next write failed
authentication on the other strap.

The behavior was timing-dependent: another supported strap had to become eligible before the
saved selection reached the transport. It did not require the user to select a replacement.
Neither Bluetooth discovery order nor a restored connection is evidence of which device the user
intends to wear. The regression test reproduces the late-subscription overwrite on the original
source and verifies that the same replay cannot change a saved binding after the fix.

The earlier interruption is a separate evidence boundary. The MG's retained live log ends at
16:28:22, with the last completed store flush at 16:28:20; there is no retained MG disconnect reason
before the new 16:46:52 app session. The phone's available crash inventory has no matching NARA
report for that gap. The nearby 16:50:08 Jetsam report lists NARA as active/frontmost without a
kill reason and identifies other processes as victims. It does not establish why the earlier
session ended. A crash, system eviction, radio loss, manual close or app replacement must not be
claimed as the initiating event without further evidence. The wrong-device selection and later
binding overwrite are independently established by the retained logs and reproduced code path.

The repair:

- waits for saved identity and complete store bootstrap before normal connection startup;
- reads the active device binding at connection admission, and selects restoration by UUID;
- requires a new handshake after restoration instead of inferring encryption from restored state;
- never replaces an existing binding based on connection/bond callbacks;
- immediately pins transport after first identity adoption;
- rejects discovery, service, notification, battery, write and connection callbacks from other
  peripherals, including unrelated cancellation callbacks;
- preserves explicit disconnect while asynchronous startup completes and retries unavailable
  bootstrap on foreground entry.

Apple documents that preservation includes peripherals the central was **trying to connect to**,
as well as connected peripherals. Restoration alone is consequently insufficient evidence of the
application handshake. See [Core Bluetooth state preservation and restoration](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).

For this already-corrupted legacy binding, a Debug-only USB launch request can change only the
saved peripheral ID. It requires an explicit expected old UUID, selected new UUID, a unique legacy
WHOOP row, existing successful-sync evidence for the selected device and no successful-sync stamp
for the old binding. The SQL update compares the expected old value. It does not reset the strap,
replace the database, relabel samples or run on ordinary launches or Release builds.

## Validation

The late-subscription overwrite, bonded-callback overwrite and missing first-pair transport pin
were reproduced against the original source. The repaired source passed 75 targeted hosted tests,
including 13 identity/explicit-repair tests, reconnect policy, battery lifecycle, onboarding,
last-sync attribution and backfill lifecycle/persistence checks. Test hosts disabled physical BLE.

Private artifacts: `baseline-regression.log`, `final-357-regression.log`,
`candidate-source-manifest.json` and `incident-manifest.json`. The first test iteration also had a
fixture that omitted initial battery-device selection; that fixture was corrected before the final
run. No result from that fixture is claimed as a product defect.

## Phone recovery

Signed Debug build 357 was installed over build 355's app container on the USB iPhone 16. No uninstall,
database replacement or strap reset was performed. The user explicitly selected the MG. The first
diagnostic repair attempt in build 356 failed without changing the binding; its original error detail
was not retained. Build 357 adds error detail to that diagnostic and the next attempt succeeded.
While still selected in build 356, the other strap returned a fresh 100% battery response, separately
confirming that its battery differed from the MG's.

- 17:43:50: the conditional binding update succeeded; restoration rejected the unrelated strap and
  targeted the saved MG.
- 17:43:52: the MG acknowledged `CLIENT_HELLO`; the new battery response was **21%**.
- 17:43:53: Device Information confirmed serial prefix `MGB`, hardware `WS50_r00`, model `MG`.
- 17:44:50–51: catch-up logged 31,463 persisted records in two productive sessions, followed by the
  caught-up sentinel. Each session reached `HISTORY_COMPLETE` with no pending writes and no commit
  in flight. `lastSyncedAt` advanced from 16:24:01 to 17:44:51.
- A subsequent ordinary launch, without repair environment variables or diagnostic launch defaults,
  restored the MG at 17:49:13, obtained a fresh encrypted handshake, and completed another 1,572-record
  catch-up at 17:49:20. Device Control reported that it could not determine the launched PID, but a
  separate process query and the app's new logs verified that the launch succeeded.

The post-catch-up SQLite/WAL copy passed `PRAGMA quick_check` and retained the selected MG binding.
Both trim cursors reached `4294967295`. The following durable counts are from that copy, before the
ordinary relaunch; live collection continued during capture:

| Table | Before | After |
| --- | ---: | ---: |
| hrSample | 327,408 | 332,229 |
| rrInterval | 391,274 | 394,889 |
| skinTempSample | 327,350 | 332,016 |
| gravitySample | 327,350 | 332,016 |
| battery | 139 | 142 |

A row comparison against the original copy found no missing or changed original samples in those
five tables, excluding only the upload bookkeeping column `synced`. Recovered battery history ends
at 21.9%; the separate fresh standard battery response was 21%.

Private artifacts include `install-357.json`, `recovery-357-complete-strap.log`,
`normal-launch-strap.log`, `processes-after-relaunch.json`, `post-catchup/`, and
`post-catchup-analysis/`. A failed USB copy was retained separately and was not used for validation.

## Remaining boundaries

Strap-to-phone catch-up is verified. This is not acceptance of the complete downstream pipeline:
the first recovered database snapshot still owed rescore, cloud push, Health writeback and widget
work. Later logs showed rescore deferral because the last pass exceeded the background time policy.
The preferences also retain a cloud receiver `409 replacement_superseded` error for `dailyMetric`;
the identical error was captured before any changes or install in this incident. These stages were
not changed or declared healthy by this repair.

The general correction prevents connection/restoration callbacks from silently switching a saved
physical device. Already-corrupted bindings require explicit device selection; they are not guessed
from nearby straps. Overnight, out-of-range recovery, multi-phone ownership, Release validation and
fleet-wide acceptance remain unmeasured.
