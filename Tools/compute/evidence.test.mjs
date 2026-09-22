import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { requiredGates, validateCommand, validateOutput, validateReceipts, sourceSnapshot, hash } from './evidence.mjs';
import { validateSwiftProducerGuards } from './final-contract.mjs';

test('shared producer inventory names real first-instruction guards', () => {
  assert(validateSwiftProducerGuards() >= 395);
});
test('commands cannot replace executed gates with echoed success or filtered full suites', () => {
  assert.throws(() => validateCommand('swift-store', ['echo', 'swift', 'test', '--package-path', 'Packages/WhoopStore']));
  assert.throws(() => validateCommand('swift-store', ['swift', 'test', '--package-path', 'Packages/WhoopStore', '--filter', 'OneTest']));
  assert.throws(() => validateCommand('android-app', ['./gradlew', ':app:compileDebugKotlin']));
  assert.throws(() => validateCommand('macos-tests', ['xcodebuild', 'test', '-only-testing:A/B']));
  assert.throws(() => validateCommand('ios-final-runtime', ['bash', '-c', 'echo passed']));
  validateCommand('android-app', ['./gradlew', ':app:assembleDebug', ':app:testDebugUnitTest']);
  validateCommand('android-app', ['./gradlew', ':app:assembleFullDebug', ':app:testFullDebugUnitTest']);
  assert.throws(() => validateCommand('android-app', ['./gradlew', ':app:assembleFullDebug', ':app:testSlimDebugUnitTest']));
});
test('zero-test runs and route-only tests cannot satisfy executed proof', () => {
  assert.throws(() => validateOutput('swift-analytics', 'Executed 0 tests, with 0 failures'));
  assert.throws(() => validateOutput('server-pipeline', 'SQL -> actual Edge -> Swift/Kotlin decoder tests passed'));
  assert.throws(() => validateOutput('ios-final-runtime', 'FinalHostedRuntimeTests ** TEST SUCCEEDED **'));
  validateOutput('ios-final-runtime', 'FinalHostedRuntimeTests FINAL_HOSTED_ZERO path=cold_launch executions=0 ** TEST SUCCEEDED **');
});
test('receipt validation rejects stale revision content, changed logs, failures and missing gates', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'compute-receipt-tests-'));
  const actual = sourceSnapshot();
  // Synthetic unit fixture: never emitted by the production recorder and never used as a gate receipt.
  const snapshot = { ...actual, source_clean: true, dirty_source_paths: [] };
  try {
    const command = ['swift', 'test', '--package-path', 'Packages/StrandAnalytics', '--filter', 'PhoneInferenceRetirementTests'];
    const output = 'PhoneInferenceRetirementTests testNonoptionalEntrypointsFailLoudlyInFinalHostedMode Executed 5 tests, with 0 failures';
    fs.writeFileSync(path.join(directory, 'swift-zero-inference.log'), output);
    const receipt = { schema_version: 1, gate: 'swift-zero-inference', status: 'PASS', command,
      source_before: snapshot, source_after: snapshot, exit_code: 0,
      log_path: 'swift-zero-inference.log', log_sha256: hash(output) };
    const target = path.join(directory, 'swift-zero-inference.json');
    const write = (value) => fs.writeFileSync(target, JSON.stringify(value));
    write({ ...receipt, source_before: { ...snapshot, source_content_sha256: 'different' } });
    assert.throws(() => validateReceipts(directory, snapshot), /stale source evidence/);
    write({ ...receipt, log_sha256: 'wrong' });
    assert.throws(() => validateReceipts(directory, snapshot), /evidence log changed/);
    write({ ...receipt, status: 'FAIL' });
    assert.throws(() => validateReceipts(directory, snapshot));
    write(receipt);
    assert.throws(() => validateReceipts(directory, snapshot), /swift-protocol\.json/);
    assert(requiredGates.includes('server-pipeline') && requiredGates.includes('android-app'));
  } finally { fs.rmSync(directory, { recursive: true }); }
});
