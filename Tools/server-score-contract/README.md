# Mobile decoder contract

`bash Tools/server-score-contract/run-mobile-decoders.sh FIXTURE_DIRECTORY` consumes response files captured from the real isolated SQL and Edge handler path. It does not create or replace RPC responses. Swift imports the production `WhoopStore` decoder; Kotlin compiles the exact production Android codec, models and display selection sources without Android networking stubs.

`expectations.json` is a nonempty array with this shape:

```json
[{"file":"approved-v2.json","ownerId":"synthetic-owner-uuid","day":"2026-09-16","expectedDeviceId":"synthetic-device-uuid","availableFeatures":["sleep"],"unavailableFeatures":["hrv","respiration"],"nestedHrvAvailable":false,"nestedRespirationAvailable":false}]
```

The final-mode checks cover all 27 canonical families through production value selection after cache and ownership persistence. Swift reloads the real `ServerMetricOwnershipStore` from an isolated UserDefaults suite. The plain JVM runner persists and reloads the exact Android production `ServerMetricOwnership.encode`/`restore` ledger codec through files; the Android application suite separately exercises its SharedPreferences adapter. Both runners check immutable result metadata, cross-project/account/source/device/day fencing, older revisions, same-identity numerical mutation rejection, revocation, and explicit missingness. Pending registration is persisted without inventing a canonical device or result revision.

Optional `expectedValues` maps `sleep`, `hrv` or `respiration` to the expected canonical scalar, including valid zero. `expectedCanonicalValues` uses registry metric IDs and checks contract units directly. Unauthorized nested physiology is checked in both the original legacy envelope and canonical sleep details/session values. Legacy feature assertions remain provenance-compatibility checks, not final-mode selection proof. A successful run proves decoder/persisted-selection behavior, not physical screen rendering or production deployment.

After building the runners, `node Tools/server-score-contract/test-canonical-runners.mjs FIXTURE_DIRECTORY SWIFT_BINARY KOTLIN_BINARY` verifies that null/changed canonical values, removal of the canonical contract, and a nested sleep authorization leak fail even when the legacy response remains populated. These deliberately mutated copies are negative tests, never accepted server results.

Prerequisites are Swift with macOS 13 or later, JDK 17 and the existing scoring Gradle wrapper. Set `JAVA_HOME` to the JDK 17 installation if needed. Unit tests deliberately use synthetic malformed payloads; these are separate from real SQL/Edge acceptance envelopes.
