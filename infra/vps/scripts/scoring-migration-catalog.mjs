import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';

// Reviewed source identities. Applied history is never renamed to hide timestamp collisions.
export const MIGRATION_CATALOG = Object.freeze(JSON.parse(fs.readFileSync(
  new URL('../../../scoring-service/service/src/main/resources/scoring-migration-catalog.json', import.meta.url), 'utf8')).map(Object.freeze));
export const MIGRATION_NAMES = Object.freeze(MIGRATION_CATALOG.map(row => row.basename).sort());
export const MIGRATION_HASHES = new Map(MIGRATION_CATALOG.map(row => [row.basename, row.sha256]));

export function verifyMigrationSources(directory) {
  const names = fs.readdirSync(directory).filter(name => name.endsWith('.sql')).sort();
  if (JSON.stringify(names) !== JSON.stringify(MIGRATION_NAMES)) throw new Error('NOT_READY: migration catalogue differs from source filenames');
  for (const { basename, sha256 } of MIGRATION_CATALOG) {
    const filename = path.join(directory, basename);
    if (!fs.lstatSync(filename).isFile() ||
      crypto.createHash('sha256').update(fs.readFileSync(filename)).digest('hex') !== sha256) {
      throw new Error(`NOT_READY: migration source hash differs: ${basename}`);
    }
  }
  return MIGRATION_CATALOG.length;
}
