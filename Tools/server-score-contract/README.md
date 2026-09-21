# Mobile decoder contract

`bash Tools/server-score-contract/run-mobile-decoders.sh FIXTURE_DIRECTORY` consumes response files captured from the real isolated SQL and Edge handler path. It does not create or replace RPC responses. Swift imports the production `WhoopStore` decoder; Kotlin compiles the exact production Android codec, models and display selection sources without Android networking stubs.

`expectations.json` is a nonempty array with this shape:

```json
[{"file":"approved-v2.json","ownerId":"synthetic-owner-uuid","day":"2026-09-16","expectedDeviceId":"synthetic-device-uuid","availableFeatures":["sleep"],"unavailableFeatures":["hrv","respiration"],"nestedHrvAvailable":false,"nestedRespirationAvailable":false}]
```

The runners assert feature activation, unavailable display selection, exact selected device when supplied, and embedded physiology. Optional `expectedValues` maps `sleep`, `hrv` or `respiration` to the expected scalar selected for display, including valid zero. They check the original Edge bytes for embedded unauthorized values before accepting decoder sanitization. Include approved v2, retained v1, shadow, missing/revoked approval, manifest mismatch, sleep-only approval and isolated user/device cases. A successful run proves decoder/display-selection behavior, not physical screen rendering or production deployment.

Prerequisites are Swift with macOS 13 or later, JDK 17 and the existing scoring Gradle wrapper. Set `JAVA_HOME` to the JDK 17 installation if needed. Unit tests deliberately use synthetic malformed payloads; these are separate from real SQL/Edge acceptance envelopes.
