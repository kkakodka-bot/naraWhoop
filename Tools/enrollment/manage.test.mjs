import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import test from 'node:test';

import {
  generateEnrollmentCode,
  hashEnrollmentCode,
  hashOpaqueToken,
  main,
  normalizeEnrollmentCode,
} from './manage.mjs';

test('generateEnrollmentCode emits a 100-bit human-readable payload', () => {
  const code = generateEnrollmentCode(() => Uint8Array.from({ length: 20 }, (_, index) => index));
  assert.equal(code, 'NARA-0123-4567-89AB-CDEF-GHJK');
  assert.equal(normalizeEnrollmentCode(code), 'NARA0123456789ABCDEFGHJK');
});

test('normalization accepts case, spacing, and unambiguous aliases', () => {
  assert.equal(
    normalizeEnrollmentCode(' nara-o123 i567 89ab cdef ghjk '),
    'NARA0123156789ABCDEFGHJK',
  );
});

test('normalization rejects malformed or short codes', () => {
  assert.throws(() => normalizeEnrollmentCode('OTHER-0123-4567-89AB-CDEF-GHJK'), /invalid/);
  assert.throws(() => normalizeEnrollmentCode('NARA-0123'), /invalid/);
  assert.throws(() => normalizeEnrollmentCode('NARA-0123-4567-89AB-CDEF-GHJU'), /invalid/);
  assert.throws(() => normalizeEnrollmentCode('NARA\u00a00123-4567-89AB-CDEF-GHJK'), /invalid/);
});

test('hashEnrollmentCode hashes only the canonical representation', () => {
  const pepper = '0123456789abcdef0123456789abcdef';
  const expected = createHmac('sha256', pepper)
    .update('NARA0123456789ABCDEFGHJK', 'utf8')
    .digest('hex');
  assert.equal(hashEnrollmentCode('nara-0123-4567-89ab-cdef-ghjk', pepper), expected);
  assert.equal(hashEnrollmentCode(' NARA 0123 4567 89AB CDEF GHJK ', pepper), expected);
  assert.throws(() => hashEnrollmentCode('NARA-0123-4567-89AB-CDEF-GHJK', 'short'), /32 bytes/);
  assert.throws(() => hashEnrollmentCode('NARA-0123-4567-89AB-CDEF-GHJK', ` ${pepper}`), /whitespace/);
});

test('opaque token hashes are stable without exposing plaintext', () => {
  assert.equal(
    hashOpaqueToken('noop_example'),
    'bbd3b668e94d97f86db3c75e07ab5c33cd5bb2c6b573895795772784983b8fb0',
  );
});

const operatorEnv = {
  SUPABASE_URL: 'https://enrollment.example.invalid',
  SUPABASE_SERVICE_ROLE_KEY: 'test-service-role-key',
  NOOP_ENROLLMENT_PEPPER: '0123456789abcdef0123456789abcdef',
};
const testerId = '3ab0c13e-842f-4d22-b25c-4ef9c730897d';

