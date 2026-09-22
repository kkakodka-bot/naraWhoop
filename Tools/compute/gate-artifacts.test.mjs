import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { captureAndroidReports, requiredAndroidReports, validateAndroidReport, validateAndroidReports } from './gate-artifacts.mjs';

// Synthetic parser fixtures only; these are never saved as repository verification receipts.
function report(expected, { tests = expected.minimum, skipped = 0, failures = 0, errors = 0 } = {}) {
  const cases = Array.from({ length: tests }, (_, i) =>
    `<testcase name="case-${i}" classname="${expected.name}" time="0.01"/>`).join('\n');
  return `<?xml version="1.0"?><testsuite name="${expected.name}" tests="${tests}" skipped="${skipped}" failures="${failures}" errors="${errors}">\n` +
    `${cases}\n<system-out><![CDATA[${expected.markers.join('\n')}]]></system-out></testsuite>`;
}

test('Android proof requires executed native cases, zero skips and real zero-inference counters', () => {
  for (const expected of requiredAndroidReports) {
    assert.equal(validateAndroidReport(report(expected), expected).tests, expected.minimum);
    for (const problem of [{ tests: 0 }, { skipped: 1 }, { failures: 1 }, { errors: 1 }]) {
      assert.throws(() => validateAndroidReport(report(expected, problem), expected));
    }
    assert.throws(() => validateAndroidReport(report(expected).replace('<testcase ', '<not-a-test '), expected));
    assert.throws(() => validateAndroidReport(report(expected).replace(`classname="${expected.name}"`, 'classname="other"'), expected));
    assert.throws(() => validateAndroidReport(report(expected).replace('</testsuite>', '<failure/></testsuite>'), expected));
    assert.throws(() => validateAndroidReport(report(expected).replace('</testsuite>', ''), expected));
    if (expected.markers.length) assert.throws(() => validateAndroidReport(report(expected).replace(expected.markers[0], ''), expected));
  }
});

test('CDATA cannot manufacture executed tests or hide an empty native consumer suite', () => {
  const expected = requiredAndroidReports.at(-1);
  const xml = report(expected);
  assert.throws(() => validateAndroidReport(xml.replace(/(<testcase[^>]+>)/g, '<![CDATA[$1]]>'), expected));
  const noisy = xml.replace('<system-out><![CDATA[', '<system-out><![CDATA[<testcase name="fake"/><failure/>');
  assert.equal(validateAndroidReport(noisy, expected).tests, expected.minimum);
});

test('Android recorder rejects stale, absent, skipped or edited native artifacts', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'compute-native-report-tests-'));
  const source = path.join(root, 'android/app/build/test-results/testFullDebugUnitTest');
  const evidence = path.join(root, 'receipts');
  fs.mkdirSync(source, { recursive: true }); fs.mkdirSync(evidence);
  const command = ['./gradlew', ':app:assembleFullDebug', ':app:testFullDebugUnitTest', '--rerun-tasks'];
  const started = new Date(Date.now() - 1000).toISOString();
  try {
    for (const expected of requiredAndroidReports) fs.writeFileSync(path.join(source, `TEST-${expected.name}.xml`), report(expected));
    const finished = new Date().toISOString();
    const runtime_reports = captureAndroidReports(root, evidence, command, started, finished);
    const receipt = { command, started_at: started, finished_at: finished, runtime_reports };
    validateAndroidReports(evidence, receipt);
    assert.throws(() => validateAndroidReports(evidence, { ...receipt, runtime_reports: runtime_reports.slice(1) }));
    assert.throws(() => validateAndroidReports(evidence, { ...receipt, started_at: new Date(Date.now() + 10000).toISOString() }), /not produced during/);
    const target = path.join(evidence, runtime_reports[0].path);
    fs.appendFileSync(target, '<!-- changed -->');
    assert.throws(() => validateAndroidReports(evidence, receipt), /report changed/);
    const sourceTarget = path.join(source, runtime_reports[0].path);
    fs.utimesSync(sourceTarget, new Date(0), new Date(0));
    assert.throws(() => captureAndroidReports(root, evidence, command, started, finished), /not produced during/);
    fs.writeFileSync(sourceTarget, report(requiredAndroidReports[0], { skipped: 1 }));
    assert.throws(() => captureAndroidReports(root, evidence, command, started, finished), /skipped must be zero/);
    fs.unlinkSync(sourceTarget);
    assert.throws(() => captureAndroidReports(root, evidence, command, started, finished), /ENOENT/);
  } finally { fs.rmSync(root, { recursive: true }); }
});
