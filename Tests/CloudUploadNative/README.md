# Native cloud queue tests

Run from the repository root on macOS with Xcode selected and the existing NoopPush native Zstandard dependency installed:

```sh
zsh Tests/CloudUploadNative/run.sh /path/to/existing/external/artifacts
```

The runner creates a unique artifact directory outside the checkout. Production Swift sources and the two XCTest suites are symlinked from the current checkout, not copied. NoopPush is a local package dependency. The real ResourceBudget and SyncPipelineTrace sources are included. Additional `swift test` options may follow the artifact directory, for example `--filter CloudUploadOutcomeTests`.

Each run saves its test log, repository HEAD, and before/after SHA-256 manifests covering the compiled sources, package sources, tests, and harness files. A changed source fingerprint fails the run. HEAD alone does not identify uncommitted changes; retain the manifests. The script does not delete its artifact directory.

## Isolation boundaries

- `CloudAuthClient` is a fail-closed stub: unexpected refresh throws `signedOut`. It never opens Keychain or stored credentials. Authentication tests inject synthetic refresh closures into the real queue.
- `SyncEngine.DependentStageAdmission` is a fail-closed compile boundary. These suites do not construct it; unexpected validation returns false and boundary checking throws. This harness does not test the app's SyncEngine admission integration.
- `ReceiptFixture.swift` contains the synthetic `receipt`, `inline`, and `bytes` helpers from `W5ReceiptFixture` in `StrandTests/CloudPushReceiptIntegrationTests.swift`. It fabricates test responses only; receipt validation remains production code.
- The suites use fake session adapters or a controlled URLProtocol and synthetic account/device/token values. No real cloud account, device, or server is contacted. The runner clears inherited environment values before launching Swift.

This is macOS Debug deterministic queue/transport evidence, not an iOS Release build, background daemon execution, real credential refresh, deployed receiver verification, physical restoration, memory, energy, or thermal acceptance. The native Zstandard library is not evidence of iOS compression behavior. macOS library deployment-version linker warnings must not be treated as older-system compatibility proof.
