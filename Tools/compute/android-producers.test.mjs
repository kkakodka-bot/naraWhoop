import test from 'node:test';
import assert from 'node:assert/strict';
import { validateAndroidProducerGuards } from './final-contract.mjs';

const file = 'android/app/src/main/java/test/Producer.kt';
const guard = 'PhoneComputeRuntime.inferenceStarted("recovery")';
const entry = { file, symbol: 'score', producer: 'recovery', guard_kind: 'numerical_entrypoint',
  guard, occurrence: 1, first_body_statement: true };
const check = (source, entries = [entry]) => validateAndroidProducerGuards({
  inventory: { schema_version: 1, entries }, minimumEntries: 0,
  sourceFiles: [file], readSource: () => source,
});

test('Android guards bind literal identities to their callable, not comments or string content', () => {
  assert.deepEqual(check(`fun score(): Int { /* nested /* comment */ */ ${guard}; return 5 }`),
    { total: 1, numericalEntrypoints: 1, hostedAdmissions: 0, firstBodyStatements: 1 });
  assert.throws(() => check(`fun score(): Int { // ${guard}\n return 5 }`), /Missing Android/);
  assert.throws(() => check(`fun score(): String { return """${guard}""" }`), /Missing Android/);
  assert.throws(() => check(`fun other(): Int { ${guard}; return 5 }`), /callable mismatch/);
  assert.throws(() => check(`fun score(): Int { ${guard}; return 5 }`, [{ ...entry, producer: 'different' }]), /identity mismatch/);
  assert.throws(() => check(`fun score(): Int { ${guard}; return 5 }`, [{ ...entry, guard_kind: 'hosted_admission' }]), /kind mismatch/);
});

test('first-body claims fail if numerical work moves before the guard', () => {
  assert.throws(() => check(`fun score(): Int { val result = 5; ${guard}; return result }`), /precedes declared first-body/);
  const delayed = check(`fun score() = withContext(IO) { ${guard}; 5 }`, [{ ...entry, first_body_statement: false }]);
  assert.equal(delayed.firstBodyStatements, 0);
  assert.throws(() => check(`fun score() = withContext(IO) { ${guard}; 5 }`), /precedes declared first-body/);
});

test('duplicate, omitted and unscoped numerical guards fail the complete inventory check', () => {
  assert.throws(() => check(`fun score() { ${guard} }`, [entry, entry]), /Duplicate Android/);
  assert.throws(() => check(`fun score() { ${guard} }`, []), /Uninventoried Android/);
  assert.throws(() => check(`fun score() { ${guard} } fun again() { ${guard} }`), /Uninventoried Android/);
  assert.throws(() => check(`${guard}\nfun score() {}`), /outside a callable/);
  assert.throws(() => check(`fun score() { PhoneComputeRuntime.inferenceStarted(producer) }`), /literal inventoried/);
});

test('ordinal occurrences and nested callables cannot substitute for one another', () => {
  const source = `fun score() { ${guard} } fun another() { ${guard} }`;
  assert.equal(check(source, [entry, { ...entry, symbol: 'another', occurrence: 2 }]).total, 2);
  assert.throws(() => check(source, [entry, { ...entry, symbol: 'score', occurrence: 2 }]), /callable mismatch/);
  assert.throws(() => check(`fun score() { fun hidden() { ${guard} } }`), /callable mismatch/);
});
