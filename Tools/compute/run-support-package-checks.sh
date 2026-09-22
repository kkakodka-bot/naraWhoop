#!/usr/bin/env bash
set -euo pipefail
compute_repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$compute_repo"
for compute_package in NoopLocalAccess NoopPush OuraProtocol PolarProtocol StrandDesign StrandImport; do
  swift test --package-path "Packages/$compute_package" \
    --scratch-path ".derived/compute-support/$compute_package"
  printf 'SUPPORT_PACKAGE_PASS: %s\n' "$compute_package"
done
