#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# XcodeGen embeds path-based scripts in DerivedData, so BASH_SOURCE is not the source file.
test_source_root="${1:-${SRCROOT:-$(pwd)}}"
while [[ ! -f "$test_source_root/Tools/testing/source-contract-inputs.json" ]]; do
  test_source_parent="$(dirname "$test_source_root")"
  [[ "$test_source_parent" != "$test_source_root" ]] || { printf 'Repository source contracts not found\n' >&2; exit 1; }
  test_source_root="$test_source_parent"
done
test_resources="${2:-${TARGET_BUILD_DIR:?test target build directory required}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?test resources path required}}"
exec node "$test_source_root/Tools/testing/stage-source-contracts.mjs" "$test_source_root" "$test_resources"