test('create-tester validates enrollment inputs before any admin request', async (t) => {
  const cases = [
    { name: 'missing pepper', env: { NOOP_ENROLLMENT_PEPPER: '' }, error: /32 bytes/ },
    { name: 'short pepper', env: { NOOP_ENROLLMENT_PEPPER: 'short' }, error: /32 bytes/ },
    { name: 'leading pepper whitespace', env: { NOOP_ENROLLMENT_PEPPER: ` ${operatorEnv.NOOP_ENROLLMENT_PEPPER}` }, error: /whitespace/ },
    { name: 'trailing pepper newline', env: { NOOP_ENROLLMENT_PEPPER: `${operatorEnv.NOOP_ENROLLMENT_PEPPER}\n` }, error: /whitespace/ },
    { name: 'zero expiry', options: ['--expires-hours', '0'], error: /expires-hours/ },
    { name: 'negative expiry', options: ['--expires-hours', '-1'], error: /expires-hours/ },
    { name: 'excessive expiry', options: ['--expires-hours', '721'], error: /expires-hours/ },
    { name: 'invalid expiry', options: ['--expires-hours', 'tomorrow'], error: /expires-hours/ },
    { name: 'infinite expiry', options: ['--expires-hours', 'Infinity'], error: /expires-hours/ },
    { name: 'blank tester label', options: ['--label', ' '], error: /--label/ },
    { name: 'long tester label', options: ['--label', 'x'.repeat(121)], error: /--label/ },
    { name: 'blank code label', options: ['--code-label', ' '], error: /--code-label/ },
    { name: 'long code label', options: ['--code-label', 'x'.repeat(121)], error: /--code-label/ },
    { name: 'malformed email', options: ['--email', 'invalid'], error: /--email/ },
    { name: 'email containing newline', options: ['--email', 'tester\n@example.com'], error: /--email/ },
  ];
  for (const entry of cases) {
    await t.test(entry.name, async (t) => {
      const adminFetch = t.mock.method(globalThis, 'fetch', async () => {
        throw new Error('unexpected admin request');
      });
      await assert.rejects(
        main(['create-tester', '--label', 'Tester 01', ...(entry.options || [])], { ...operatorEnv, ...entry.env }),
        entry.error,
      );
      assert.equal(adminFetch.mock.callCount(), 0);
    });
  }
});

test('issue-code rejects a mismatched pepper before looking up the tester', async (t) => {
  const adminFetch = t.mock.method(globalThis, 'fetch', async () => {
    throw new Error('unexpected admin request');
  });
  await assert.rejects(
    main(['issue-code', '--user-id', testerId, '--label', 'replacement'], {
      ...operatorEnv,
      NOOP_ENROLLMENT_PEPPER: `${operatorEnv.NOOP_ENROLLMENT_PEPPER}\n`,
    }),
    /whitespace/,
  );
  assert.equal(adminFetch.mock.callCount(), 0);
});

test('create-tester uses validated enrollment settings when creating the first code', async (t) => {
  const requests = [];
  const output = t.mock.method(console, 'log', () => {});
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    const path = new URL(url).pathname;
    const body = options.body ? JSON.parse(options.body) : null;
    requests.push({ path, method: options.method, body });
    if (path === '/auth/v1/admin/users' && options.method === 'POST') {
      return Response.json({ id: testerId, email: body.email });
    }
    if (path === `/auth/v1/admin/users/${testerId}` && options.method === 'GET') {
      return Response.json({ id: testerId });
    }
    if (path === '/rest/v1/noop_enrollment_codes' && options.method === 'POST') {
      return Response.json([{ id: 'test-code-id', user_id: testerId, expires_at: body.expires_at }]);
    }
    throw new Error('unexpected admin request');
  });
  const before = Date.now();
  assert.equal(await main([
    'create-tester', '--label', ' Tester 01 ', '--code-label', ' first iPhone ',
    '--email', ' tester@example.com ', '--expires-hours', '24',
  ], operatorEnv), 0);
  const after = Date.now();
  assert.equal(requests.length, 3);
  assert.equal(requests[0].body.email, 'tester@example.com');
  assert.equal(requests[0].body.user_metadata.tester_label, 'Tester 01');
  assert.equal(requests[2].body.label, 'first iPhone');
  const expiresAt = Date.parse(requests[2].body.expires_at);
  assert.ok(expiresAt >= before + 24 * 60 * 60 * 1000);
  assert.ok(expiresAt <= after + 24 * 60 * 60 * 1000);
  assert.equal(output.mock.callCount(), 1);
  const result = JSON.parse(output.mock.calls[0].arguments[0]);
  assert.equal(result.userId, testerId);
  assert.equal(requests[2].body.code_hash, hashEnrollmentCode(result.enrollmentCode, operatorEnv.NOOP_ENROLLMENT_PEPPER));
});
