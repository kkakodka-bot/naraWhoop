import assert from 'node:assert/strict';
import { gunzipSync } from 'node:zlib';
import { AuxiliaryIdentityValidator, auxiliaryFingerprint, strictAuxiliaryFields } from '../_shared/auxiliaryIdentity.ts';
import { scalarProvenance } from '../_shared/scalarProvenance.ts';
import { schemaVersionFor, negotiateProtocol } from '../_shared/registry.ts';
import { sha256Hex } from '../_shared/s3.ts';

// Exact vector from actual Swift PushAuxiliaryIdentityTests, not a second encoder's expected output.
export const AUX_GOLDEN = '4e504231020203000000' +
  '0100000000000000640000000000000001000000000000000009000000020100000000000000' +
  '0200000000000000640000000000000001ffffffff00000000090000000201000000ffffffff' +
  '030000000000000064000000000000000006000000020200000001';
export const unhex = (hex: string) => Uint8Array.from(hex.match(/../g)!, (pair) => parseInt(pair, 16));
export const V18_PROVENANCE = { v: 1, origin: 'whoop-v18', recordIndex: 25443699,
  frameSHA256: 'f33c461502c48aa493723f437268fbe88b2d08e25b7c73deedd427544b8a9ade' };
export const PPG_PROVENANCE = { v: 1, origin: 'whoop-v26-ppg-derived', algorithm: 'ppg-acf-v1',
  sampleRateHz: 24, windowSettingSeconds: 8, inputStartTs: 100, inputEndTs: 102,
  inputSHA256: 'c0c4d0701eb3741fd07bd4a62d2cc23f6caccc91819f927e7df30ab07ef66ac4' };
export const INVALID_PROVENANCE = [[], 'json', true, { v: 2, origin: 'whoop-v18' },
  { ...V18_PROVENANCE, origin: ['whoop-v18'] }, { ...V18_PROVENANCE, origin: true },
  { ...PPG_PROVENANCE, algorithm: ['ppg-acf-v1'] }, { ...PPG_PROVENANCE, algorithm: 1 },
  { v: 1, origin: 'whoop-v18', extra: 1 }, { ...V18_PROVENANCE, recordIndex: true },
  { ...V18_PROVENANCE, recordIndex: '1' }, { ...V18_PROVENANCE, recordIndex: -1 },
  { ...V18_PROVENANCE, recordIndex: 4294967296 }, { ...V18_PROVENANCE, frameSHA256: 'A'.repeat(64) },
  { ...V18_PROVENANCE, frameSHA256: { nested: 1 } }, { ...V18_PROVENANCE, algorithm: 'ppg-acf-v1' },
  { v: 1, origin: 'legacy-unknown', recordIndex: 0 }, { v: 1, origin: 'whoop-v26-ppg-derived' },
  { ...PPG_PROVENANCE, sampleRateHz: 0 }, { ...PPG_PROVENANCE, windowSettingSeconds: 0.5 },
  { ...PPG_PROVENANCE, inputEndTs: 100 }, { ...PPG_PROVENANCE, inputSHA256: 'x'.repeat(1025) }];

Deno.test('auxiliary1.4 exact Swift bytes/fingerprints survive every small chunk boundary', async () => {
  const bytes = unhex(AUX_GOLDEN);
  assert.equal(sha256Hex(bytes), 'bc0f818227ef1c3ed66b6596dbeb4e533d4f632994ac5728c4ac4701a3ee523a');
  const fingerprints = [0, 4294967295, null].map((index) => auxiliaryFingerprint('fixture-device', 100, index));
  assert.deepEqual(fingerprints, ['af4a73756a88246ff46f49a667eb32d4917de6468ac189d4b8ccb4b308f1ecaa',
    '7ad1d842f0a57254542785cb45fb33dd4162c7b45a12db7af8a5469ce5c85d82',
    '39ad74746342bc4d30c7086d6a66db64d7f2ed52d55c95bf1e83bb8ac405bb59']);
  for (let chunk = 1; chunk <= bytes.length; chunk++) {
    const parser = new AuxiliaryIdentityValidator(3, 100, 101);
    for (let offset = 0; offset < bytes.length; offset += chunk) parser.push(bytes.subarray(offset, offset + chunk));
    assert.deepEqual(parser.finish(), { version: 1, format: 2, records: 3, supportedRecords: 3,
      unknownIdentityRecords: 1, unsupportedFieldsRecords: 0, state: 'validated' });
  }
  const exported = `${Deno.env.get('EDGE_TEST_ARTIFACTS')}/aux14-swift`;
  assert.deepEqual(await Deno.readFile(`${exported}/payload.npb1`), bytes);
  assert.deepEqual(new Uint8Array(gunzipSync(await Deno.readFile(`${exported}/payload.gz`))), bytes);
  assert.deepEqual(JSON.parse(await Deno.readTextFile(`${exported}/golden.json`)).fingerprints, fingerprints);
});

