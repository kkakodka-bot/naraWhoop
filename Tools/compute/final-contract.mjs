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
  contains('supabase/functions/_shared/serverScores.ts', ['resolveJwtUser({headers:req.headers', 'server_scoring_for_device_day',
    'compute-requests', 'source_id', 'supabaseUrl']);
  contains('supabase/functions/_shared/tokens.ts', ['export async function resolveJwtUser', '/auth/v1/user']);
  contains('scoring-service/service/src/main/kotlin/com/frwhoop/scoring/ScoringApplication.kt',
    ['ComputeContractPublisher', 'publishDay(', 'computePublisher::retryDay', 'computePublisher::processSession']);
  contains('scoring-service/service/src/main/kotlin/com/frwhoop/scoring/scoring/ScoringPoller.kt', ['publishComputeDispositions']);
  contains('supabase/migrations/20260921111000_compute_session_requests.sql',
    ['expires_at', 'decision_expired', 'compute_session_results', 'compute_session_requests', 'process_compute_session_request']);
  for (const file of [swiftFile, androidFile]) contains(file, ['result_revision', 'input_revision', 'manifest_hash', 'canonical_qualification', 'source_id', 'device_id']);

  const swiftProducerEntrypoints = validateSwiftProducerGuards();
  const androidProducerGuards = validateAndroidProducerGuards();
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
  contains('Strand/Screens/CoachView.swift', ['PhoneComputeRuntime.isFinalHosted', 'CanonicalPhysiologySection(families: ["live_coaching", "insights"])']);
  contains('Strand/AI/AICoach.swift', ['permitsLocal("coach_physiological_context")',
    'permitsLocal("coach_stress_context")', 'permitsLocal("legacy_coach_provider")']);
  contains('Strand/System/CoachBriefScheduler.swift', ['!PhoneComputeRuntime.isFinalHosted', 'permitsLocal("legacy_scheduled_coaching")']);
  contains('Tools/compute/Tests/FinalHostedRuntimeTests.swift', ['AICoachError.serverOwnedUnavailable', 'CoachBriefScheduler.consumeStoredBrief()']);
  contains('StrandTests/CanonicalPhysiologySurfaceTests.swift', ['testFinalHostedLegacySleepAdapterCannotReconstructOrReturnLocalModel']);
  contains('Strand/Data/WhoopImporter.swift', ['let derivesLocally = PhoneComputeRuntime.permitsLocal("import.whoop_derived")',
    'if derivesLocally, let deep', 'entered("import.whoop_restorative")',
    'if derivesLocally, let asleep', 'entered("import.whoop_sleep_need")',
    'if derivesLocally {\n            PhoneComputeRuntime.entered("import.whoop_baselines_stress_zones")']);
  for (const [screen, producer] of [['AppleHealthView', 'physiological_mean'],
    ['XiaomiBandView', 'physiological_mean'], ['MedicationsView', 'physiological_response']]) {
    contains(`Strand/Screens/${screen}.swift`, ['PhoneComputeRuntime.isFinalHosted',
      'CanonicalPhysiologySection(', `permitsLocal("${screen}.${producer}")`, `entered("${screen}.${producer}")`]);
    contains('Tools/compute/Tests/FinalHostedRuntimeTests.swift', [`${screen}(`]);
  }
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
  for (const file of [...registry.sharedConsumers, ...registry.sessionContract.consumers]) {
    assert(fs.existsSync(path.join(root, file)), `Shared canonical consumer missing: ${file}`);
  }
  assert.deepEqual(registry.retirementExtensions.map((entry) => entry.output).sort(),
    ['caffeine_estimate', 'hydration_goal_ml', 'rhythm_summary'], 'Retired auxiliary physiology must remain inventoried');
  for (const extension of registry.retirementExtensions) {
    assert(extension.family === 'insights' && extension.status === 'unsupported' && extension.numericContract === false,
      `${extension.output}: no unqualified auxiliary producer may publish a numeric result`);
    for (const file of [extension.localProducer, ...extension.consumerFiles]) assert(fs.existsSync(path.join(root, file)), file);
  }
  return { families: Object.keys(expected).length, swiftProducerEntrypoints, androidProducerGuards,
    sourceAssertions: ['exact family/metric maps across registry, SQL, Swift and Android',
      'production worker publication, independent retry and durable session entrypoints',
      'first-instruction shared Swift producer guards',
      'Android callable-scoped numerical and admission guard inventory (first statement only where declared)',
      'per-family consumer and test source inventory'],
    runtimeAssertionsRequired: ['production phone lifecycle zero-inference', 'raw upload with analytics disabled',
      'database/account/enrollment/production decoder parity', 'consumer revision and cache fencing',
      'Android application build and executed tests', 'late-input/edit/calendar/baseline replay'] };
}

