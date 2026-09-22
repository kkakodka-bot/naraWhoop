#!/usr/bin/env bash
set -euo pipefail
compute_repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$compute_repo"
compute_products="${COMPUTE_TEST_PRODUCTS_DIR:-$(mktemp -d /private/tmp/nara-compute-products.XXXXXX)}"
# Keeping the executable and fixtures together avoids removable-volume privacy prompts from the
# XCTest app host. All compiler/package caches and result bundles remain in external DerivedData.
mkdir -p .derived/compute-checks "$compute_products/Debug/fixtures"
printf 'Compute test products: %s\n' "$compute_products"
xcodegen generate --spec Tools/compute/project.yml --project .derived/compute-checks
xcodebuild -project .derived/compute-checks/ComputeChecks.xcodeproj \
  -scheme FinalHostedChecks -destination 'platform=macOS' \
  -derivedDataPath .derived/compute-final-macos "SYMROOT=$compute_products" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM= ENABLE_DEBUG_DYLIB=NO \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  -only-testing:ComputeChecksTests/FinalHostedRuntimeTests \
  -only-testing:ComputeChecksTests/CanonicalPhysiologySurfaceTests \
  -only-testing:ComputeChecksTests/CanonicalConsumerPublicationTests \
  -only-testing:ComputeChecksTests/CanonicalWorkoutInputTests \
  -only-testing:ComputeChecksTests/ScoringPreferenceContainmentTests/testFinalHostedExportsUseCanonicalAdmissionWithoutPreferenceProjection \
  -only-testing:ComputeChecksTests/ScoringPreferenceContainmentTests/testFinalHostedResultChangeAtAttemptRetainsExactExportToken test
