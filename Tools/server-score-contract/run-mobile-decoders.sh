#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 || ! -f "$1/expectations.json" ]]; then
  echo 'usage: run-mobile-decoders.sh FIXTURE_DIRECTORY (containing real Edge envelopes and expectations.json)' >&2
  exit 2
fi
contract_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir="$(cd "$1" && pwd)"
swift run --package-path "$contract_dir/swift" DecodeContract "$fixture_dir"
"$contract_dir/../../scoring-service/gradlew" --project-dir "$contract_dir/android" --console=plain test installDist
"$contract_dir/android/build/install/server-score-decoder-contract/bin/server-score-decoder-contract" "$fixture_dir"
