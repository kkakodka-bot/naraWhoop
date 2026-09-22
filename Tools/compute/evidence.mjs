import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const evidenceDefault = 'docs/compute/evidence';
export const requiredGates = ['swift-zero-inference', 'swift-protocol', 'swift-store', 'swift-analytics',
  'swift-support',
  'server-jvm', 'server-pipeline', 'ios-final-runtime', 'android-app', 'ios-build', 'watch-build', 'macos-tests'];
export const hash = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const git = (...args) => {
  const result = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
};
const relevant = (name) => !name.startsWith('docs/compute/evidence/') &&
  (!name.startsWith('docs/') || /^docs\/compute\/(metric-ownership|swift-producers|android-producers|consumer-revisions)\.json$/.test(name)) &&
  /\.(swift|kt|kts|java|ts|tsx|js|mjs|json|sql|sh|yml|yaml|xml|plist|pbxproj|xcscheme|xcconfig|toml|properties|gradle|jar)$/.test(name);

/// Evidence binds to all checked-in implementation, tests and build contracts, not merely a branch
/// name. Markdown handoffs and evidence receipts are excluded to avoid self-referential hashes.
export function sourceSnapshot() {
  const files = [...new Set(git('ls-files', '-z', '--cached', '--others', '--exclude-standard').split('\0'))]
    .filter(relevant).sort();
  const digest = crypto.createHash('sha256');
  for (const file of files) {
    digest.update(file).update('\0');
    digest.update(fs.existsSync(path.join(root, file)) ? fs.readFileSync(path.join(root, file)) : '<deleted>');
    digest.update('\0');
  }
  const dirty = git('status', '--porcelain=v1', '--untracked-files=all').split('\n')
    .filter(Boolean).map((line) => line.slice(3).replace(/^"|"$/g, '')).filter(relevant);
  return { source_sha: git('rev-parse', 'HEAD').trim(), source_content_sha256: digest.digest('hex'),
    source_file_count: files.length, source_clean: dirty.length === 0, dirty_source_paths: dirty };
}

const has = (command, token) => command.some((part) => part === token || part.endsWith('/' + token));
export function validateCommand(gate, command) {
  assert(requiredGates.includes(gate), `Unknown verification gate: ${gate}`);
  assert(command.length && !['-c', '--command'].some((arg) => command.includes(arg)), 'Use a direct gate command, not a shell expression');
  const script = (name) => has(command, name) && ['bash', '/bin/bash'].includes(command[0]);
  const swift = (name) => /(^|\/)swift$/.test(command[0]) && command.includes('test') &&
    command.some((value) => value.endsWith(`Packages/${name}`)) && !command.includes('--skip-build');
  if (gate === 'swift-zero-inference') assert(swift('StrandAnalytics') && command.includes('PhoneInferenceRetirementTests'));
  if (gate === 'swift-protocol') assert(swift('WhoopProtocol') && !command.includes('--filter'));
  if (gate === 'swift-store') assert(swift('WhoopStore') && !command.includes('--filter'));
  if (gate === 'swift-analytics') assert(swift('StrandAnalytics') && !command.includes('--filter'));
  if (gate === 'swift-support') assert(script('Tools/compute/run-support-package-checks.sh'));
  if (gate === 'server-jvm') assert(script('scoring-service/scripts/test-server-jvm.sh'));
  if (gate === 'server-pipeline') assert(script('scoring-service/scripts/test-server-pipeline.sh'));
  if (gate === 'ios-final-runtime') assert(script('Tools/compute/run-final-hosted-checks.sh'));
  if (gate === 'android-app') {
    assert(has(command, 'gradlew') || command[0].endsWith('/gradle'));
    const assemble = command.map((v) => v.match(/^(?::?app:)?assemble([A-Za-z0-9]*)Debug$/)).find(Boolean);
    assert(assemble && command.some((v) => v === `:app:test${assemble[1]}DebugUnitTest` ||
      v === `app:test${assemble[1]}DebugUnitTest` || v === `test${assemble[1]}DebugUnitTest`),
      'An Android application build and executed unit suite are both required');
  }
  if (['ios-build', 'watch-build', 'macos-tests'].includes(gate)) {
    assert(/(^|\/)xcodebuild$/.test(command[0]), 'Use the actual Xcode build/test command');
    if (gate === 'macos-tests') assert(command.includes('test') && !command.some((v) => v.startsWith('-only-testing') || v.startsWith('-skip-testing')));
    else assert(command.includes('build') && command.some((v) => gate === 'watch-build' ? /watchOS/.test(v) : /iOS/.test(v)));
  }
}

