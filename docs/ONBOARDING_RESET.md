# WHOOP first-run pairing and storage reset

This change applies to the shared iPhone/macOS onboarding wizard. Android onboarding is unchanged.

## User flow

1. Charge the WHOOP, double-tap its top, and check for a green side light.
2. Scan without connecting automatically. Select the advertised name whose serial matches the sensor.
   Generic model names without a plausible serial cannot be selected.
3. Confirm the serial match. Take the sensor off the wrist, wait for its underside lights to turn off,
   and tap the top firmly and continuously until the side light flashes blue. The text explicitly says
   that it can take many taps.
4. Select **Connect and reset this WHOOP**. This screen discloses that all strap history will be erased.
5. Tap **Pair** in the system prompt. Existing OS pairings can reconnect without another prompt;
   CoreBluetooth does not expose a separate "user tapped Pair" event. NARA requires its confirmed
   encrypted handshake, never the legacy `bonded` flag that can also mean unencrypted live HR.
6. **Connecting and resetting** stays visible through the clear and empty-history verification.
   Only verified completion unlocks profile setup and normal collection.

The charge/tapping guidance follows [WHOOP setup guidance](https://support.whoop.com/s/article/Setting-Up-Your-WHOOP-4-0?language=en_US)
and the user's requested sequence. The advertised serial comparison is a user confirmation, not an
independent hardware identity attestation. Unnamed/renamed straps without a serial-bearing name
cannot pass this onboarding flow.

## Isolation and recovery

- Before initial discovery, the BLE manager blocks automatic connections and inbound health-data
  routing. Selection pins the peripheral UUID across normal connection, reconnection, and restore.
- Reset is the documented `FORCE_TRIM(25)` whole-history sentinel: eight `FE` bytes. This is a
  storage reset, not a reboot or a reset of unrelated settings. The opcode remains excluded from
  the generic command enum/menu; a private writer admits only the correct payload in the reset phase.
- All history notification channels must be subscribed before reset or verification. The setup
  writer owns the command lane while resetting/verifying, and ordinary history triggers are blocked.
- Incoming bytes are intercepted before raw journals, collectors, live decoding, and backfill.
  Verification never stores or uploads readings. It accepts only a checksum-valid history START
  followed by COMPLETE without historical records/events. Empty metadata chunks may be acknowledged.
- A strict, characteristic-scoped verifier rejects corrupted packets, discarded-byte equivalents,
  incomplete fragments, unexpected metadata, and data after COMPLETE in the same notification.
- A successful ATT write is insufficient. Silence, a rejected write, remaining records, or a lost
  link keeps onboarding closed. Pairing has a 90-second deadline; reset and verification have
  separate 45-second deadlines. Retry is explicit.
- A checkpoint is atomically written before the erase command. After a disconnect/relaunch, Retry
  verifies first; **Clear storage and retry** explicitly authorizes a new erase. Verified completion
  survives a crash later in the wizard. Finishing onboarding retires that receipt, so a future
  onboarding session cannot reuse a previous owner's completed receipt.
- Existing onboarded installations do not erase history on upgrade, launch, or ordinary reconnect.
  Previously imported local/server history is not deleted by this change.

## Design

Reading: first-run hardware setup for a WHOOP owner, using NARA's existing calm visual language.
Energy 1 / rhythm 1 / motion 1 for the changed setup screens. Existing palette, type, and button
components preserve app consistency. A short vertical sequence keeps physical instructions beside
their confirmation controls. The serial-bearing device name is the selection focal point; the
progress indicator is the reset focal point. Scrollable content accommodates small screens and
larger text. The battery icon refers directly to the charge check. No new decorative animation.

## Acceptance boundary

Automated tests cover protocol corruption/nonempty-history refusal and the persistent setup gate.
Build/test evidence is recorded with the implementation handoff. Firmware acceptance of FORCE_TRIM,
an actual iPhone Pair prompt, cancel/retry behavior on hardware, and retained flash contents after a
power cycle require a sacrificial strap with known test history. These remain **NOT_READY** until
tested on the target firmware. No physical device is erased as part of local verification.

Empty-session verification is intentionally conservative: newly banked records/events during setup
also cause refusal. Keep the WHOOP off-wrist. Unit tests cannot prove physical flash sanitization.

## Local verification (2026-09-18)

- **PASS:** iPhone Simulator app build, both arm64 and x86_64, with signing disabled.
  Local log: `.build-artifacts/ios-build-final.log`.
- **PASS:** macOS app build and 22 focused app tests: `WhoopOnboardingSetupTests`,
  `ClientHelloOutcomeTests`, and `OnboardingUnitsPickerTests`. The tests exercise both the
  wrong-device/unencrypted refusal and the persistent recovery/finished-receipt boundaries.
  Local log: `.build-artifacts/app-tests-final.log`.
- **PASS:** full `WhoopProtocol` suite, 739 tests executed, one existing skip, zero failures.
  Includes nine new empty-history/fragmentation/corruption tests on both WHOOP frame families.
  Local log: `.build-artifacts/protocol-tests-final.log`.
- **PASS:** staged diff whitespace check.
- **NOT_READY:** interactive visual walkthrough. CoreSimulator device creation returned
  `Device was allocated but was stuck in creation state` for default and external device sets.
  The desktop Computer Use tool returned `Computer Use requires nodeRepl.createElicitation`.
  Layout has been compiled but not visually approved; no screenshot or click-through is claimed.
- **NOT_READY:** physical pairing, flash reset, and power-cycle retention verification.

The original `WHOOP NARA-pr16` checkout remains at `5caa31689da0023e111beb36850d3f81d67e1be2`.
Implementation and local validation were isolated in `WHOOP NARA-onboarding-reset`, on
`fix/onboarding-pairing-reset`. Build artifacts are local and are not included in the commit.
