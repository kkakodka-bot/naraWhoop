import fs from 'node:fs';
import { MIGRATION_NAMES } from './scoring-migration-catalog.mjs';

// One canonical required chain for source presence, evidence, and the live ledger.
export const REQUIRED_MIGRATIONS = MIGRATION_NAMES;
export const CANARY_STAGES = Object.freeze(['committed', 'accepted', 'archiveVerified', 'indexed', 'computed', 'displayed']);
export const SCENARIOS = Object.freeze(['twoHourLockedReconnect', 'overnightThroughWake', 'forceQuitRecovery', 'twoAccounts', 'twoDevices', 'backlog72Hours']);
export const fail = reason => { throw new Error(`NOT_READY: ${reason}`); };
export const requireThat = (condition, reason) => { if (!condition) fail(reason); };
export const nonempty = value => typeof value === 'string' && value.trim().length > 0;
export const sha = value => typeof value === 'string' && value.length === 64 && /^[0-9a-f]{64}$/.test(value);
export const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
// Canonical UTC with milliseconds. Date.parse alone accepts rolled-over calendar dates.
export function instant(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)) return NaN;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) && new Date(parsed).toISOString() === value ? parsed : NaN;
}
export function migrationLedger(values) {
  requireThat(Array.isArray(values) && values.every(value => typeof value === 'string' && /^\d{14}_[a-z0-9_]+\.sql$/.test(value)) &&
    new Set(values).size === values.length, 'record distinct applied migration IDs as an array');
  for (const id of REQUIRED_MIGRATIONS) requireThat(values.includes(id), `deployed migration missing: ${id}`);
}
export function readJSON(filename) {
  requireThat(nonempty(filename), 'provide JSON path');
  const stat = fs.statSync(filename);
  requireThat(stat.isFile() && stat.size <= 1024 * 1024, 'JSON must be a regular file at most 1 MiB');
  return JSON.parse(fs.readFileSync(filename, 'utf8'));
}
export function reportError(error) {
  console.error(error?.message?.startsWith('NOT_READY:') ? error.message : 'NOT_READY: required file, artifact or command cannot be verified');
  process.exitCode = 3;
}
