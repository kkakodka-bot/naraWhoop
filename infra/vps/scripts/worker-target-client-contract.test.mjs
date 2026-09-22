import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';


const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const source = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const deploy = source('infra/vps/scripts/deploy-scoring-service.sh');
const progress = source('infra/vps/scripts/scoring-progress.sh');
const hostedQuery = source('infra/vps/scripts/scoring-hosted-query.py');
const runtimeVerifier = source('infra/vps/scripts/remote/verify-scoring-runtime.sh');
const phase3 = source('infra/vps/scripts/phase3-acceptance-checks.sh');
const exactClient = 'docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3';


test('deployment target comes only from the verified plan and exact private known_hosts', () => {
  assert.doesNotMatch(deploy, /read-deploy-target|droplet\.env/);
  for (const field of ['target.ip', 'target.sshPort', 'target.sshHostPublicKey.line',
    'target.sshHostPublicKey.fingerprint', 'target.deployPublicKeyFingerprint']) {
    assert.match(deploy, new RegExp(field.replaceAll('.', '\\.')));
  }
  assert.match(deploy, /ssh-keygen -y -f "\$SSH_KEY"/);
  assert.match(deploy, /OBSERVED_DEPLOY_PUBLIC_KEY_FINGERPRINT.*DEPLOY_PUBLIC_KEY_FINGERPRINT/s);
  assert.match(deploy, /chmod 600 "\$KNOWN_HOSTS"/);
  assert.match(deploy, /UserKnownHostsFile=\$KNOWN_HOSTS/);
  assert.match(deploy, /GlobalKnownHostsFile=\/dev\/null/);
  assert.ok(deploy.indexOf('OBSERVED_TOKEN="$(ssh') < deploy.indexOf('mkdir "$lock"'));
  assert.ok(deploy.indexOf('observed-target.json') < deploy.indexOf('mkdir "$lock"'));
});


test('PostgreSQL client descriptors are verified before hosted secrets and every query uses the digest', () => {
  assert.match(deploy, new RegExp(exactClient.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(deploy, /docker pull --platform "\$SCORING_POSTGRES_CLIENT_PLATFORM"/);
  assert.match(deploy, /docker image save -o "\$archive"/);
  assert.match(deploy, /verify-pinned-postgres-client\.py/);
  assert.ok(deploy.indexOf('\nverify_postgres_client\n') < deploy.indexOf('\nsource "$SECRETS"'));
  for (const runtime of [progress, hostedQuery]) {
    assert.match(runtime, new RegExp(exactClient.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
    assert.doesNotMatch(runtime, /postgres:17(?:-alpine)?/);
    assert.match(runtime, /SCORING_POSTGRES_CLIENT_IMAGE/);
  }
  for (const consumer of [runtimeVerifier, phase3]) {
    assert.match(consumer, /source \/opt\/frwhoop\/scoring-client\.env/);
    assert.match(consumer, /scoring_client_identity_valid/);
  }
});
