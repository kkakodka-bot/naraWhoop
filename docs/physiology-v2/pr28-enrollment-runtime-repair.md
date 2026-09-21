# Tester enrollment runtime repair

The PR 27 integration creates the application runtime from the password-session identity. Tester codes instead create a separate installation enrollment credential. An enrolled tester consequently received a guest runtime, with capture and presentation disabled, while the root displayed the strap-link gate. The gate's sign-out button cleared the password session rather than enrollment.

The phone incident confirmed a server registration receipt for the same `my-whoop` identity as the paired-device registry. An owner/source-scoped database remained present, while the broken runtime had opened a separate unassigned database. Preferences and both database/WAL pairs were copied before repair; no phone database was removed or reset.

The runtime now recognizes validated enrollment identity and replaces its model on enrollment changes. Enrollment reopens its existing owner/source directory. The account-owner metadata upgrade requires the exact stored enrollment owner and installation witness, and refuses conflicting endpoint ownership. Capture and durable uploads use the enrolled installation source and opaque token, with the existing ownership fences. Password-session credentials remain a separate authentication path.

The link gate explicitly confirms registration independently of score fetches. Sign-out clears enrollment and fences pending publication. Tester score scalars feed the current dashboard through a separate presentation field rather than fabricated account snapshot revisions. Null server results remain unavailable. Registered-device selection precedes score bootstrap.

Validation during implementation: 17 identity/storage package tests passed; 38 focused application tests passed; iPhone Release compilation passed. The full app test target has pre-existing compile failures in `ExploreRangeGatingTests.swift` and `ServerScoringRescoreSkipTests.swift`; those files were excluded for the focused app run. Final build and handset verification are recorded in the PR handoff. This change does not establish fleet latency, overnight continuity, or physiological validation.
