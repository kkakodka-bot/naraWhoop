#!/bin/bash
# Run the full app suite against a freshly generated, actual JVM publication.
# Caller must first run PopulatedContextSnapshotFixtureIntegrationTest successfully.
set -euo pipefail
fixture="${1:?usage: run-hosted.sh fixture.json derived-data result.xcresult}"
build_dir="${2:?derived-data directory required}"
result="${3:?new result bundle path required}"
cd "$(dirname "$0")/../.."

python3 - "$fixture" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
assert p.name == 'W4-POPULATED-CONTEXT-SNAPSHOT-V2-NATIVE-FIXTURE.json'
assert p.is_absolute() and isinstance(json.loads(p.read_bytes()), dict)
PY

xcodebuild build-for-testing -project Strand.xcodeproj -scheme Strand -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$build_dir" CODE_SIGN_IDENTITY=-

# xcodebuild's shell environment is not an app-test environment contract. Bind the
# fixture explicitly into the generated run file; keep missing inputs fail-closed.
run_file=$(python3 - "$build_dir" "$fixture" <<'PY'
import pathlib, plistlib, sys
products = pathlib.Path(sys.argv[1]) / 'Build' / 'Products'
runs = list(products.glob('Strand_macosx*.xctestrun'))
assert len(runs) == 1, 'Expected exactly one generated Strand run file'
path = runs[0]
value = plistlib.loads(path.read_bytes())
targets = [v for v in value.values() if isinstance(v, dict)]
for configuration in value.get('TestConfigurations', []):
    targets.extend(configuration.get('TestTargets', []))
matches = [t for t in targets if t.get('BlueprintName') == 'StrandTests']
assert len(matches) == 1, 'StrandTests must occur exactly once'
matches[0].setdefault('EnvironmentVariables', {}).update({
    'W4_POPULATED_CONTEXT_FIXTURE': sys.argv[2],
    'NOOP_HERMETIC_TESTING': '1',
    'NOOP_TEST_DISABLE_BLUETOOTH': '1',
})
path.write_bytes(plistlib.dumps(value))
print(path)
PY
)
xcodebuild test-without-building -xctestrun "$run_file" -destination 'platform=macOS' \
  -resultBundlePath "$result" -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 600