// A small lexical source check, not a Kotlin interpreter or runtime proof. Keeping comments and
// strings atomic prevents commented-out calls or a string containing a guard from satisfying it.
function kotlinTokens(source) {
  const tokens = [];
  let i = 0;
  while (i < source.length) {
    if (/\s/.test(source[i])) { i++; continue; }
    if (source.startsWith('//', i)) { const end = source.indexOf('\n', i); i = end < 0 ? source.length : end; continue; }
    if (source.startsWith('/*', i)) {
      let depth = 1; i += 2;
      while (i < source.length && depth) {
        if (source.startsWith('/*', i)) { depth++; i += 2; }
        else if (source.startsWith('*/', i)) { depth--; i += 2; }
        else i++;
      }
      assert.equal(depth, 0, 'Unterminated Kotlin comment'); continue;
    }
    const start = i;
    if (source.startsWith('"""', i)) {
      const end = source.indexOf('"""', i + 3);
      assert(end >= 0, 'Unterminated Kotlin raw string'); i = end + 3;
    } else if ('"\'`'.includes(source[i])) {
      const delimiter = source[i++];
      while (i < source.length) {
        if (source[i] === '\\' && delimiter !== '`') { i += 2; continue; }
        if (source[i++] === delimiter) break;
      }
    } else if (/[A-Za-z_$]/.test(source[i])) {
      while (i < source.length && /[A-Za-z0-9_$]/.test(source[i])) i++;
    } else i++;
    tokens.push({ text: source.slice(start, i), start, end: i });
  }
  return tokens;
}

function kotlinFunctions(tokens) {
  const pairs = new Map(), stack = [];
  for (let i = 0; i < tokens.length; i++) {
    if (['(', '{', '['].includes(tokens[i].text)) stack.push(i);
    else if ([')', '}', ']'].includes(tokens[i].text)) {
      const open = stack.pop();
      assert(open !== undefined && '({['.indexOf(tokens[open].text) === ')}]'.indexOf(tokens[i].text), 'Unbalanced Kotlin source');
      pairs.set(open, i);
    }
  }
  assert.equal(stack.length, 0, 'Unbalanced Kotlin source');
  const functions = [];
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].text !== 'fun') continue;
    let parameter = i + 1;
    while (parameter < tokens.length && tokens[parameter].text !== '(' && tokens[parameter].text !== '{') parameter++;
    if (tokens[parameter]?.text !== '(') continue;
    let nameStart = parameter - 1;
    while (nameStart > i + 2 && tokens[nameStart - 1].text === '.' && /^[A-Za-z_][A-Za-z0-9_]*$/.test(tokens[nameStart - 2].text)) nameStart -= 2;
    const name = tokens.slice(nameStart, parameter).map((token) => token.text.replace(/^`|`$/g, '')).join('');
    let body = pairs.get(parameter) + 1;
    while (body < tokens.length && !['{', '=', '}', 'fun'].includes(tokens[body].text)) {
      if (pairs.has(body)) body = pairs.get(body) + 1;
      else body++;
    }
    const expression = tokens[body]?.text === '=';
    if (expression) {
      body++;
      while (body < tokens.length && !['{', '}', 'fun'].includes(tokens[body].text)) {
        if (pairs.has(body)) body = pairs.get(body) + 1;
        else body++;
      }
    }
    if (tokens[body]?.text === '{') functions.push({ name, start: i, body, end: pairs.get(body), expression });
  }
  return functions;
}

