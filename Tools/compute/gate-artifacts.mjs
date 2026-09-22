import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const requiredAndroidReports = [
  { name: 'com.noop.analytics.FinalHostedPhonePathsNativeTest', minimum: 1,
    markers: ['FINAL_HOSTED_COLD_LAUNCH admitted=0 forbidden=0'] },
  { name: 'com.noop.analytics.FinalHostedComputeRuntimeTest', minimum: 2,
    markers: ['FINAL_HOSTED_RUNTIME admitted=0 forbidden=0', 'FINAL_HOSTED_NEGATIVE_CONTROL deep producer blocked before body'] },
  { name: 'com.noop.push.FinalHostedRawUploadNativeTest', minimum: 1,
    markers: ['FINAL_HOSTED_DURABLE_RAW_UPLOAD admitted=0 forbidden=0'] },
  { name: 'com.noop.push.ServerComputeContractTest', minimum: 7, markers: [] },
  { name: 'com.noop.push.CanonicalConsumersNativeTest', minimum: 5,
    markers: ['FINAL_HOSTED_CONSUMER_REVISIONS same_revision=true widget_save_load=true export_zip=true health_adapter=true valid_zero=true health_zero_unsupported_without_coercion=true admitted=0 forbidden=0'] },
];
const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const attributes = (text) => Object.fromEntries([...text.matchAll(/([\w-]+)="([^"]*)"/g)].map((m) => [m[1], m[2]]));

// This reads Gradle's test-result dialect, not arbitrary XML. CDATA is excluded from structural
// checks so diagnostic strings cannot masquerade as executed cases or change failure counts.
export function validateAndroidReport(bytes, expected) {
  const xml = bytes.toString('utf8');
  const structure = xml.replace(/<!\[CDATA\[[\s\S]*?\]\]>/g, '').replace(/<!--[\s\S]*?-->/g, '');
  assert(!/<!DOCTYPE/i.test(structure), 'JUnit evidence must not contain external entities');
  const suites = [...structure.matchAll(/<testsuite\s+([^>]+)>/g)];
  assert.equal(suites.length, 1, `${expected.name}: one Gradle test suite required`);
  assert.equal((structure.match(/<\/testsuite>/g) ?? []).length, 1);
  const suite = attributes(suites[0][1]);
  assert.equal(suite.name, expected.name, 'JUnit suite identity mismatch');
  assert(/^[1-9][0-9]*$/.test(suite.tests ?? ''), `${expected.name}: no executed tests`);
  for (const field of ['failures', 'errors', 'skipped']) assert.equal(suite[field], '0', `${expected.name}: ${field} must be zero`);
  assert(!/<(?:failure|error|skipped)(?:\s|\/?>)/.test(structure), `${expected.name}: failed or skipped case`);
  const cases = [...structure.matchAll(/<testcase\s+([^>]+)>/g)].map((m) => attributes(m[1]));
  assert.equal(cases.length, Number(suite.tests), `${expected.name}: declared and executed case counts differ`);
  assert(cases.length >= expected.minimum, `${expected.name}: required runtime cases missing`);
  assert(cases.every((item) => item.classname === expected.name && item.name), 'JUnit case identity mismatch');
  assert.equal(new Set(cases.map((item) => item.name)).size, cases.length, 'Duplicate JUnit case identity');
  for (const marker of expected.markers) assert(xml.includes(marker), `${expected.name}: missing runtime counter ${marker}`);
  return { name: expected.name, tests: cases.length, failures: 0, errors: 0, skipped: 0 };
}

function taskReportDirectory(command) {
  const assemble = command.map((value) => value.match(/^(?::?app:)?assemble([A-Za-z0-9]*)Debug$/)).find(Boolean);
  assert(assemble, 'Android assemble variant missing');
  return `android/app/build/test-results/test${assemble[1]}DebugUnitTest`;
}

function validateReportTime(report, receipt) {
  const modified = Date.parse(report.source_modified_at);
  const start = Date.parse(receipt.started_at), finish = Date.parse(receipt.finished_at);
  assert(Number.isFinite(modified) && Number.isFinite(start) && Number.isFinite(finish));
  assert(modified >= start - 2000 && modified <= finish + 2000,
    `${report.name}: JUnit report was not produced during this gate`);
}

export function captureAndroidReports(root, directory, command, startedAt, finishedAt) {
  const reportDirectory = taskReportDirectory(command);
  return requiredAndroidReports.map((expected) => {
    const filename = `TEST-${expected.name}.xml`;
    const source = path.join(root, reportDirectory, filename), bytes = fs.readFileSync(source);
    const report = { ...validateAndroidReport(bytes, expected), path: filename,
      sha256: digest(bytes), source_path: `${reportDirectory}/${filename}`,
      source_modified_at: fs.statSync(source).mtime.toISOString() };
    validateReportTime(report, { started_at: startedAt, finished_at: finishedAt });
    fs.writeFileSync(path.join(directory, filename), bytes);
    return report;
  });
}

export function validateAndroidReports(directory, receipt) {
  const reports = receipt.runtime_reports;
  assert(Array.isArray(reports) && reports.length === requiredAndroidReports.length,
    'Android gate requires all executed native inference, upload, decoder and consumer reports');
  for (const expected of requiredAndroidReports) {
    const matches = reports.filter((report) => report.name === expected.name);
    assert.equal(matches.length, 1, `${expected.name}: missing or duplicate runtime report`);
    const report = matches[0], filename = `TEST-${expected.name}.xml`;
    assert.equal(report.path, filename, 'Runtime report path escapes expected artifact');
    assert.equal(report.source_path, `${taskReportDirectory(receipt.command)}/${filename}`);
    validateReportTime(report, receipt);
    const bytes = fs.readFileSync(path.join(directory, filename));
    assert.equal(digest(bytes), report.sha256, `${expected.name}: runtime report changed`);
    const actual = validateAndroidReport(bytes, expected);
    for (const field of ['tests', 'failures', 'errors', 'skipped']) assert.equal(report[field], actual[field]);
  }
}
