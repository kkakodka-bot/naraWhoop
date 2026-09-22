import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const [fixtures, swift, kotlin] = process.argv.slice(2);
assert(fixtures && swift && kotlin, 'usage: node test-canonical-runners.mjs ACTUAL_FIXTURES SWIFT_BINARY KOTLIN_BINARY');
const expectations = JSON.parse(fs.readFileSync(path.join(fixtures, 'expectations.json'), 'utf8'));
const output = fs.mkdtempSync(path.join(os.tmpdir(), 'canonical-runner-mutations.'));
const cases = [
  { name: 'null-owned-value', fixture: 'approved-v2.json', reason: /final canonical hrv_rmssd_ms differs/,
    mutate: (row) => { row.server_scoring.compute.families.night_hrv.values.hrv_rmssd_ms = null; } },
  { name: 'altered-owned-value', fixture: 'approved-v2.json', reason: /final canonical hrv_rmssd_ms differs/,
    mutate: (row) => { row.server_scoring.compute.families.night_hrv.values.hrv_rmssd_ms = 1; } },
  { name: 'legacy-only-response', fixture: 'approved-v2.json', reason: /missing final canonical contract/,
    mutate: (row) => { delete row.server_scoring.compute; } },
  { name: 'sleep-only-nested-leak', fixture: 'sleep-only.json', reason: /canonical sleep leaked hrv_rmssd_ms/,
    mutate: (row) => { row.server_scoring.compute.families.sleep.details.nights[0].hrv_rmssd_ms = 1; } },
];
for (const test of cases) {
  const expected = expectations.find((row) => row.file === test.fixture);
  assert(expected, `Actual ${test.fixture} capture required`);
  const directory = path.join(output, test.name);
  fs.mkdirSync(directory);
  const row = JSON.parse(fs.readFileSync(path.join(fixtures, test.fixture), 'utf8'));
  test.mutate(row);
  fs.writeFileSync(path.join(directory, test.fixture), JSON.stringify(row));
  fs.writeFileSync(path.join(directory, 'expectations.json'), JSON.stringify([expected]));
  for (const [platform, binary] of [['swift', swift], ['kotlin', kotlin]]) {
    const result = spawnSync(path.resolve(binary), [directory], { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
    assert(!result.error, result.error?.message);
    assert.notEqual(result.status, 0, `${platform} accepted ${test.name}`);
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    fs.writeFileSync(path.join(directory, `${platform}.log`), log);
    assert.match(log, test.reason, `${platform}: mutation failed for an unrelated reason`);
    console.log(`${platform}: rejected ${test.name}`);
  }
}
console.log(`Canonical runner mutation checks passed: 8 rejections; artifacts ${output}`);
