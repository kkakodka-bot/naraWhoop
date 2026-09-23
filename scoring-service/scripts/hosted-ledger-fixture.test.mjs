import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { MIGRATION_CATALOG } from '../../infra/vps/scripts/scoring-migration-catalog.mjs';
import { migrationApplySQL } from '../../Tools/release/hosted-migration-release.mjs';
import { loadHostedPredecessorFixture, validateHostedPredecessorFixture,
  verifyHostedNativeLedger, hostedNativeLedgerSeedSQL, NATIVE_LEDGER_SHA256,
} from './hosted-ledger-fixture.mjs';

const fixture = loadHostedPredecessorFixture();
const actualFull = MIGRATION_CATALOG.slice(0, 117).map(row => ({ stableIdentity: row.basename, sha256: row.sha256 }));
function sourceDerivedNative() {
  const rows = new Map();
  for (const row of [...actualFull].sort((a, b) => a.stableIdentity.localeCompare(b.stableIdentity))) {
    const version = row.stableIdentity.slice(0, 14);
    if (!rows.has(version)) rows.set(version, { version, name: row.stableIdentity.slice(15) });
  }
  return [...rows.values()];
}

test('frozen capture preserves actual110 names, absent native motion row and117 full identities', () => {
  const receipt = verifyHostedNativeLedger(fixture.nativeLedger);
  assert.equal(receipt.nativeLedgerRows, 110);
  assert.equal(receipt.nativeLedgerFingerprintSha256, NATIVE_LEDGER_SHA256);
  assert.deepEqual([...actualFull].sort((a, b) => a.stableIdentity.localeCompare(b.stableIdentity)), fixture.fullIdentityLedger);
  assert.equal(fixture.nativeLedger.find(row => row.version === '20260918040000').name, 'rr_packet_provenance');
  assert.equal(fixture.nativeLedger.some(row => row.version === '20260918234000'), false);
  assert.equal(fixture.nativeLedger.some(row => row.name.endsWith('.sql')), false);
  assert.equal(fixture.fullIdentityLedger.filter(row => row.stableIdentity.startsWith('20260918040000')).length, 2);
  assert.equal(fixture.identityStates['20260918234000_motion_evidence_provenance.sql'].state, 'superseded_in_hosted_schema');
});

test('former actual runner algorithm produces111 and is rejected independently of before-after equality', () => {
  const surrogate = sourceDerivedNative();
  assert.equal(surrogate.length, 111);
  assert.equal(surrogate.find(row => row.version === '20260918234000').name, 'motion_evidence_provenance.sql');
  assert.equal(surrogate.find(row => row.version === '20260918040000').name, 'production_projection_debt.sql');
  assert.throws(() => verifyHostedNativeLedger(surrogate), /exact|frozen read-only 110-row capture/);
  assert.throws(() => verifyHostedNativeLedger(structuredClone(surrogate)), /frozen read-only 110-row capture/);
});

test('count correction alone and stripping suffixes still fail exact collision-name fidelity', () => {
  const almost = sourceDerivedNative().filter(row => row.version !== '20260918234000')
    .map(row => ({ ...row, name: row.name.replace(/\.sql$/, '') }));
  assert.equal(almost.length, 110);
  assert.throws(() => verifyHostedNativeLedger(almost), /frozen read-only 110-row capture/);
  const renamed = structuredClone(fixture.nativeLedger);
  renamed[0].name += '.sql';
  assert.throws(() => verifyHostedNativeLedger(renamed), /frozen read-only 110-row capture/);
});

test('local seed requires exact full identity hashes and never rewrites existing history', () => {
  const sql = hostedNativeLedgerSeedSQL(actualFull);
  assert.match(sql, /assert not exists\(select 1 from supabase_migrations.schema_migrations\)/);
  assert.match(sql, /insert into supabase_migrations.schema_migrations\(version,name\)/);
  assert.doesNotMatch(sql, /\b(?:delete|update|truncate|drop|distinct|on conflict)\b/i);
  assert.match(sql, /"name":"rr_packet_provenance","version":"20260918040000"/);
  assert.doesNotMatch(sql, /20260918234000/);
  const changed = structuredClone(actualFull); changed[0].sha256 = '0'.repeat(64);
  assert.throws(() => hostedNativeLedgerSeedSQL(changed), /117-entry attestation/);
  assert.throws(() => hostedNativeLedgerSeedSQL(actualFull.filter(row => !row.stableIdentity.includes('motion_evidence'))), /117-entry attestation/);
});

test('fixture provenance, supersession and immutable historical source hashes are pinned', () => {
  for (const change of [
    value => { value.sourceReceipt.sha256 = '0'.repeat(64); },
    value => { value.sourceReceipt.productionMutation = true; },
    value => { value.historicalSupersessionAttestation.sha256 = '0'.repeat(64); },
    value => { value.identityStates['20260918234000_motion_evidence_provenance.sql'].state = 'active'; },
    value => { value.fullIdentityLedger.find(row => row.stableIdentity.includes('motion_evidence')).sha256 = '0'.repeat(64); },
  ]) {
    const changed = structuredClone(fixture); change(changed);
    assert.throws(() => validateHostedPredecessorFixture(changed), /NOT_READY/);
  }
});

test('actual production apply wrapper is bound to frozen native capture and full predecessor', () => {
  const migration = MIGRATION_CATALOG[117];
  const sql = migrationApplySQL({ migrationBytes: fs.readFileSync(new URL(`../../supabase/migrations/${migration.basename}`, import.meta.url)),
    migration: { stableIdentity: migration.basename, sha256: migration.sha256, applyOrdinal: 1 },
    expectedNativeLedger: fixture.nativeLedger, expectedFullIdentityLedger: fixture.fullIdentityLedger });
  assert.match(sql, /frwhoop_native_ledger_drift/);
  assert.match(sql, /"name":"rr_packet_provenance","version":"20260918040000"/);
  assert.match(sql, /20260918234000_motion_evidence_provenance.sql/);
  assert.doesNotMatch(sql, /"name":"motion_evidence_provenance(?:\.sql)?"/);
});
