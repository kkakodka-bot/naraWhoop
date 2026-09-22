#!/usr/bin/env node

import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const PARITY_CONTRACT = Object.freeze({
  kind: 'frwhoop-hosted-score-route-parity',
  schemaVersion: 1,
});
export const HOSTED_PROJECT_REF = 'sgoyxzcagqyxexmsidtk';
export const COMPUTE_FAMILY_NAMES = Object.freeze([
  'baselines',
  'biofeedback',
  'circadian',
  'current_hrv',
  'cycle',
  'fitness_longevity',
  'illness',
  'insights',
  'intraday_temperature',
  'live_coaching',
  'live_hr_selection',
  'live_workout',
  'night_hrv',
  'oxygen',
  'ppg_hr',
  'readiness_load',
  'recovery',
  'respiration',
  'sleep',
  'sleep_history',
  'spot_hrv',
  'steps',
  'strain_energy',
  'stress',
  'stress_events',
  'temperature',
  'workouts',
]);

const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
const FAMILY_REQUIRED_FIELDS = Object.freeze([
  'owner', 'metrics', 'status', 'reason', 'result_revision', 'input_revision',
  'algorithm_version', 'configuration_version', 'model_version', 'preprocessing_version',
  'quality_version', 'manifest_hash', 'feature_manifest_hash', 'canonical_qualification',
  'owner_id', 'source_id', 'device_id', 'project', 'window', 'timezone_id',
  'computed_at', 'observed_through', 'freshness', 'expires_at', 'decision_id', 'values', 'details',
]);

class ParityError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function fail(code, message) {
  throw new ParityError(code, message);
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function isUuid(value) {
  return typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function isExternalDevice(value) {
  if (typeof value !== 'string' || !/^[\x20-\x7e]{1,255}$/.test(value)) return false;
  if (value.includes('@') || /^\+?\d{7,}$/.test(value.replace(/[\s-]/g, ''))) return false;
  return true;
}

function validDay(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function hasOwnFields(value, fields) {
  return isObject(value) && fields.every((field) => Object.hasOwn(value, field));
}

function validNullableTimestamp(value) {
  return value === null || (typeof value === 'string' && Number.isFinite(Date.parse(value)));
}

function validNullableSha256(value) {
  return value === null || (typeof value === 'string' && /^[0-9a-f]{64}$/.test(value));
}

function requiredEnvironment(environment) {
  const names = [
    'FRWHOOP_HOSTED_ACCOUNT_JWT',
    'FRWHOOP_HOSTED_ANON_KEY',
    'FRWHOOP_HOSTED_ENROLLMENT_TOKEN',
    'FRWHOOP_HOSTED_FLEET_TOKEN',
    'FRWHOOP_HOSTED_USER_ID',
    'FRWHOOP_HOSTED_SOURCE_ID',
    'FRWHOOP_HOSTED_DEVICE_ID',
    'FRWHOOP_HOSTED_DAY',
  ];
  const values = {};
  for (const name of names) {
    if (typeof environment[name] !== 'string' || environment[name].length === 0) {
      fail('CONFIGURATION_MISSING', `required protected environment value is missing: ${name}`);
    }
    values[name] = environment[name];
  }
  if (values.FRWHOOP_HOSTED_ACCOUNT_JWT.split('.').length !== 3) {
    fail('CONFIGURATION_INVALID', 'account credential is not JWT-shaped');
  }
  if (!values.FRWHOOP_HOSTED_ENROLLMENT_TOKEN.startsWith('noop_') ||
      !values.FRWHOOP_HOSTED_FLEET_TOKEN.startsWith('noop_')) {
    fail('CONFIGURATION_INVALID', 'installation or fleet credential shape differs');
  }
  if (!isUuid(values.FRWHOOP_HOSTED_USER_ID) || !isUuid(values.FRWHOOP_HOSTED_SOURCE_ID)) {
    fail('CONFIGURATION_INVALID', 'expected owner/source identity is not a UUID');
  }
  if (!isExternalDevice(values.FRWHOOP_HOSTED_DEVICE_ID) || !validDay(values.FRWHOOP_HOSTED_DAY)) {
    fail('CONFIGURATION_INVALID', 'device/day selection is invalid');
  }
  return values;
}

async function boundedJsonResponse(response, lane, abortController) {
  if (!response || response.status !== 200) fail('ROUTE_FAILED', `${lane} score route did not return HTTP 200`);
  const cacheControl = response.headers?.get?.('cache-control') ?? '';
  if (!/(?:^|,)\s*no-store\s*(?:,|$)/i.test(cacheControl)) {
    fail('ROUTE_FAILED', `${lane} score route omitted cache-control no-store`);
  }
  const contentType = response.headers?.get?.('content-type') ?? '';
  if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
    fail('ROUTE_FAILED', `${lane} score route did not return application/json`);
  }
  if (!response.body?.getReader) fail('ROUTE_FAILED', `${lane} score route omitted a response body`);
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array)) fail('ROUTE_FAILED', `${lane} score route returned invalid body bytes`);
      total += value.byteLength;
      if (total > MAX_RESPONSE_BYTES) {
        abortController.abort();
        await reader.cancel().catch(() => {});
        fail('ROUTE_FAILED', `${lane} score response size is outside the reviewed bound`);
      }
      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof ParityError) throw error;
    fail('ROUTE_FAILED', `${lane} score response body read failed`);
  } finally {
    reader.releaseLock();
  }
  if (total === 0) {
    fail('ROUTE_FAILED', `${lane} score response size is outside the reviewed bound`);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch {
    fail('ROUTE_FAILED', `${lane} score route did not return JSON`);
  }
}

