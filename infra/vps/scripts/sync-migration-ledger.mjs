import { migrationLedger, requireThat } from './sync-evidence-contract.mjs';
import { MIGRATION_NAMES, MIGRATION_HASHES } from './scoring-migration-catalog.mjs';

export const SUPPORTED_LEDGER_BASENAMES = MIGRATION_NAMES;
const byPrefix = new Map();
for (const name of MIGRATION_NAMES) {
  const prefix = name.slice(0, 14);
  byPrefix.set(prefix, [...(byPrefix.get(prefix) ?? []), name]);
}

export function migrationIdentity(value) {
  const row = typeof value === 'string' ? { version: value } : value;
  requireThat(row && typeof row === 'object' && !Array.isArray(row) && typeof row.version === 'string',
    'raw migration ledger entries must have a version');
  let basename = row.version;
  if (/^\d{14}$/.test(row.version)) {
    const candidates = byPrefix.get(row.version) ?? [];
    if (typeof row.name === 'string') {
      basename = row.name.endsWith('.sql') ? row.name : `${row.version}_${row.name}.sql`;
      requireThat(candidates.includes(basename), 'migration ledger name does not resolve its version');
    } else {
      requireThat(candidates.length === 1, 'ambiguous or unknown timestamp-only migration; reconcile full applied identity before continuing');
      [basename] = candidates;
    }
  }
  requireThat(MIGRATION_HASHES.has(basename), 'unsupported migration ledger basename');
  if (row.sha256 !== undefined) requireThat(row.sha256 === MIGRATION_HASHES.get(basename), `applied migration hash differs: ${basename}`);
  return basename;
}

export function canonicalMigrationLedger(raw) {
  requireThat(Array.isArray(raw), 'raw migration ledger must be an array');
  const canonical = raw.map(migrationIdentity);
  migrationLedger(canonical);
  return canonical.sort();
}

export function validateMigrationEvidence(server) {
  migrationLedger(server?.migrations);
  const canonical = canonicalMigrationLedger(server?.migrationLedgerRaw);
  requireThat(JSON.stringify(canonical) === JSON.stringify([...server.migrations].sort()),
    'recorded raw migration ledger differs from canonical evidence IDs');
  return canonical;
}
