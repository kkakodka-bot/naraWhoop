import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { root } from './evidence.mjs';

const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const quoted = (text) => [...text.matchAll(/"([^"]+)"/g)].map((m) => m[1]).sort();
const map = (source, expression) => Object.fromEntries([...source.matchAll(expression)]
  .map((m) => [m[1], quoted(m[2])]).sort(([a], [b]) => a.localeCompare(b)));
const contains = (file, tokens) => {
  const source = read(file);
  for (const token of tokens) assert(source.includes(token), `${file}: missing source contract ${token}`);
};
const normalize = (text) => text.replace(/\/\/[^\n]*/g, '').replace(/\s+/g, ' ').trim();

export function validateFinalSourceContracts(registry) {
  const expected = Object.fromEntries(registry.entries.map((e) => [e.id, e.outputContract.metrics.map((m) => m.id).sort()])
    .sort(([a], [b]) => a.localeCompare(b)));
  const swiftFile = 'Packages/WhoopStore/Sources/WhoopStore/ServerCanonicalResult.swift';
  const androidFile = 'android/app/src/main/java/com/noop/push/ServerComputeContract.kt';
  const swiftMap = map(read(swiftFile).split('public static let familyMetrics:')[1].split('public static let allMetrics')[0], /"([^"]+)": \[([^\]]+)\]/g);
  const androidMap = map(read(androidFile).split('val familyMetrics = mapOf(')[1].split('val metricIDs')[0], /"([^"]+)" to setOf\(([^)]+)\)/g);
  assert.deepEqual(swiftMap, expected, 'Swift canonical families must cover the exact registry, including explicitly missing metrics');
  assert.deepEqual(androidMap, expected, 'Android canonical families must cover the exact registry');
  const sqlFile = 'supabase/migrations/20260921110000_final_hosted_compute_contract.sql';
  const sql = read(sqlFile);
  const sqlMap = Object.fromEntries([...sql.matchAll(/\('([^']+)',array\[([^\]]+)\]/g)]
    .map((m) => [m[1], [...m[2].matchAll(/'([^']+)'/g)].map((v) => v[1]).sort()])
    .sort(([a], [b]) => a.localeCompare(b)));
  assert.deepEqual(sqlMap, expected, 'Production server disposition policy must cover every family and metric');
  contains(sqlFile, ['server_scoring_read_contract_v1', 'server_compute_dispositions', 'source_result_hash',
    'process_compute_disposition', 'input_revision', 'timezone_id', 'canonical_qualification', 'configuration_metadata_status']);
  contains('supabase/functions/_shared/serverScores.ts', ['auth/v1/user', 'server_scoring_for_device_day',
    'compute-requests', 'source_id', 'supabaseUrl']);
  contains('scoring-service/service/src/main/kotlin/com/frwhoop/scoring/ScoringApplication.kt',
    ['ComputeContractPublisher', 'publishDay(', 'computePublisher::retryDay', 'computePublisher::processSession']);
  contains('scoring-service/service/src/main/kotlin/com/frwhoop/scoring/scoring/ScoringPoller.kt', ['publishComputeDispositions']);
  contains('supabase/migrations/20260921111000_compute_session_requests.sql',
    ['expires_at', 'decision_expired', 'compute_session_results', 'compute_session_requests', 'process_compute_session_request']);
  for (const file of [swiftFile, androidFile]) contains(file, ['result_revision', 'input_revision', 'manifest_hash', 'canonical_qualification', 'source_id', 'device_id']);

  const swiftProducerEntrypoints = validateSwiftProducerGuards();
  contains('Packages/WhoopProtocol/Sources/WhoopProtocol/PhoneComputeRuntime.swift',
    ['NOOPFinalHostedCompute', 'precondition(!isFinalHosted', 'executions', 'denied']);
  contains('Packages/StrandAnalytics/Tests/StrandAnalyticsTests/PhoneInferenceRetirementTests.swift',
    ['testNonoptionalEntrypointsFailLoudlyInFinalHostedMode', 'testFinalHostedOptionalProducersRefuseBeforeNumericalWork',
      'testFinalHostedLeavesUserTimersFormattingAndRawProvenanceOperational']);
  contains('Tools/compute/Tests/FinalHostedRuntimeTests.swift', ['FinalHostedRuntimeTests', 'PhoneComputeRuntime']);
  contains('android/app/src/test/java/com/noop/analytics/FinalHostedComputeRuntimeTest.kt', ['FinalHostedComputeRuntimeTest']);
  contains('android/app/src/main/java/com/noop/analytics/PhoneComputeRuntime.kt', ['finalHosted', 'inferenceStarted']);
  contains('android/app/src/main/java/com/noop/NoopApplication.kt', ['PhoneComputeRuntime.installFinalHosted()']);
  contains('android/app/build.gradle.kts', ['buildConfigField("boolean", "FINAL_HOSTED_COMPUTE", "true")']);
  assert([...read('project.yml').matchAll(/NOOPFinalHostedCompute: true/g)].length >= 2,
    'Both shipped Apple app targets must declare immutable final-hosted mode');

  for (const entry of registry.entries) {
    assert(entry.cutover.finalHostedEligible && entry.cutover.completeConsumerClosure,
      `${entry.id}: family not independently declared migrated`);
    assert(entry.canonicalReadback, `${entry.id}: missing canonical readback contract`);
    assert(entry.serverProducer?.implementation && entry.serverProducer?.entrypoint,
      `${entry.id}: real result or missing-state producer must be declared`);
    const evidence = entry.validation?.finalHosted;
    assert(evidence?.consumerFiles?.length && evidence?.testFiles?.length,
      `${entry.id}: missing concrete consumer and validation source inventory`);
    for (const file of [...evidence.consumerFiles, ...evidence.testFiles]) assert(fs.existsSync(path.join(root, file)), `${entry.id}: missing ${file}`);
    assert(evidence.disposition === 'qualified_or_explicit_server_state', `${entry.id}: missing final disposition`);
  }
  return { families: Object.keys(expected).length, swiftProducerEntrypoints,
    sourceAssertions: ['exact family/metric maps across registry, SQL, Swift and Android',
      'production worker publication, independent retry and durable session entrypoints',
      'first-instruction shared Swift producer guards', 'per-family consumer and test source inventory'],
    runtimeAssertionsRequired: ['production phone lifecycle zero-inference', 'raw upload with analytics disabled',
      'database/account/enrollment/production decoder parity', 'consumer revision and cache fencing',
      'Android application build and executed tests', 'late-input/edit/calendar/baseline replay'] };
}

export function validateSwiftProducerGuards() {
  const inventory = JSON.parse(read('docs/compute/swift-producers.json'));
  assert.equal(inventory.schema_version, 1);
  assert(inventory.entrypoints.length >= 395, 'Shared Swift producer inventory cannot silently shrink');
  const sourceCache = new Map();
  for (const entry of inventory.entrypoints) {
    assert(entry.mode === 'reference_only');
    if (!sourceCache.has(entry.file)) sourceCache.set(entry.file, normalize(read(entry.file)));
    const source = sourceCache.get(entry.file), signature = normalize(entry.symbol) + ' {';
    const start = source.indexOf(signature);
    assert(start >= 0, `Unresolved producer inventory symbol: ${entry.file}: ${entry.symbol}`);
    const body = source.slice(start + signature.length).trimStart();
    const admission = entry.bodyguard === 'entered' ? '' :
      `guard PhoneComputeRuntime.permitsLocal("${entry.producer}") else { return ${entry.bodyguard === 'permitsLocal:nil+entered' ? 'nil' : '[]'} } `;
    assert(body.startsWith(admission + `PhoneComputeRuntime.entered("${entry.producer}")`),
      `Numerical work precedes final-hosted instrumentation: ${entry.producer}`);
  }
  return inventory.entrypoints.length;
}