function verifyIdentity(envelope, expected, lane) {
  const identity = envelope?.identity;
  if (!identity || identity.userId !== expected.userId || identity.sourceId !== expected.sourceId ||
      identity.externalDeviceId !== expected.deviceId || identity.project !== expected.projectUrl) {
    fail('IDENTITY_MISMATCH', `${lane} score route returned a different owner/source/device/project identity`);
  }
  if (identity.deviceId !== null && !isUuid(identity.deviceId)) {
    fail('IDENTITY_MISMATCH', `${lane} score route returned an invalid canonical device identity`);
  }
  return identity;
}

function verifyFamily(familyName, family, expected, pending, lane) {
  if (!hasOwnFields(family, FAMILY_REQUIRED_FIELDS)) {
    fail('CONTRACT_MISMATCH', `${lane} ${familyName} family omits required result fields`);
  }
  if (family.owner !== 'server' || family.owner_id !== expected.userId ||
      family.source_id !== expected.sourceId || family.device_id !== expected.canonicalDeviceId ||
      family.project !== expected.projectUrl || family.window !== expected.day) {
    fail('CONTRACT_MISMATCH', `${lane} ${familyName} family scope differs from the requested route identity`);
  }
  if (!Array.isArray(family.metrics) || family.metrics.length === 0 ||
      family.metrics.some((metric) => typeof metric !== 'string' || metric.length === 0) ||
      new Set(family.metrics).size !== family.metrics.length || !isObject(family.values) ||
      JSON.stringify(Object.keys(family.values).sort()) !== JSON.stringify([...family.metrics].sort())) {
    fail('CONTRACT_MISMATCH', `${lane} ${familyName} family metrics and explicit values differ`);
  }
  if (typeof family.status !== 'string' || family.status.length === 0 ||
      !(family.reason === null || typeof family.reason === 'string') ||
      !(family.input_revision === null || (Number.isSafeInteger(family.input_revision) && family.input_revision >= 0)) ||
      typeof family.algorithm_version !== 'string' || family.algorithm_version.length === 0 ||
      !(family.configuration_version === null || typeof family.configuration_version === 'string') ||
      !(family.canonical_qualification === null || typeof family.canonical_qualification === 'string') ||
      !validNullableSha256(family.manifest_hash) || !validNullableSha256(family.feature_manifest_hash) ||
      !validNullableTimestamp(family.computed_at) || !validNullableTimestamp(family.observed_through) ||
      !validNullableTimestamp(family.expires_at) || typeof family.freshness !== 'string' ||
      !isObject(family.details)) {
    fail('CONTRACT_MISMATCH', `${lane} ${familyName} family result metadata is malformed`);
  }
  if (family.result_revision !== null &&
      (typeof family.result_revision !== 'string' ||
       !/^(?:sha256:[0-9a-f]{64}|compute:[1-9][0-9]*)$/.test(family.result_revision))) {
    fail('CONTRACT_MISMATCH', `${lane} ${familyName} family result revision is not immutable`);
  }
  if (!family.canonical_qualification && Object.values(family.values).some((value) => value !== null)) {
    fail('CONTRACT_MISMATCH', `${lane} ${familyName} publishes values without canonical qualification`);
  }
  if (family.canonical_qualification &&
      (!family.result_revision?.startsWith('sha256:') || family.manifest_hash === null ||
       family.feature_manifest_hash === null)) {
    fail('CONTRACT_MISMATCH', `${lane} ${familyName} qualified result lacks immutable manifest identity`);
  }
  if (pending && (family.result_revision !== null || family.input_revision !== null ||
      Object.values(family.values).some((value) => value !== null))) {
    fail('CONTRACT_MISMATCH', `${lane} ${familyName} pending-device result is not explicitly unavailable`);
  }
}

