#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/installation-lifecycle.XXXXXX")"
mkdir -p "$evidence/Sources/InstallationLifecycleHarness" "$evidence/Tests/InstallationLifecycleTests"
ln -s "$root/Tests/InstallationLifecycleNative/Package.swift" "$evidence/Package.swift"
ln -s "$root/Strand/Push/CloudEnrollment.swift" "$evidence/Sources/InstallationLifecycleHarness/CloudEnrollment.swift"
ln -s "$root/Tests/InstallationLifecycleNative/BoundaryStubs.swift" "$evidence/Sources/InstallationLifecycleHarness/BoundaryStubs.swift"
ln -s "$root/Tests/InstallationLifecycleNative/LifecycleTests.swift" "$evidence/Tests/InstallationLifecycleTests/LifecycleTests.swift"
shasum -a 256 "$root/Strand/Push/CloudEnrollment.swift" > "$evidence/source.sha256"
NARA_LIFECYCLE_SOURCE_ROOT="$root" swift test --package-path "$evidence" --jobs 4 2>&1 | tee "$evidence/swift.log"
printf 'Native installation lifecycle evidence: %s\n' "$evidence"