Deno.test('auxiliary1.4 refuses incomplete framing/identity but retains unsupported fields as explicit debt', () => {
  const bytes = unhex(AUX_GOLDEN);
  for (let end = 0; end < bytes.length; end++) {
    const parser = new AuxiliaryIdentityValidator(3, 100, 101);
    parser.push(bytes.subarray(0, end)); assert.throws(() => parser.finish(), /aux_truncated/);
  }
  for (const [offset, value, error] of [[4, 1, 'invalid_aux'], [6, 2, 'aux_count'],
    [26, 2, 'aux_index_presence'], [27, 1, 'aux_fields_identity'], [34, 1, 'aux_index_range']] as const) {
    const changed = bytes.slice(); changed[offset] = value;
    assert.throws(() => new AuxiliaryIdentityValidator(3, 100, 101).push(changed), new RegExp(error));
  }
  const trailing = new Uint8Array(bytes.length + 1); trailing.set(bytes);
  assert.throws(() => new AuxiliaryIdentityValidator(3, 100, 101).push(trailing), /aux_trailing/);
  assert.throws(() => new AuxiliaryIdentityValidator(3, 99, 101).push(bytes), /aux_window_mismatch/);
  const future = bytes.slice(); future[39] = 3;
  const parser = new AuxiliaryIdentityValidator(3, 100, 101); parser.push(future);
  assert.equal(parser.finish().state, 'pending'); assert.equal(parser.finish().unsupportedFieldsRecords, 1);
  for (const fields of [[], [2], [2, 1, 0, 0, 0], [2, 0, 0, 2, 0]]) {
    assert.equal(strictAuxiliaryFields(Uint8Array.from(fields)).supported, false);
  }
});

Deno.test('scalar provenance validates the actual producer shape and PPG input digest golden', () => {
  for (const p of [V18_PROVENANCE, PPG_PROVENANCE, { v: 1, origin: 'legacy-unknown' }]) {
    assert.deepEqual(scalarProvenance(p, '1.4'), p);
    assert.throws(() => scalarProvenance(p, '1.3'), /invalid_scalar_provenance/);
  }
  assert.equal(scalarProvenance(undefined, '1.4'), null);
  for (const p of INVALID_PROVENANCE) assert.throws(() => scalarProvenance(p, '1.4'), /invalid_scalar_provenance/);
  const input = unhex('77312d7070672d696e7075742d76310a0200000064000000000000000100000000000000000300000000800000ff7f650000000000000000020000000700f9ff');
  assert.equal(sha256Hex(input), PPG_PROVENANCE.inputSHA256);
});

Deno.test('schema mapping is exact; receiver support does not prematurely advertise1.4', () => {
  for (const version of ['1.0', '1.1', '1.2', '1.3', '1.4']) {
    assert.equal(schemaVersionFor('ppgWaveformSample', version), ['1.3', '1.4'].includes(version) ? 2 : 1);
    for (const stream of ['v18AuxSample', 'stepSample', 'sleepStateSample', 'ppgHrSample']) {
      assert.equal(schemaVersionFor(stream, version), version === '1.4' ? 2 : 1);
    }
    for (const stream of ['rawBatch', 'rawImuSession', 'hrSample']) assert.equal(schemaVersionFor(stream, version), 1);
  }
  assert.equal(negotiateProtocol('1.4,1.3,1.2'), '1.3');
  assert.equal(negotiateProtocol('1.4'), null);
});
