# Scripted production BLE transport tests

Run from the repository root:

```sh
zsh Tests/BLETransportNative/run.sh /tmp/nara-ble-transport-evidence
```

The runner compiles the production `BLEConnectionOwner`, `BLETransportDriver`, and
`CoreBluetoothTransport` adapters with native XCTest. Scripted implementations replace
only the central/peripheral radio boundary. Tests execute the production driver's
connection, discovery, notification, read, and write effects and callback admission.
They do not construct private Core Bluetooth objects or require a paired strap.

The suite checks synchronous pending connections after failures, OS automatic
reconnect without a competing request, teardown/account fences, radio transitions,
exact restored selection, restoration failure fallback, combined service scanning,
object and captured-generation rejection, bounded discovery/notification recovery,
ordered callback payloads, and the owner's readiness boundary on history writes.
An error-specific standing request made by the synchronous manager sink takes
precedence over the driver's fallback and does not produce a second native request.
The production `BLENotificationController` also runs through the scripted production
driver: a cached active subscription emits OFF, waits for its callback, emits ON, and
authorizes a history write only after the positive ON callback. Repeated requests,
out-of-order ON, duplicate OFF, rejected effects, errors, and generation changes are
covered separately. The helper does not infer a WHOOP firmware notification profile.

## Manager integration contract

Keep the existing `BLEConnectionOwner`; the driver is its effect adapter, not another
connection policy. Create one `CoreBluetoothCentralTransport(central)` and one
`BLETransportDriver(central: adapter, owner: connectionOwner)` for that central.

- `admitRequest`: retain account shutdown, intentional disconnect, registered device,
  onboarding approval, and current bond-pause admission from the managed entry point.
- `willSubmit`: set the manager's exact held native peripheral and install its
  generation-capturing peripheral delegate before `CBCentralManager.connect`.
- `managedConnect`: invoke `driver.request(adapter.wrap(p), startDelay: delay)`.
  Native `connect` lives only in `CoreBluetoothCentralTransport`.
- Native connect callback: invoke `driver.connected(adapter.wrap(p))`. Its synchronous
  `.connected` sink runs the existing manager setup after the owner transition. Remove
  the second `owner.connected` call from that setup; reinstall the delegate with the
  supplied token when OS automatic reconnect created a generation.
- Native disconnect callback: pass native error, timestamp (modern callback), and
  `isReconnecting` into `driver.disconnected`. Its sink runs the existing teardown
  without another `owner.disconnected`. Teardown finishes before automatic fallback.
- Native connection failure: call `driver.failedToConnect(..., error: error)`. Its
  separate sink preserves the existing failure/bond diagnosis. The driver already
  checked the pending phase, so the post-transition sink must not check it again.
- Existing manager teardown may submit a policy-specific standing connection (for
  example a 30-second stale-pairing floor) synchronously. The fallback is then rejected
  by the same owner's pending-request guard. `admitRequest` must also respect any
  pause that teardown chose without submitting a connection.
- After minimum registry/approval lookup, `restore` selects only the registered
  candidate, cancels others, attaches the generation before the `.restored` sink, or
  submits a pending connection. The manager sink resets its discovery/session fields
  and begins discovery without calling `owner.attachRestored` again. A failed lookup
  passes nil registration or false approval; heavy account bootstrap stays outside
  this synchronous path.
- Send service/characteristic discovery, notification, read, and write effects through
  the driver with the retained current token. Set `requiresHistoryReady: true` for
  history commands. The manager still owns family-specific notification requirements
  and calls `owner.ready()` only after confirming them.
- Append ATT queue metadata using `write`'s `beforeSubmission` closure, which runs
  after the final token/GATT/readiness admission and immediately before the native
  write. The closure is synchronous bookkeeping only. Honor the returned Bool before
  marking an ACK submitted or a command accepted.
- The retained peripheral proxy passes its captured token into `discoveredServices`,
  `discoveredCharacteristics`, `notificationChanged`, `valueChanged`, and
  `writeCompleted`. Their synchronous event sink invokes the corresponding manager
  handlers. Preserve the callback's error, current notifying flag, and byte snapshot.
- Use `BLENotificationController` for each subscription request and notification
  callback; derive confirmations from its `confirmed` set. Its `needsRecovery` result
  feeds the existing owner's bounded GATT recovery, whose retry must call the same
  helper request path. Clear it when resetting the connection. While waiting for a
  cached subscription's OFF callback, an ON cannot authorize readiness. A duplicate
  OFF during pending ON also leaves the request pending without a second enable.
- Begin `BLEConnectionSetupLease` before normal/restored connected discovery. Its
  20-second deadline and finite UIKit assertion end at required readiness or teardown.
  Assertion expiration, background denial, and missing setup callbacks fence the
  generation before releasing the assertion. Denial while foreground permits setup
  until the deadline, but entering background without an assertion ends that attempt.
  macOS retains the deadline without claiming a UIKit assertion.
- `expireSetup` cancels the old local connection and immediately submits one OS-owned
  request with a 30-second start delay. Exhausted GATT retries and restored disconnecting
  links use the same effect. The eventual old cancellation callback cannot consume that
  request. Apple defines the local link as effectively disconnected after cancellation;
  actual radio scheduling and delivery order still require physical acceptance.
  The known WHOOP 5 suppressed-hello fallback explicitly ends setup with its existing
  limited-session hint, without authorizing history.

`CoreBluetoothCentralTransport.wrap` caches exact native-object wrappers; callers must
use it rather than constructing a second wrapper. The driver verifies object identity
before changing the owner. Service/characteristic effects and events also require
membership in the current peripheral's GATT objects.

## Evidence limits

Core Bluetooth central callbacks carry no connection generation. The optional
`originatingToken` is for an event source that actually retained one; production must
not label a native callback with the current token and claim provenance. Native object
identity, callback phase, link state, and strictly increasing modern disconnect
timestamps reject distinguishable stale/duplicate events. A native callback delivered
on the same reused object without distinguishing metadata remains an OS boundary.
Peripheral delegates retain the generation, but a callback already relabeled by the
OS to a replacement delegate cannot manufacture its prior provenance.
Notification callbacks likewise have no operation identifier. A nil-error OFF while
waiting for ON cannot distinguish a duplicate OFF from an unreported enable failure;
the helper waits for positive confirmation, an explicit error, or the manager's
deadline/generation fence, and never treats that uncertainty as ready.

These are deterministic transport tests, not full `BLEManager` app execution or
physical scheduling evidence. Required notification profiles, locked operation,
genuine restoration, timing, energy, and firmware behavior require the separate app
and physical acceptance suites. No physical measurements are claimed here.
The finite setup deadline is not a guarantee that iOS schedules the app within 20
wall-clock seconds. The assertion may expire earlier, and no repeating app timer owns
reconnection. See Apple's [cancellation contract](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection(_:))
and [finite background execution guidance](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).
