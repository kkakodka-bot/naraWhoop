#!/usr/bin/env bash
set -euo pipefail
compute_repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$compute_repo"
mkdir -p .derived/compute-checks .derived/fixtures
xcodegen generate --spec Tools/compute/project.yml --project .derived/compute-checks
xcodebuild -project .derived/compute-checks/ComputeChecks.xcodeproj \
  -scheme FinalHostedChecks -destination 'platform=macOS' \
  -derivedDataPath .derived/compute-final-macos CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_DEBUG_DYLIB=NO \
  -only-testing:ComputeChecksTests/FinalHostedRuntimeTests \
  -only-testing:ComputeChecksTests/CanonicalPhysiologySurfaceTests test
