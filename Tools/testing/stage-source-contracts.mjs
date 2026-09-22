#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(import.meta.url);
export function stageSourceContracts(repository, resourcesDirectory) {
  const root = fs.realpathSync(repository);
  const resources = path.resolve(resourcesDirectory);
  // Only our generated namespace is written. Existing user/build resources are untouched.
  fs.mkdirSync(resources, { recursive: true });
  const destination = path.join(resources, 'SourceContracts');
  if (fs.existsSync(destination) && fs.lstatSync(destination).isSymbolicLink()) throw new Error('SourceContracts must not be a symlink');
  fs.mkdirSync(destination, { recursive: true });
  const inputs = JSON.parse(fs.readFileSync(path.join(root, 'Tools/testing/source-contract-inputs.json'), 'utf8'));
  const git = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' });
  if (git.status !== 0) throw new Error('Source revision unavailable');
  const files = {};
  const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
  for (const relative of inputs) {
    if (path.isAbsolute(relative) || relative.split('/').includes('..')) throw new Error(`Invalid source path: ${relative}`);
    const source = fs.realpathSync(path.join(root, relative));
    if (!source.startsWith(root + path.sep) || !fs.statSync(source).isFile()) throw new Error(`Source escapes repository: ${relative}`);
    const bytes = fs.readFileSync(source), output = path.join(destination, relative);
    fs.mkdirSync(path.dirname(output), { recursive: true });
    // A fresh build always overwrites from actual current source; no recorded golden source copies.
    fs.writeFileSync(output, bytes);
    const sha256 = digest(bytes);
    if (digest(fs.readFileSync(output)) !== sha256) throw new Error(`Copy verification failed: ${relative}`);
    files[relative] = { sha256, bytes: bytes.length };
  }
  const manifest = { schema_version: 1, source_revision: git.stdout.trim(), files };
  fs.writeFileSync(path.join(destination, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  return { destination, ...manifest };
}

if (process.argv[1] && path.resolve(process.argv[1]) === script) {
  if (process.argv.length !== 4) throw new Error('usage: stage-source-contracts.mjs REPOSITORY TEST_BUNDLE_RESOURCES');
  const result = stageSourceContracts(process.argv[2], process.argv[3]);
  console.log(`Staged ${Object.keys(result.files).length} exact source contracts at ${result.source_revision}: ${result.destination}`);
}
