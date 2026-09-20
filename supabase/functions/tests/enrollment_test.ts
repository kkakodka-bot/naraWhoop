import { assert, assertEquals, assertRejects, assertThrows } from 'jsr:@std/assert';
import {
  createEnrollmentService,
  deriveInstallationToken,
  EnrollmentError,
  hashEnrollmentCode,
  normalizeEnrollmentCode,
  validateEnrollmentRequest,
} from '../_shared/enrollment.ts';
import { hashIngestToken } from '../_shared/tokens.ts';

const PEPPER = 'test-only-enrollment-pepper-32-bytes-minimum';
const USER = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const TOKEN_ID = '33333333-3333-4333-8333-333333333333';

Deno.test('enrollment: display, case, whitespace, and Crockford aliases share one canonical hash', () => {
  const display = 'NARA-ABCD-EFGH-JKMN-PQRS-TVWX';
  const noisy = ' nara abcd-efgh-jkmn-pqrs-tvwx\n';
  assertEquals(normalizeEnrollmentCode(display), 'NARAABCDEFGHJKMNPQRSTVWX');
  assertEquals(normalizeEnrollmentCode(noisy), normalizeEnrollmentCode(display));
  assertEquals(hashEnrollmentCode(noisy, PEPPER), hashEnrollmentCode(display, PEPPER));

  const canonicalDigits = 'NARA01AA01AA01AA01AA01AA';
  const aliases = 'NARAOIAAOLAAOIAAOLAAOIAA';
  assertEquals(normalizeEnrollmentCode(aliases), canonicalDigits);
  assertEquals(hashEnrollmentCode(aliases, PEPPER), hashEnrollmentCode(canonicalDigits, PEPPER));
});

Deno.test('enrollment: malformed, ambiguous-U, short, and non-ASCII separator codes are rejected', () => {
  for (const value of [
    'NARA-ABCD-EFGH-JKMN-PQRS-TUVX',
    'NARA-ABCD',
    'NARA-ABCD-EFGH-JKMN-PQRS-TVW!',
    'NARA\u00a0ABCD-EFGH-JKMN-PQRS-TVWX',
    null,
  ]) {
    assertThrows(
      () => normalizeEnrollmentCode(value),
      EnrollmentError,
      'malformed_enrollment_code',
    );
  }
});

Deno.test('enrollment: request validation canonicalizes UUID/platform and bounds app metadata', () => {
  assertEquals(validateEnrollmentRequest({
    code: 'nara-abcd-efgh-jkmn-pqrs-tvwx',
    sourceId: SOURCE.toUpperCase(),
    platform: 'iOS',
    appVersion: ' 1.2.3 (45) ',
  }), {
    code: 'NARAABCDEFGHJKMNPQRSTVWX',
    sourceId: SOURCE,
    platform: 'ios',
    appVersion: '1.2.3 (45)',
  });

  assertThrows(
    () => validateEnrollmentRequest({
      code: 'NARA-ABCD-EFGH-JKMN-PQRS-TVWX',
      sourceId: SOURCE,
      platform: 'ios',
      appVersion: `1.${'x'.repeat(64)}`,
    }),
    EnrollmentError,
    'invalid_app_version',
  );
});

Deno.test('enrollment: same code/source retries return one stable credential', () => {
  const code = 'NARA-ABCD-EFGH-JKMN-PQRS-TVWX';
  const same = deriveInstallationToken(code, SOURCE, PEPPER);
  assertEquals(deriveInstallationToken(code.toLowerCase(), SOURCE.toUpperCase(), PEPPER), same);
  assert(same.startsWith('noop_'));
  assertEquals(same.length, 48);
  assert(
    deriveInstallationToken(code, '22222222-2222-4222-8222-222222222223', PEPPER) !== same,
    'another installation must receive another credential',
  );
  assert(
    deriveInstallationToken('NARA-ABCD-EFGH-JKMN-PQRS-TVW0', SOURCE, PEPPER) !== same,
    'another enrollment code must receive another credential',
  );
});

Deno.test('enrollment: Edge sends only hashes to the atomic RPC and returns the raw token once', async () => {
  const calls: any[] = [];
  const rest: any = {
    configured: true,
    async rpc(name: string, args: any) {
      calls.push({ name, args });
      return [{ user_id: USER, token_id: TOKEN_ID }];
    },
  };
  const service = createEnrollmentService({ rest, pepper: PEPPER, retryWindowSeconds: 300 });
  const result = await service.redeem({
    code: 'NARA-ABCD-EFGH-JKMN-PQRS-TVWX',
    sourceId: SOURCE,
    platform: 'ios',
    appVersion: '1.2.3',
  });

  assertEquals(result.type, 'enrollment');
  assertEquals(result.protocolVersion, '1.1');
  assertEquals(result.userId, USER);
  assertEquals(result.sourceId, SOURCE);
  assertEquals(result.tokenId, TOKEN_ID);
  assert(result.uploadToken.startsWith('noop_'));
  assertEquals(Object.keys(result).sort(), [
    'protocolVersion',
    'sourceId',
    'tokenId',
    'type',
    'uploadToken',
    'userId',
  ]);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].name, 'redeem_noop_enrollment');
  assertEquals(calls[0].args.p_code_hash, hashEnrollmentCode('NARA-ABCD-EFGH-JKMN-PQRS-TVWX', PEPPER));
  assertEquals(calls[0].args.p_token_hash, hashIngestToken(result.uploadToken));
  assert(!JSON.stringify(calls[0]).includes(result.uploadToken), 'plaintext token must not reach Postgres');
  assert(!JSON.stringify(calls[0]).includes('NARA-ABCD'), 'plaintext code must not reach Postgres');
});

Deno.test('enrollment: duplicate same-source requests cannot invalidate an earlier response', async () => {
  const rest: any = {
    configured: true,
    rpc() {
      return [{ user_id: USER, token_id: TOKEN_ID }];
    },
  };
  const service = createEnrollmentService({ rest, pepper: PEPPER, retryWindowSeconds: 300 });
  const request = {
    code: 'NARA-ABCD-EFGH-JKMN-PQRS-TVWX',
    sourceId: SOURCE,
    platform: 'ios',
    appVersion: '1.2.3',
  };
  const [first, retry] = await Promise.all([service.redeem(request), service.redeem(request)]);
  assertEquals(retry.uploadToken, first.uploadToken);
  assertEquals(retry.tokenId, first.tokenId);
});

Deno.test('enrollment: RPC reuse and expiry errors preserve their fail-closed status', async () => {
  for (const [message, code, status] of [
    ['POST rpc failed enrollment_code_already_used', 'enrollment_code_already_used', 409],
    ['POST rpc failed enrollment_retry_window_elapsed', 'enrollment_retry_window_elapsed', 409],
    ['POST rpc failed enrollment_code_expired', 'enrollment_code_expired', 410],
  ] as const) {
    const rest: any = {
      configured: true,
      rpc() {
        throw new Error(message);
      },
    };
    const service = createEnrollmentService({ rest, pepper: PEPPER });
    const err = await assertRejects(
      () => service.redeem({
        code: 'NARA-ABCD-EFGH-JKMN-PQRS-TVWX',
        sourceId: SOURCE,
        platform: 'ios',
        appVersion: '1',
      }),
    );
    assertEquals((err as any).code, code);
    assertEquals((err as any).status, status);
  }
});
