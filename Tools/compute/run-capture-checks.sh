#!/usr/bin/env bash
set -euo pipefail
capture_repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$capture_repo"
capture_scratch="${CAPTURE_TEST_SCRATCH:-$(mktemp -d /private/tmp/nara-capture-checks.XXXXXX)}"
mkdir -p .derived/compute-checks "$capture_scratch/products/Debug/fixtures"
printf 'Capture test scratch: %s\n' "$capture_scratch"
xcodegen generate --spec Tools/compute/project.yml --project .derived/compute-checks
xcodebuild -project .derived/compute-checks/ComputeChecks.xcodeproj \
  -scheme GenericCaptureChecks -destination 'platform=macOS' \
  -derivedDataPath "$capture_scratch/derived" "SYMROOT=$capture_scratch/products" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM= ENABLE_DEBUG_DYLIB=NO \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym test
