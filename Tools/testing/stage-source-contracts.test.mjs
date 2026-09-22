import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { stageSourceContracts } from './stage-source-contracts.mjs';

test('source contract resources are exact current source and regenerated on each build', () => {
  const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'source-contract-stage-test.'));
  try {
    const first = stageSourceContracts(repository, temporary);
    assert.equal(Object.keys(first.files).length, 21);
    for (const [relative, expected] of Object.entries(first.files)) {
      const source = fs.readFileSync(path.join(repository, relative));
      const copy = fs.readFileSync(path.join(first.destination, relative));
      assert.deepEqual(copy, source);
      assert.equal(crypto.createHash('sha256').update(copy).digest('hex'), expected.sha256);
    }
    const firstPath = Object.keys(first.files)[0];
    fs.writeFileSync(path.join(first.destination, firstPath), 'stale build source');
    const second = stageSourceContracts(repository, temporary);
    assert.deepEqual(fs.readFileSync(path.join(second.destination, firstPath)), fs.readFileSync(path.join(repository, firstPath)));
    assert.deepEqual(second.files, first.files);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true }); // exact mkdtemp directory created by this test only
  }
});
