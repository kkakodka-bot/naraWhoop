import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { canonicalJSON, sha256Hex } from '../../Tools/release/generate-migration-manifest.mjs';

const fixtureURL = new URL('../service/src/test/resources/hosted_ledger_predecessor_20260923.json', import.meta.url);
export const NATIVE_LEDGER_SHA256 = 'b0e9ee4b377ae6c287e1ee1aed1203b4a2ca99b6194def74482dd4788428c767';
export const FULL_IDENTITY_SHA256 = '8860c41c115c104a4130ea5048da18722279691bd26602b2066f8a706a794be7';
const SOURCE_RECEIPT_SHA256 = 'f3b71d15536666f21b7d645490971da0354435f6b5324ea66a554236d0210a5c';
const SUPERSESSION_SHA256 = '853e5766b725d3a14fb03a12b95ae211e41ed11e871bcce6f19bb43f80badb37';
const SUPERSEDED_IDENTITY = '20260918234000_motion_evidence_provenance.sql';
const SUPERSEDED_SOURCE_SHA256 = '982237106b845b7d29ebabc1682c5b8706f1e483dd6427dc4be1efe0463dc33d';
function requireThat(value, message) { if (!value) throw new Error(`NOT_READY: ${message}`); }

export function validateHostedPredecessorFixture(value) {
  requireThat(value?.schemaVersion === 1 && value.sourceReceipt?.sha256 === SOURCE_RECEIPT_SHA256
    && value.sourceReceipt.projectRef === 'sgoyxzcagqyxexmsidtk'
    && value.sourceReceipt.productionMutation === false, 'hosted predecessor capture provenance changed');
  requireThat(value.historicalSupersessionAttestation?.sha256 === SUPERSESSION_SHA256
    && value.historicalSupersessionAttestation.releaseSourceSha === '33a38c5167afec5beeadd700be714e89fa25fb57',
    'historical supersession attestation changed');
  requireThat(Array.isArray(value.nativeLedger) && value.nativeLedger.length === 110
    && sha256Hex(canonicalJSON(value.nativeLedger)) === NATIVE_LEDGER_SHA256,
    'native predecessor must match the exact captured 110 rows, including names');
  requireThat(Array.isArray(value.fullIdentityLedger) && value.fullIdentityLedger.length === 117
    && sha256Hex(canonicalJSON(value.fullIdentityLedger)) === FULL_IDENTITY_SHA256,
    'full predecessor must retain the exact captured 117 identities and hashes');
  requireThat(value.identityStates?.[SUPERSEDED_IDENTITY]?.state === 'superseded_in_hosted_schema'
    && value.identityStates[SUPERSEDED_IDENTITY].reason ===
      'The hosted schema already had the equivalent columns and constraints through a later forward repair.'
    && value.fullIdentityLedger.find(row => row.stableIdentity === SUPERSEDED_IDENTITY)?.sha256 === SUPERSEDED_SOURCE_SHA256,
    'superseded full identity must remain attested; it is not a native timestamp row');
  return value;
}
export function loadHostedPredecessorFixture() {
  return validateHostedPredecessorFixture(JSON.parse(fs.readFileSync(fixtureURL, 'utf8')));
}

export function verifyHostedNativeLedger(observed, fixture = loadHostedPredecessorFixture()) {
  validateHostedPredecessorFixture(fixture);
  requireThat(Array.isArray(observed), 'native ledger capture must be an array');
  const ordered = [...observed].sort((a, b) => String(a.version).localeCompare(String(b.version)));
  requireThat(ordered.length === 110 && sha256Hex(canonicalJSON(ordered)) === NATIVE_LEDGER_SHA256,
    'observed native ledger differs from the frozen read-only 110-row capture');
  return { status: 'PASS', scope: 'local_fixture_native_ledger_fidelity', nativeLedgerRows: 110,
    nativeLedgerFingerprintSha256: NATIVE_LEDGER_SHA256, fullIdentityRows: 117,
    predecessorFullIdentityFingerprintSha256: FULL_IDENTITY_SHA256,
    sourceReceiptSha256: SOURCE_RECEIPT_SHA256, historicalSupersessionAttestationSha256: SUPERSESSION_SHA256,
    productionMutation: false, hostedDeploymentAcceptance: 'NOT_MEASURED' };
}

/** Local disposable fixture only. Existing rows are a failure, never overwritten or deleted. */
export function hostedNativeLedgerSeedSQL(observedFull, fixture = loadHostedPredecessorFixture()) {
  validateHostedPredecessorFixture(fixture);
  const ordered = [...observedFull].sort((a, b) => a.stableIdentity.localeCompare(b.stableIdentity));
  requireThat(ordered.length === 117 && sha256Hex(canonicalJSON(ordered)) === FULL_IDENTITY_SHA256,
    'local predecessor full identity/hash ledger differs from the captured 117-entry attestation');
  const nativeJSON = canonicalJSON(fixture.nativeLedger).replaceAll("'", "''");
  return `begin;
create table if not exists supabase_migrations.schema_migrations(version text primary key,name text);
do $$ begin
  assert not exists(select 1 from supabase_migrations.schema_migrations), 'native fixture requires an empty disposable ledger';
end $$;
insert into supabase_migrations.schema_migrations(version,name)
select version,name from jsonb_to_recordset('${nativeJSON}'::jsonb) as native(version text,name text);
commit;
`;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, input] = process.argv.slice(2);
  if (!['seed', 'verify'].includes(mode) || !input || process.argv.length !== 4) {
    throw new Error('Use hosted-ledger-fixture.mjs seed|verify captured-ledger.json');
  }
  const value = JSON.parse(fs.readFileSync(input, 'utf8'));
  process.stdout.write(mode === 'seed' ? hostedNativeLedgerSeedSQL(value)
    : `${JSON.stringify(verifyHostedNativeLedger(value), null, 2)}\n`);
}
