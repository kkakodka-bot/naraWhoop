import assert from 'node:assert/strict';
import test from 'node:test';

import {
  COMPUTE_FAMILY_NAMES,
  HOSTED_PROJECT_REF,
  verifyHostedScoreRouteParity,
} from './verify-hosted-score-route-parity.mjs';

const bundleSha256 = 'a'.repeat(64);
const sourceCommit = 'b'.repeat(40);
const projectUrl = `https://${HOSTED_PROJECT_REF}.supabase.co`;
const canonicalDeviceId = '33333333-3333-4333-8333-333333333333';
const environment = {
  FRWHOOP_HOSTED_ACCOUNT_JWT: 'header.payload.signature',
  FRWHOOP_HOSTED_ANON_KEY: 'protected-anon-key',
  FRWHOOP_HOSTED_ENROLLMENT_TOKEN: 'noop_installation-secret',
  FRWHOOP_HOSTED_FLEET_TOKEN: 'noop_fleet-secret',
  FRWHOOP_HOSTED_USER_ID: '11111111-1111-4111-8111-111111111111',
  FRWHOOP_HOSTED_SOURCE_ID: '22222222-2222-4222-8222-222222222222',
  FRWHOOP_HOSTED_DEVICE_ID: 'whoop-test-strap',
  FRWHOOP_HOSTED_DAY: '2026-09-22',
};

function family(name, deviceId = canonicalDeviceId) {
  const metric = `${name}_metric`;
  return {
    owner: 'server',
    metrics: [metric],
    status: 'unqualified',
    reason: 'selected_result_required',
    result_revision: null,
    input_revision: null,
    algorithm_version: 'vps-only-1',
    selected_algorithm_version: null,
    configuration_version: 'vps-only-1',
    model_version: null,
    preprocessing_version: null,
    quality_version: null,
    manifest_hash: null,
    feature_manifest_hash: null,
    canonical_qualification: null,
    owner_id: environment.FRWHOOP_HOSTED_USER_ID,
    source_id: environment.FRWHOOP_HOSTED_SOURCE_ID,
    device_id: deviceId,
    project: projectUrl,
    window: environment.FRWHOOP_HOSTED_DAY,
    timezone_id: null,
    computed_at: null,
    observed_through: null,
    freshness: 'unavailable',
    expires_at: null,
    decision_id: null,
    values: { [metric]: null },
    details: {},
  };
}

function envelope(identityOverrides = {}, pending = false) {
  const deviceId = pending ? null : canonicalDeviceId;
  return {
    server_scoring: {
      schema_version: 2,
      contract_revision: 2,
      user_id: environment.FRWHOOP_HOSTED_USER_ID,
      day: environment.FRWHOOP_HOSTED_DAY,
      algorithm_version: 'per_feature',
      daily: pending ? null : {},
      nights: [],
      measurements: [],
      sleep_overrides: [],
      computed_at: null,
      stale: true,
      features: {
        sleep: { status: 'unavailable', reason: 'selected_result_required' },
        hrv: { status: 'unavailable', reason: 'selected_result_required' },
        respiration: { status: 'unavailable', reason: 'selected_result_required' },
      },
      compute: {
        mode: 'final_hosted',
        policy_version: 'vps-only-1',
        owner_id: environment.FRWHOOP_HOSTED_USER_ID,
        source_id: environment.FRWHOOP_HOSTED_SOURCE_ID,
        device_id: deviceId,
        project: projectUrl,
        day: environment.FRWHOOP_HOSTED_DAY,
        families: Object.fromEntries(COMPUTE_FAMILY_NAMES.map((name) => [name, family(name, deviceId)])),
      },
    },
    identity: {
      userId: environment.FRWHOOP_HOSTED_USER_ID,
      sourceId: environment.FRWHOOP_HOSTED_SOURCE_ID,
      deviceId,
      externalDeviceId: environment.FRWHOOP_HOSTED_DEVICE_ID,
      project: projectUrl,
      ...identityOverrides,
    },
  };
}

function response(value, status = 200, cacheControl = 'private, no-store') {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': cacheControl },
  });
}

function verify(fetchImpl, overrides = {}) {
  return verifyHostedScoreRouteParity({
    projectRef: HOSTED_PROJECT_REF,
    bundleSha256,
    sourceCommit,
    environment,
    fetchImpl,
    ...overrides,
  });
}