function verifyProductionEnvelope(envelope, expected, lane) {
  if (!isObject(envelope) || JSON.stringify(Object.keys(envelope).sort()) !==
      JSON.stringify(['identity', 'server_scoring'])) {
    fail('CONTRACT_MISMATCH', `${lane} score route top-level envelope differs from the production contract`);
  }
  const identity = verifyIdentity(envelope, expected, lane);
  const score = envelope.server_scoring;
  if (!isObject(score) || score.schema_version !== 2 || score.contract_revision !== 2 ||
      score.user_id !== expected.userId || score.day !== expected.day ||
      !isObject(score.features) || !(score.daily === null || isObject(score.daily)) ||
      !Array.isArray(score.nights) || !Array.isArray(score.measurements) ||
      !Array.isArray(score.sleep_overrides) || !isObject(score.compute)) {
    fail('CONTRACT_MISMATCH', `${lane} server_scoring body differs from contract revision 2`);
  }
  const pending = identity.deviceId === null;
  const compute = score.compute;
  if (compute.mode !== 'final_hosted' || compute.policy_version !== 'vps-only-1' ||
      compute.owner_id !== expected.userId || compute.source_id !== expected.sourceId ||
      compute.device_id !== identity.deviceId || compute.project !== expected.projectUrl ||
      compute.day !== expected.day || !isObject(compute.families)) {
    fail('CONTRACT_MISMATCH', `${lane} compute scope differs from the final hosted contract`);
  }
  const familyNames = Object.keys(compute.families).sort();
  if (JSON.stringify(familyNames) !== JSON.stringify(COMPUTE_FAMILY_NAMES)) {
    fail('CONTRACT_MISMATCH', `${lane} compute family set differs from the 27-family production contract`);
  }
  const familyExpected = { ...expected, canonicalDeviceId: identity.deviceId };
  for (const familyName of familyNames) {
    verifyFamily(familyName, compute.families[familyName], familyExpected, pending, lane);
  }
  return envelope;
}