export function validateOutput(gate, output) {
  if (gate.startsWith('swift-')) assert(/Executed [1-9][0-9]* tests?, with 0 failures/.test(output), 'No successful executed Swift tests');
  if (gate === 'swift-zero-inference') assert(output.includes('PhoneInferenceRetirementTests') && output.includes('testNonoptionalEntrypointsFailLoudlyInFinalHostedMode'));
  if (gate === 'swift-support') {
    for (const name of ['NoopLocalAccess', 'NoopPush', 'OuraProtocol', 'PolarProtocol', 'StrandDesign', 'StrandImport'])
      assert(output.includes(`SUPPORT_PACKAGE_PASS: ${name}`), `Missing complete ${name} package run`);
  }
  if (gate === 'server-jvm') assert(output.includes('Clean JVM tests and installDist passed with a newly exported actual-Swift corpus'));
  if (gate === 'server-pipeline') {
    assert(output.includes('SQL -> actual Edge -> Swift/Kotlin decoder tests passed'));
    for (const platform of ['swift', 'kotlin']) {
      assert(new RegExp(`${platform}: [2-9][0-9] real Edge envelopes passed`).test(output));
      assert(output.includes(`${platform} worker-0.json: decoded and display selection verified`), 'Actual worker result must reach the production decoder');
      assert(output.includes(`${platform} account-sleep-only.json: decoded and display selection verified`), 'Actual account route must reach the production decoder');
    }
  }
  if (gate === 'ios-final-runtime') {
    assert(output.includes('FinalHostedRuntimeTests') && output.includes('** TEST SUCCEEDED **'));
    assert(output.includes('FINAL_HOSTED_ZERO') && output.includes('executions=0'), 'Missing exercised zero-inference counters');
  }
  if (gate === 'android-app') assert(output.includes('BUILD SUCCESSFUL'));
  if (gate === 'ios-build' || gate === 'watch-build') assert(output.includes('** BUILD SUCCEEDED **'));
  if (gate === 'macos-tests') assert(output.includes('** TEST SUCCEEDED **'));
}

export function validateReceipts(directory, snapshot = sourceSnapshot()) {
  assert(snapshot.source_clean, `Commit source before final verification: ${snapshot.dirty_source_paths.join(', ')}`);
  return requiredGates.map((gate) => {
    const receipt = JSON.parse(fs.readFileSync(path.join(directory, `${gate}.json`), 'utf8'));
    assert.equal(receipt.schema_version, 1); assert.equal(receipt.gate, gate); assert.equal(receipt.status, 'PASS');
    assert.equal(receipt.source_before.source_content_sha256, snapshot.source_content_sha256, `${gate}: stale source evidence`);
    assert.equal(receipt.source_after.source_content_sha256, snapshot.source_content_sha256, `${gate}: source changed during execution`);
    assert(receipt.source_before.source_clean && receipt.source_after.source_clean, `${gate}: uncommitted source`);
    assert.equal(spawnSync('git', ['merge-base', '--is-ancestor', receipt.source_before.source_sha, snapshot.source_sha], { cwd: root }).status, 0,
      `${gate}: evidence revision is not in this ancestry`);
    validateCommand(gate, receipt.command);
    const logPath = path.resolve(directory, receipt.log_path);
    assert(logPath.startsWith(path.resolve(directory) + path.sep), 'Evidence log path escapes receipt directory');
    const log = fs.readFileSync(logPath);
    assert.equal(hash(log), receipt.log_sha256, `${gate}: evidence log changed`);
    validateOutput(gate, log.toString('utf8'));
    assert.equal(receipt.exit_code, 0);
    return { gate, status: 'PASS', source_sha: receipt.source_before.source_sha, source_content_sha256: snapshot.source_content_sha256 };
  });
}