test('compares production account and enrollment score envelopes', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return response(envelope());
  };
  const result = await verify(fetchImpl);
  assert.equal(result.status, 'PASS');
  assert.equal(result.account.responseEnvelopeSha256, result.enrollment.responseEnvelopeSha256);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].url, `${projectUrl}/functions/v1/scores?day=2026-09-22&deviceId=whoop-test-strap`);
  assert.equal(calls[0].options.headers.authorization, `Bearer ${environment.FRWHOOP_HOSTED_ACCOUNT_JWT}`);
  assert.equal(calls[0].options.headers['x-noop-source-id'], environment.FRWHOOP_HOSTED_SOURCE_ID);
  assert.equal(calls[1].options.headers.authorization, `Bearer ${environment.FRWHOOP_HOSTED_ENROLLMENT_TOKEN}`);
  assert.equal(calls[1].options.headers['x-noop-fleet-token'], environment.FRWHOOP_HOSTED_FLEET_TOKEN);
});

test('accepts the explicit pending-device contract without inventing revisions or values', async () => {
  const result = await verify(async () => response(envelope({}, true)));
  assert.equal(result.status, 'PASS');
});

test('rejects different account and enrollment envelopes including valid-zero changes', async () => {
  let call = 0;
  await assert.rejects(() => verify(async () => {
    call += 1;
    const value = envelope();
    if (call === 2) {
      const recovery = value.server_scoring.compute.families.recovery;
      recovery.canonical_qualification = 'signed_reference_approval';
      recovery.result_revision = `sha256:${'c'.repeat(64)}`;
      recovery.manifest_hash = 'd'.repeat(64);
      recovery.feature_manifest_hash = 'e'.repeat(64);
      recovery.values.recovery_metric = 0;
    }
    return response(value);
  }), /account and enrollment score response envelopes differ/);
});

test('rejects owner/source/device/project identity mismatch', async () => {
  await assert.rejects(() => verify(async () => response(envelope({
    sourceId: '44444444-4444-4444-8444-444444444444',
  }))), /different owner\/source\/device\/project identity/);
});

test('rejects malformed final-hosted family contracts before parity comparison', async () => {
  const mutations = [
    (value) => { value.server_scoring.contract_revision = 1; },
    (value) => { value.server_scoring.compute.mode = 'hybrid'; },
    (value) => { delete value.server_scoring.compute.families.recovery; },
    (value) => { value.server_scoring.compute.families.recovery.source_id = '44444444-4444-4444-8444-444444444444'; },
    (value) => { value.server_scoring.compute.families.recovery.result_revision = 'snapshot:1'; },
    (value) => { value.server_scoring.compute.families.recovery.values.recovery_metric = 1; },
  ];
  for (const mutate of mutations) {
    const value = envelope();
    mutate(value);
    await assert.rejects(() => verify(async () => response(value)), /contract|scope|revision|qualification/i);
  }
});

test('rejects non-200, non-JSON and cacheable route responses without exposing credentials', async () => {
  for (const fetchImpl of [
    async () => response({ error: 'unauthorized' }, 401),
    async () => response(envelope(), 200, 'public, max-age=60'),
    async () => new Response('{}', { status: 200, headers: {
      'content-type': 'text/plain', 'cache-control': 'no-store',
    } }),
  ]) {
    let message = '';
    try {
      await verify(fetchImpl);
      assert.fail('expected route rejection');
    } catch (error) {
      message = error.message;
    }
    for (const credential of [
      environment.FRWHOOP_HOSTED_ACCOUNT_JWT,
      environment.FRWHOOP_HOSTED_ANON_KEY,
      environment.FRWHOOP_HOSTED_ENROLLMENT_TOKEN,
      environment.FRWHOOP_HOSTED_FLEET_TOKEN,
    ]) assert.equal(message.includes(credential), false);
  }
});

test('aborts a streaming response as soon as it exceeds two MiB', async () => {
  let cancelled = false;
  let aborted = false;
  const body = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array(2 * 1024 * 1024));
      controller.enqueue(new Uint8Array([1]));
    },
    cancel() { cancelled = true; },
  });
  await assert.rejects(() => verify(async (_url, options) => {
    options.signal.addEventListener('abort', () => { aborted = true; }, { once: true });
    return new Response(body, { headers: {
      'content-type': 'application/json', 'cache-control': 'no-store',
    } });
  }), /outside the reviewed bound/);
  assert.equal(aborted, true);
  assert.equal(cancelled, true);
});

test('keeps the timeout active while consuming the response body', async () => {
  await assert.rejects(() => verify(async (_url, options) => new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('{'));
      options.signal.addEventListener('abort', () => controller.error(new Error('aborted')), { once: true });
    },
  }), { headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } }), {
    timeoutMs: 1_000,
  }), /response body read failed/);
});

test('rejects any project other than the exact hosted project before fetch', async () => {
  let fetched = false;
  await assert.rejects(() => verifyHostedScoreRouteParity({
    projectRef: 'wrongprojectref000000',
    bundleSha256,
    sourceCommit,
    environment,
    fetchImpl: async () => { fetched = true; return response(envelope()); },
  }), /project ref must be exactly/);
  assert.equal(fetched, false);
});
