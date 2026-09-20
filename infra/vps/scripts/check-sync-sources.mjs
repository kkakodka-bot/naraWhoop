import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { REQUIRED_MIGRATIONS, requireThat, reportError } from './sync-evidence-contract.mjs';

export const PURE_DATA_SYMBOLS = Object.freeze([
  'DailyMetric', 'EventRow', 'GravitySample', 'HrSample', 'RespSample', 'RrInterval',
  'SkinTempSample', 'SleepSession', 'SourceKind', 'Spo2Sample', 'StepSample',
  'OuraRespScale', 'DeviceBrandCatalog', 'DeviceBrandSpec', 'V18AuxCodec', 'V18AuxRow', 'V18AuxSlot',
]);
export const SOURCE_ROOTS = Object.freeze([
  'scoring-service/service/src/main/kotlin', 'scoring-service/service/src/test/kotlin',
  'scoring-service/analytics-kernel/src/main/kotlin', 'scoring-service/analytics-kernel/src/test/kotlin',
  'scoring-service/analytics-kernel/build/synced-main', 'scoring-service/analytics-kernel/build/synced-test',
]);

// Preserve offsets/newlines while masking comments and literals, including nested Kotlin comments.
function codeOnly(source) {
  const chars = source.split('');
  let i = 0;
  const erase = end => { for (; i < end; i++) if (chars[i] !== '\n') chars[i] = ' '; };
  while (i < source.length) {
    if (source.startsWith('//', i)) { const end = source.indexOf('\n', i); erase(end < 0 ? source.length : end); }
    else if (source.startsWith('/*', i)) {
      let depth = 1, end = i + 2;
      while (end < source.length && depth) {
        if (source.startsWith('/*', end)) { depth++; end += 2; }
        else if (source.startsWith('*/', end)) { depth--; end += 2; }
        else end++;
      }
      requireThat(depth === 0, 'unterminated Kotlin comment'); erase(end);
    } else if (source.startsWith('"""', i)) {
      const end = source.indexOf('"""', i + 3);
      requireThat(end >= 0, 'unterminated Kotlin raw string'); erase(end + 3);
    } else if (source[i] === '"' || source[i] === "'") {
      const quote = source[i]; let end = i + 1;
      while (end < source.length && source[end] !== quote) end += source[end] === '\\' ? 2 : 1;
      requireThat(end < source.length, 'unterminated Kotlin literal'); erase(end + 1);
    } else i++;
  }
  return chars.join('');
}

export function checkKotlin(source, relative) {
  const code = codeOnly(source);
  const withoutImports = code.replace(/\bimport\s+([^\n;]+);?/g, (statement, body, offset) => {
    const normalized = body.replace(/`([A-Za-z_][\w]*)`/g, '$1').replace(/\s*\.\s*/g, '.').trim();
    const match = /^([\w.]+(?:\.\*)?)(?:\s+as\s+[A-Za-z_]\w*)?$/.exec(normalized);
    const line = code.slice(0, offset).split('\n').length;
    requireThat(match, `unsupported import syntax at ${relative}:${line}`);
    const name = match[1];
    const forbidden = /^(android|androidx|com\.noop\.ingest)(\.|$)/.test(name) ||
      (/^com\.noop\.data(\.|$)/.test(name) && !PURE_DATA_SYMBOLS.some(symbol => name === `com.noop.data.${symbol}`));
    requireThat(!forbidden, `forbidden import at ${relative}:${line}`);
    return statement.replace(/[^\n]/g, ' ');
  });
  // No directory-wide exemptions. Only the existing exact JVM SharedPreferences.Editor references.
  const shimUsers = new Set([
    'scoring-service/analytics-kernel/build/synced-main/com/noop/analytics/Baselines.kt',
    'scoring-service/analytics-kernel/build/synced-test/com/noop/analytics/HrvBaselineRecalibrationTest.kt',
  ]);
  const references = withoutImports.replace(/^\s*package\s+[\w.]+\s*;?/gm, '');
  for (const match of references.matchAll(/\b(?:androidx?|com\.noop\.(?:data|ingest))\.[\w.]+/g)) {
    const name = match[0];
    const allowed = PURE_DATA_SYMBOLS.some(symbol => name === `com.noop.data.${symbol}` || name.startsWith(`com.noop.data.${symbol}.`)) ||
      (name === 'android.content.SharedPreferences.Editor' && shimUsers.has(relative));
    requireThat(allowed, `forbidden qualified reference in ${relative}`);
  }
}

function readableFile(filename) {
  const stat = fs.lstatSync(filename);
  requireThat(stat.isFile() && (stat.mode & 0o444) !== 0 && stat.size > 0, 'required source must be a readable nonempty regular file');
  fs.accessSync(filename, fs.constants.R_OK);
}
export function checkMigrations(root) {
  const directory = path.join(root, 'supabase/migrations');
  const names = fs.readdirSync(directory);
  for (const id of REQUIRED_MIGRATIONS) {
    const matches = names.filter(name => name.startsWith(`${id}_`) && name.endsWith('.sql'));
    requireThat(matches.length === 1, `exactly one source migration required: ${id}`);
    const filename = path.join(directory, matches[0]);
    readableFile(filename);
    requireThat(fs.readFileSync(filename, 'utf8').trim().length > 0, `empty source migration: ${id}`);
  }
  const base = path.join(directory, '20260916160000_scoring_service_state.sql');
  readableFile(base);
  const text = fs.readFileSync(base, 'utf8');
  for (const symbol of ['scoring_service_heartbeats', 'scoring_work_items', 'engine_ingest_scored']) {
    requireThat(text.includes(symbol), `base migration missing ${symbol}`);
  }
  return REQUIRED_MIGRATIONS.length;
}
export function checkSources(root) {
  let count = 0;
  function scan(directory) {
    let found = 0;
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const filename = path.join(directory, entry.name);
      requireThat(!entry.isSymbolicLink(), 'source symlinks are not supported');
      if (entry.isDirectory()) found += scan(filename);
      else if (entry.name.endsWith('.kt')) {
        readableFile(filename);
        checkKotlin(fs.readFileSync(filename, 'utf8'), path.relative(root, filename).split(path.sep).join('/'));
        found++;
      }
    }
    return found;
  }
  for (const relative of SOURCE_ROOTS) {
    const directory = path.join(root, relative);
    requireThat(fs.lstatSync(directory).isDirectory(), `missing source root: ${relative}`);
    const found = scan(directory);
    requireThat(found > 0, `empty source root: ${relative}`);
    count += found;
  }
  return { status: 'SOURCE_CHECKS_PASSED', kotlinFiles: count, requiredMigrations: checkMigrations(root) };
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { requireThat(process.argv.length === 3, 'provide repository root'); console.log(JSON.stringify(checkSources(path.resolve(process.argv[2])))); }
  catch (error) { reportError(error); }
}
