import path from 'node:path';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
import { MIGRATION_CATALOG, MIGRATION_HASHES, verifyMigrationSources } from './scoring-migration-catalog.mjs';
import { migrationIdentity } from './sync-migration-ledger.mjs';
import { readJSON, requireThat, reportError } from './sync-evidence-contract.mjs';

// Input is a bounded, read-only ledger export. Hashes for historical rows that never stored
// hashes must come from reviewed deployment artifacts, never from current source by inference.
export function migrationPlan(raw, historicalIdentities = []) {
  requireThat(Array.isArray(raw) && Array.isArray(historicalIdentities), 'ledger and historical identities must be arrays');
  const attestations = new Map();
  for (const row of historicalIdentities) {
    const basename = migrationIdentity(row);
    requireThat(!attestations.has(basename) && row.sha256 === MIGRATION_HASHES.get(basename), 'historical identity requires distinct full basename and matching source hash');
    attestations.set(basename, row.sha256);
  }
  const applied = new Map();
  for (const row of raw) {
    const basename = migrationIdentity(row);
    requireThat(!applied.has(basename), 'duplicate applied migration identity');
    const hash = typeof row === 'object' ? row.sha256 : undefined;
    requireThat((hash ?? attestations.get(basename)) === MIGRATION_HASHES.get(basename),
      `applied migration hash not attested: ${basename}`);
    applied.set(basename, MIGRATION_HASHES.get(basename));
  }
  const pending = MIGRATION_CATALOG.filter(row => !applied.has(row.basename));
  const historicalGaps = raw.length === 0 ? [] : pending.filter(row => row.basename < '20260921100000');
  return {
    schemaVersion: 1, status: historicalGaps.length ? 'REVIEW_REQUIRED' : 'PLAN_REVIEWABLE',
    mutationPerformed: false, lineage: raw.length === 0 ? 'fresh' : 'upgrade',
    applied: [...applied].map(([basename, sha256]) => ({ basename, sha256 })),
    pending, historicalGaps,
    reason: historicalGaps.length ? 'Historical omissions require a reviewed upgrade lineage; do not replay them blindly.' : null,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  try {
    requireThat(process.argv.length === 4 || process.argv.length === 5,
      'usage: scoring-migration-plan.mjs SOURCE_DIRECTORY LEDGER_JSON [REVIEWED_HISTORICAL_IDENTITIES_JSON]');
    verifyMigrationSources(path.resolve(process.argv[2]));
    const result = migrationPlan(readJSON(process.argv[3]), process.argv[4] ? readJSON(process.argv[4]) : []);
    console.log(JSON.stringify(result, null, 2));
    if (result.status !== 'PLAN_REVIEWABLE') process.exitCode = 3;
  } catch (error) { reportError(error); }
}