function kotlinRuntimeCalls(source) {
  const tokens = kotlinTokens(source), functions = kotlinFunctions(tokens), calls = [];
  for (let i = 0; i < tokens.length - 5; i++) {
    if (tokens[i].text !== 'PhoneComputeRuntime' || tokens[i + 1].text !== '.' ||
      !['inferenceStarted', 'allowsLocal'].includes(tokens[i + 2].text)) continue;
    assert.equal(tokens[i + 3].text, '(');
    assert(/^"[^"\\]+"$/.test(tokens[i + 4].text) && tokens[i + 5].text === ')',
      'Every Android producer guard must have a literal inventoried producer identity');
    let start = i;
    while (start >= 2 && tokens[start - 1].text === '.' && /^[A-Za-z_][A-Za-z0-9_]*$/.test(tokens[start - 2].text)) start -= 2;
    const owner = functions.filter((f) => f.body < start && start < f.end).sort((a, b) => b.start - a.start)[0];
    assert(owner, `Android guard outside a callable: ${tokens[i + 4].text}`);
    calls.push({ guard: source.slice(tokens[start].start, tokens[i + 5].end), producer: JSON.parse(tokens[i + 4].text),
      symbol: owner.name, guard_kind: tokens[i + 2].text === 'inferenceStarted' ? 'numerical_entrypoint' : 'hosted_admission',
      first: !owner.expression && owner.body + 1 === start });
  }
  return calls;
}

export function validateAndroidProducerGuards(options = {}) {
  const rootPath = options.rootPath ?? root;
  const readSource = options.readSource ?? ((file) => fs.readFileSync(path.join(rootPath, file), 'utf8'));
  const inventory = options.inventory ?? JSON.parse(readSource('docs/compute/android-producers.json'));
  assert.equal(inventory.schema_version, 1);
  assert(inventory.entries.length >= (options.minimumEntries ?? 225), 'Android producer inventory cannot silently shrink');
  const walk = (directory) => fs.readdirSync(path.join(rootPath, directory), { withFileTypes: true })
    .flatMap((entry) => entry.isDirectory() ? walk(`${directory}/${entry.name}`) :
      entry.name.endsWith('.kt') ? [`${directory}/${entry.name}`] : []);
  const files = options.sourceFiles ?? walk('android/app/src/main/java');
  const actual = new Map();
  for (const file of files) {
    const source = readSource(file);
    if (!/PhoneComputeRuntime\s*\.\s*(inferenceStarted|allowsLocal)/.test(source)) continue;
    let calls;
    try { calls = kotlinRuntimeCalls(source); }
    catch (error) { throw new Error(`${file}: ${error.message}`, { cause: error }); }
    const occurrences = new Map();
    for (const call of calls) {
      const occurrence = (occurrences.get(call.guard) ?? 0) + 1;
      occurrences.set(call.guard, occurrence);
      actual.set(JSON.stringify([file, call.guard, occurrence]), call);
    }
  }
  const seen = new Set();
  const counts = { numericalEntrypoints: 0, hostedAdmissions: 0, firstBodyStatements: 0 };
  for (const entry of inventory.entries) {
    assert(Number.isInteger(entry.occurrence) && entry.occurrence > 0);
    assert.equal(typeof entry.first_body_statement, 'boolean');
    const key = JSON.stringify([entry.file, entry.guard, entry.occurrence]);
    assert(!seen.has(key), `Duplicate Android inventory guard: ${key}`); seen.add(key);
    const call = actual.get(key);
    assert(call, `Missing Android inventory guard: ${key}`);
    assert.equal(call.symbol, entry.symbol, `Android callable mismatch: ${key}`);
    assert.equal(call.producer, entry.producer, `Android producer identity mismatch: ${key}`);
    assert.equal(call.guard_kind, entry.guard_kind, `Android guard kind mismatch: ${key}`);
    if (entry.first_body_statement) {
      assert(call.first, `Numerical work precedes declared first-body Android guard: ${key}`);
      counts.firstBodyStatements++;
    }
    counts[entry.guard_kind === 'numerical_entrypoint' ? 'numericalEntrypoints' : 'hostedAdmissions']++;
  }
  for (const key of actual.keys()) assert(seen.has(key), `Uninventoried Android runtime guard: ${key}`);
  return { total: seen.size, ...counts };
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
