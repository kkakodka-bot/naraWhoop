#!/usr/bin/env bash
set -euo pipefail
compute_repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$compute_repo"
mkdir -p .derived/compute-checks .derived/fixtures
xcodegen generate --spec Tools/compute/project.yml --project .derived/compute-checks
xcodebuild -project .derived/compute-checks/ComputeChecks.xcodeproj \
  -scheme ComputeChecks -destination 'platform=macOS' \
  -derivedDataPath .derived/compute-macos CODE_SIGNING_ALLOWED=NO \
  -only-testing:ComputeChecksTests/SyncDrainPolicyTests \
  -only-testing:ComputeChecksTests/ServerScoreRepositoryRaceTests \
  -only-testing:ComputeChecksTests/ServerScoringRescoreSkipTests \
  -only-testing:ComputeChecksTests/ScoringPreferenceContainmentTests/testRawUploadDrainsWhilePreferenceProjectionIsHeld \
  -only-testing:ComputeChecksTests/ScoringPreferenceContainmentTests/testNewRawTokenDuringUploadCannotBeSettledByOldAttempt \
  -only-testing:ComputeChecksTests/ScoringPreferenceContainmentTests/testHeldRepeatedWakesRetainExactJobsWhileRawRemainsRunnable \
  test
