#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
test_source_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
test_resources="${2:-${TARGET_BUILD_DIR:?test target build directory required}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?test resources path required}}"
exec node "$test_source_root/Tools/testing/stage-source-contracts.mjs" "$test_source_root" "$test_resources"
