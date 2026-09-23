import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { evidenceDefault, sourceSnapshot, validateReceipts } from './evidence.mjs';
import { validateFinalSourceContracts } from './final-contract.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');
const registry = JSON.parse(read('docs/compute/metric-ownership.json'));
assert.equal(registry.schemaVersion, 1);
const ids = new Set();
const metrics = new Set();
for (const entry of registry.entries) {
  assert(!ids.has(entry.id), `duplicate family: ${entry.id}`);
  ids.add(entry.id);
  for (const key of ['localProducer', 'requiredInputs', 'outputContract', 'consumers', 'cutover', 'validation']) {
    assert(entry[key], `${entry.id}: missing ${key}`);
  }
  assert(entry.requiredInputs.length && entry.consumers.length, entry.id);
  for (const file of Object.values(entry.localProducer)) assert(fs.existsSync(path.join(root, file)), file);
  if (entry.serverProducer) {
    for (const key of ['implementation', 'entrypoint']) {
      assert(fs.existsSync(path.join(root, entry.serverProducer[key])), entry.serverProducer[key]);
    }
  }
  for (const output of entry.outputContract.metrics) {
    assert(output.id && output.unit, `${entry.id}: output contract`);
    metrics.add(output.id);
  }
  if (entry.cutover.localProducerRemoved) {
    assert(entry.serverProducer && entry.canonicalReadback && entry.cutover.completeConsumerClosure &&
      entry.cutover.finalHostedEligible, `${entry.id}: premature producer removal`);
  }
}

// Every scalar/detail metric selectable by the iOS repository must have an ownership row.
const swiftMetricSource = read('Strand/Push/ServerScoreSnapshot.swift').split('    static let vitals:')[0];
for (const match of swiftMetricSource.matchAll(/^\s*case (.+)$/gm)) {
  for (const part of match[1].split(',')) {
    const item = part.trim().match(/^(\w+)(?:\s*=\s*"([^"]+)")?$/);
    assert(item, `unrecognized metric declaration: ${part}`);
    assert(metrics.has(item[2] ?? item[1]), `missing visible metric: ${item[2] ?? item[1]}`);
  }
}

const swift = read('Packages/WhoopStore/Sources/WhoopStore/ServerMetricOwnership.swift');
const kotlin = read('android/app/src/main/java/com/noop/push/ServerMetricOwnership.kt');
const quoted = (text) => [...text.matchAll(/"([^"]+)"/g)].map((m) => m[1]).sort();
const featureMap = (source, expression) => Object.fromEntries([...source.matchAll(expression)]
  .map((m) => [m[1], quoted(m[2])]).sort(([a], [b]) => a.localeCompare(b)));
const swiftMap = featureMap(swift, /"([^"]+)": \[([\s\S]*?)\]/g);
const kotlinMap = featureMap(kotlin, /"([^"]+)" to setOf\(([\s\S]*?)\)/g);
assert.deepEqual(swiftMap, kotlinMap, 'platform ownership contracts differ');
for (const family of Object.values(swiftMap)) for (const metric of family) {
  assert(metrics.has(metric), `claim not inventoried: ${metric}`);
}
const swiftRequired = quoted(swift.match(/dailyKernelOutputs: Set<String> = \[([\s\S]*?)\]/)[1]);
const kotlinRequired = quoted(kotlin.match(/dailyKernelOutputs = setOf\(([\s\S]*?)\)/)[1]);
assert.deepEqual(swiftRequired, kotlinRequired, 'daily producer dependency closures differ');
for (const metric of swiftRequired) assert(metrics.has(metric), `kernel output not inventoried: ${metric}`);
assert(!read('Strand/Push/ServerScoringSettings.swift').includes('CloudScoreIdentity.overlayLive'));
assert(!read('Strand/Push/ServerScoreRepository.swift').includes('markOverlayLive'));
assert(!read('android/app/src/main/java/com/noop/push/ServerScoreRepository.kt').includes('markOverlayLive'));

const blocked = registry.entries.filter((entry) => !entry.cutover.finalHostedEligible).map((entry) => entry.id);
const requireFinal = process.argv.includes('--require-final');
let finalSource, runtimeEvidence, finalFailure;
if (requireFinal) {
  try {
    assert.equal(blocked.length, 0, `Incomplete registry families: ${blocked.join(', ')}`);
    finalSource = validateFinalSourceContracts(registry);
    const position = process.argv.indexOf('--evidence-dir');
    const directory = path.resolve(root, position >= 0 ? process.argv[position + 1] :
      process.env.COMPUTE_EVIDENCE_DIR ?? evidenceDefault);
    runtimeEvidence = validateReceipts(directory, sourceSnapshot());
  } catch (error) { finalFailure = error.message; process.exitCode = 1; }
}
console.log(JSON.stringify({ registry: 'PASS', families: ids.size, outputs: metrics.size,
  ownershipParity: 'PASS', assertions: { static: finalSource ?? 'registry and legacy ownership maps only',
    executed: runtimeEvidence ?? 'NOT_VERIFIED' },
  // These gates establish source/runtime ownership. Even an executed all-null
  // envelope and zero local calls cannot establish numerical producer closure,
  // deployment, reference qualification or physical phone continuity.
  finalHosted: requireFinal && !finalFailure ? 'SOURCE_RUNTIME_VERIFIED' : 'NOT_VERIFIED',
  numericalProducerParity: registry.finalHostedStatus,
  productionAcceptance: 'NOT_MEASURED',
  blocked, finalFailure }, null, 2));
