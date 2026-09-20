# WHOOP MG sensors remaining on off-body

Target: the user's WHOOP MG on firmware `50.41.1.0`, connected to NARA
11.1.1 build 343. Investigation date: 2026-09-18.

## Current result

The user confirmed that a normal strap restart restored the off-body
lights-off state for at least 60 seconds. A subsequent wear/removal cycle
also passed: the green lights turned off automatically with NARA connected.
The sync repair in build 343 remains installed. No VPS, server
database, firmware image, or persistent strap setting was changed in this
investigation.

The user confirmed that the underside green sensors remain illuminated after
30 seconds off-body, facing up and unobstructed. They then remained illuminated
with iPhone Bluetooth disabled for 60 seconds. The user reports no other phone,
Mac, or official WHOOP app connected to this strap.

The Bluetooth-off observation excludes an actively connected NARA client as a
necessary condition for the lights staying on during that minute. It does not
exclude a persistent setting or a firmware state previously initiated by a
client, and does not by itself identify a hardware fault.

## Phone evidence

The saved phone log contains:

```
[11:40:23] Wear: off wrist; reconciling realtime request
```

This is an app wear-state transition, not an optical-power measurement. It
shows that a wrist-off event can reach NARA. During history transfer the event
dispatcher accepts wrist events only within 45 seconds of the current strap
clock. Historical console messages adjacent to the event are not treated as
current physical observations.

Build 343 gates NARA's requested realtime HR stream on wear state. This changes
telemetry requests; it is not a demonstrated control for physical LED power.
Standard HR sensor-contact bits previously reported contact detection as
unsupported, so they cannot provide an independent wear-state verdict here.

Phone preferences and complete available log generations were copied to:

```
/Volumes/Untitled/WHOOP NARA-offbody-evidence/2026-09-18/
```

## Source and prior-artifact review

- Normal connect/sync paths do not invoke the R22 persistent-flag enable
  sequence. Its call sites are explicit Settings/Test Centre actions.
- The device-config write gate excludes `sigproc_wear_detect` and
  `cont_collection_mode` from permitted writes.
- A September 15 read-only report from this same target recorded
  `sigproc_wear_detect='0'`, `cont_collection_mode='0'`,
  `wear_detect_bias='2'`, and `hr_ch_switching='1'`. These are older raw values,
  not a current readback or a validated interpretation of enabled/disabled.
- The September 16 producer experiment's retained terminal report and wire
  analysis support completion of its exact stop command. It recorded no AFE
  setting write. This does not prove the current sensor state or exclude all
  earlier client effects.
- NARA's existing normal Restart action sends opcode 29 with an empty body.
  Previously retained repository evidence confirmed this form on WHOOP 5.0
  firmware 50.40.1.0. This investigation adds an observed normal restart on
  the user's MG firmware 50.41.1.0, with physical lights-off confirmation.

## Recovery check

The user was asked to use Devices → WHOOP menu → Restart strap, keep the strap
off-body, and report whether the LEDs stay off for 60 seconds after reconnect.
NARA records command acceptance, disconnect, and reconnect independently of
the physical LED observation. This is a normal restart preserving recorded
history, not a factory reset.

The user confirmed that the green lights turned off and stayed off for at
least 60 seconds after restart. The phone log independently records:

```
[11:51:58] reboot: request family=whoop5 fw=50.41.1.0 connected=true bonded=true
[11:51:58] reboot: sent opcode=29 ... payload=empty writeType=withResponse
reboot: strap acked result=0x01 (accepted)
[11:52:07] reboot: link dropped 9221ms after send ...
[11:52:09] reboot: reconnected 10.6s after send ...
[11:52:10] Wear: off wrist; reconciling realtime request
```

The reconnect alone is not optical evidence; the user's physical observation
supplies that part. This supports a recoverable firmware/runtime state as the
immediate failure, without establishing the initiating cause or excluding an
intermittent hardware fault. No current persistent-configuration readback was
performed, and no configuration change was needed for this recovery.

For the follow-up, the user was asked to wear the device for 60 seconds and
remove it for another 60 seconds with NARA connected. The user confirmed:
“Yes, they turn off automatically.” The log independently records wrist-on at
11:53:12 and wrist-off at 11:53:56, followed by wrist-on at 11:54:16. The
user's visual observation establishes shutdown, while the event times do not
independently establish exact 60-second intervals for this second cycle. This
establishes recovery of automatic removal behavior in the observed test;
long-term recurrence has not been evaluated.

The restored app also completed history sessions at 11:48:29 and resumed
successful history transfer after the restart, reaching `HISTORY_COMPLETE` at
11:52:59. These are phone/strap transfer observations, not server database or
remote scoring acceptance. The phone's persisted `lastSyncedAt` was
`1789757579.300609` (11:52:59 PDT) and `sync.lastWriteOkAt` was
`1789757578.497247` in the post-restart snapshot.

The external evidence directory contains the preference snapshots, extracted
logs, the physical-observation record in `result.json`, and `sha256.json`.

WHOOP's [5.0/MG firmware guidance](https://support.whoop.com/s/article/WHOOP-5-0-MG-Firmware-Release-Notes)
recommends a normal reboot for issues after an update. Its
[LED troubleshooting article](https://support.whoop.com/s/article/WHOOP-Troubleshooting-101)
also recommends rebooting for stuck sensor LEDs, but that article's LED-specific
section is explicitly about WHOOP 4.0 and is not MG verification.

## VPS assessment

Additional wear classification on a VPS would not establish an actuator for
physical sensor shutdown, and would require the phone and network to deliver
observations and commands. The observed wrist-off event and Bluetooth-off
result make firmware state and sensor control the next questions to resolve.
There is no present evidence that insufficient server compute causes this
failure. No server algorithm or deployment is warranted by these observations.