export async function verifyHostedScoreRouteParity({
  projectRef,
  bundleSha256,
  sourceCommit,
  environment = process.env,
  fetchImpl = fetch,
  timeoutMs = 30_000,
}) {
  if (projectRef !== HOSTED_PROJECT_REF) fail('PROJECT_MISMATCH', `project ref must be exactly ${HOSTED_PROJECT_REF}`);
  if (!/^[0-9a-f]{64}$/.test(bundleSha256 ?? '') || !/^[0-9a-f]{40}$/.test(sourceCommit ?? '')) {
    fail('ARGUMENT_INVALID', 'bundle/source release identity is invalid');
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1_000 || timeoutMs > 120_000) {
    fail('ARGUMENT_INVALID', 'timeout must be between 1000 and 120000 milliseconds');
  }
  const configuration = requiredEnvironment(environment);
  const projectUrl = `https://${HOSTED_PROJECT_REF}.supabase.co`;
  const query = new URLSearchParams({
    day: configuration.FRWHOOP_HOSTED_DAY,
    deviceId: configuration.FRWHOOP_HOSTED_DEVICE_ID,
  });
  const url = `${projectUrl}/functions/v1/scores?${query.toString()}`;
  const common = {
    apikey: configuration.FRWHOOP_HOSTED_ANON_KEY,
    accept: 'application/json',
    'cache-control': 'no-store',
  };
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const accountResponse = await fetchImpl(url, {
      method: 'GET',
      redirect: 'error',
      signal: controller.signal,
      headers: {
        ...common,
        authorization: `Bearer ${configuration.FRWHOOP_HOSTED_ACCOUNT_JWT}`,
        'x-noop-source-id': configuration.FRWHOOP_HOSTED_SOURCE_ID,
      },
    });
    const account = await boundedJsonResponse(accountResponse, 'account', controller);
    const enrollmentResponse = await fetchImpl(url, {
      method: 'GET',
      redirect: 'error',
      signal: controller.signal,
      headers: {
        ...common,
        authorization: `Bearer ${configuration.FRWHOOP_HOSTED_ENROLLMENT_TOKEN}`,
        'x-noop-fleet-token': configuration.FRWHOOP_HOSTED_FLEET_TOKEN,
      },
    });
    const enrollment = await boundedJsonResponse(enrollmentResponse, 'enrollment', controller);
    const identity = {
      userId: configuration.FRWHOOP_HOSTED_USER_ID,
      sourceId: configuration.FRWHOOP_HOSTED_SOURCE_ID,
      deviceId: configuration.FRWHOOP_HOSTED_DEVICE_ID,
      day: configuration.FRWHOOP_HOSTED_DAY,
      projectUrl,
    };
    verifyProductionEnvelope(account, identity, 'account');
    verifyProductionEnvelope(enrollment, identity, 'enrollment');
    const accountCanonical = canonicalJson(account);
    const enrollmentCanonical = canonicalJson(enrollment);
    const accountHash = sha256(accountCanonical);
    const enrollmentHash = sha256(enrollmentCanonical);
    if (accountHash !== enrollmentHash) fail('PARITY_MISMATCH', 'account and enrollment score response envelopes differ');
    return {
      status: 'PASS',
      projectRef,
      bundleSha256,
      sourceCommit,
      account: { status: 'PASS', responseEnvelopeSha256: accountHash },
      enrollment: { status: 'PASS', responseEnvelopeSha256: enrollmentHash },
      parity: {
        status: 'PASS',
        comparisonSha256: sha256(`${accountHash}\n${enrollmentHash}\n${configuration.FRWHOOP_HOSTED_DAY}\n`),
      },
    };
  } catch (error) {
    if (error instanceof ParityError) throw error;
    fail('ROUTE_FAILED', 'hosted score route request or response body failed');
  } finally {
    clearTimeout(timeout);
  }
}

function parseFlags(args) {
  const allowed = new Set(['--project-ref', '--bundle-sha256', '--source-commit', '--timeout-ms']);
  const values = {};
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (!allowed.has(flag) || value === undefined || value.startsWith('--') || values[flag] !== undefined) {
      fail('ARGUMENT_INVALID', `usage error near ${flag ?? '<end>'}`);
    }
    values[flag] = value;
  }
  return values;
}

async function main(argv) {
  if (argv.length === 1 && argv[0] === '--contract-version') {
    process.stdout.write(`${JSON.stringify(PARITY_CONTRACT)}\n`);
    return;
  }
  const flags = parseFlags(argv);
  for (const required of ['--project-ref', '--bundle-sha256', '--source-commit']) {
    if (!flags[required]) fail('ARGUMENT_INVALID', `${required} is required`);
  }
  const timeoutMs = flags['--timeout-ms'] === undefined ? 30_000 : Number(flags['--timeout-ms']);
  const result = await verifyHostedScoreRouteParity({
    projectRef: flags['--project-ref'],
    bundleSha256: flags['--bundle-sha256'],
    sourceCommit: flags['--source-commit'],
    timeoutMs,
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => {
    const code = error instanceof ParityError ? error.code : 'UNEXPECTED_FAILURE';
    const message = error instanceof ParityError ? error.message : 'unexpected parity verification failure';
    process.stderr.write(`HOSTED_SCORE_PARITY_${code}: ${message}\n`);
    process.exitCode = 1;
  });
}
