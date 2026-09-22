import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { root, evidenceDefault, hash, sourceSnapshot, validateCommand, validateOutput } from './evidence.mjs';

const args = process.argv.slice(2), separator = args.indexOf('--');
assert(separator > 0, 'Usage: node Tools/compute/record-gate.mjs --gate NAME [--evidence-dir DIR] [--cwd DIR] -- COMMAND ARGS...');
const options = args.slice(0, separator), command = args.slice(separator + 1);
const option = (key) => options.includes(key) ? options[options.indexOf(key) + 1] : undefined;
const gate = option('--gate');
validateCommand(gate, command);
const directory = path.resolve(root, option('--evidence-dir') ?? process.env.COMPUTE_EVIDENCE_DIR ?? evidenceDefault);
const cwd = path.resolve(root, option('--cwd') ?? '.');
assert(cwd === root || cwd.startsWith(root + path.sep), 'Gate cwd must belong to this checkout');
const before = sourceSnapshot();
assert(before.source_clean, `Commit source before recording evidence: ${before.dirty_source_paths.join(', ')}`);
fs.mkdirSync(directory, { recursive: true });
const logPath = path.join(directory, `${gate}.log`);
const log = fs.createWriteStream(logPath, { flags: 'w' });
const started = new Date().toISOString();
const child = spawn(command[0], command.slice(1), { cwd, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
for (const stream of [child.stdout, child.stderr]) stream.on('data', (data) => { process.stdout.write(data); log.write(data); });
let spawnError;
child.on('error', (error) => { spawnError = error.message; });
const exitCode = await new Promise((resolve) => child.on('close', resolve));
await new Promise((resolve) => log.end(resolve));
const after = sourceSnapshot(), bytes = fs.readFileSync(logPath);
let failure = spawnError;
try {
  assert.equal(exitCode, 0, 'Gate command failed');
  assert.equal(after.source_content_sha256, before.source_content_sha256, 'Source changed during gate');
  assert(after.source_clean, 'Source became dirty during gate');
  validateOutput(gate, bytes.toString('utf8'));
} catch (error) { failure = error.message; }
const receipt = { schema_version: 1, gate, status: failure ? 'FAIL' : 'PASS', command,
  cwd: path.relative(root, cwd) || '.', started_at: started, finished_at: new Date().toISOString(),
  source_before: before, source_after: after, exit_code: exitCode, failure: failure ?? null,
  log_path: path.basename(logPath), log_sha256: hash(bytes) };
fs.writeFileSync(path.join(directory, `${gate}.json`), JSON.stringify(receipt, null, 2) + '\n');
console.log(JSON.stringify({ gate, status: receipt.status, receipt: path.join(directory, `${gate}.json`), failure: receipt.failure }));
if (failure) process.exitCode = 1;
