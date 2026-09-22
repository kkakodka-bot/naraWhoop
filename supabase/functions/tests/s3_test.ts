// Phase 2 S3 coverage — mirror of the retired Node receiver plus the newly
// ported deleteObject path used by the account-deletion worker.
import { assertEquals, assert } from 'jsr:@std/assert';
import { createS3 } from '../_shared/s3.ts';

function xmlPage({ keys, truncated, token }: { keys: string[]; truncated: boolean; token: string | null }) {
  const contents = keys.map((k) => `<Contents><Key>${k}</Key></Contents>`).join('');
  const next = token ? `<NextContinuationToken>${token}</NextContinuationToken>` : '';
  return `<ListBucketResult><IsTruncated>${truncated}</IsTruncated>${next}${contents}</ListBucketResult>`;
}

function makeS3(impl: (url: string, init: any) => Promise<any>) {
  return createS3({
    endpoint: 'https://s3.example.test',
    bucket: 'FRWHOOP',
    region: 'us-west-004',
    accessKeyId: 'kid',
    secretAccessKey: 'secret',
    fetchImpl: impl as typeof fetch,
  });
}

Deno.test('s3 listPrefix follows continuation tokens past one page', async () => {
  const urls: string[] = [];
  const s3 = makeS3(async (url: string) => {
    urls.push(url);
    const token = new URL(String(url)).searchParams.get('continuation-token');
    if (!token) {
      return { ok: true, status: 200, headers: { get: () => null }, text: async () => xmlPage({ keys: ['a'], truncated: true, token: 'page-2' }) };
    }
    assertEquals(token, 'page-2');
    return { ok: true, status: 200, headers: { get: () => null }, text: async () => xmlPage({ keys: ['b'], truncated: false, token: null }) };
  });
  const keys = await s3.listPrefix('v3/core/users/x/');
  assertEquals(keys, ['a', 'b']);
  assertEquals(urls.length, 2);
});

Deno.test('s3 listPrefix stops on an untruncated single page', async () => {
  const urls: string[] = [];
  const s3 = makeS3(async (url: string) => {
    urls.push(String(url));
    return { ok: true, status: 200, headers: { get: () => null }, text: async () => xmlPage({ keys: ['only'], truncated: false, token: null }) };
  });
  const keys = await s3.listPrefix('v1/metrics/');
  assertEquals(keys, ['only']);
  assertEquals(urls.length, 1);
});

Deno.test('s3 deleteObject treats a missing object as deleted and reports it', async () => {
  const s3 = makeS3(async () => ({ ok: true, status: 404, headers: { get: () => null }, text: async () => '' }));
  const out = await s3.deleteObject('v2/users/x/devices/d/raw/hr/k.ndjson.gz');
  assertEquals(out, { deleted: true, missing: true });
});

Deno.test('s3 deleteObject reports a server error instead of swallowing it', async () => {
  const s3 = makeS3(async () => ({ ok: false, status: 500, headers: { get: () => null }, text: async () => 'boom' }));
  let threw = false;
  try {
    await s3.deleteObject('k');
  } catch (e) {
    threw = true;
    assert(String(e).includes('object delete failed'));
  }
  assert(threw, 'deleteObject must throw on a non-404 failure');
});

Deno.test('version erasure checks owner prefix before deletion and removes all archived versions', async () => {
  const prefix='v2/users/11111111-1111-4111-8111-111111111111/';
  const deleted:string[]=[];let listed=0;
  const s3=makeS3(async(url,init)=>{
    const parsed=new URL(url);
    if(init.method==='DELETE') {deleted.push(parsed.searchParams.get('versionId')!);return new Response(null,{status:204});}
    listed++;
    const versions=listed===1?`<Version><Key>${encodeURIComponent(prefix+'raw/a')}</Key><VersionId>v1</VersionId></Version>
      <DeleteMarker><Key>${encodeURIComponent(prefix+'raw/a')}</Key><VersionId>v2</VersionId></DeleteMarker>`:'';
    return new Response(`<ListVersionsResult><IsTruncated>false</IsTruncated>${versions}</ListVersionsResult>`);
  });
  assertEquals(await s3.purgePrefixVersions(prefix),{deleted:2});
  assertEquals(deleted,['v1','v2']);assertEquals(listed,2);
  const foreign=makeS3(async(_url,init)=>{
    assertEquals(init.method,'GET');
    return new Response('<ListVersionsResult><Version><Key>v2/users/another-owner/raw/a</Key><VersionId>x</VersionId></Version></ListVersionsResult>');
  });
  let denied=false;try {await foreign.purgePrefixVersions(prefix);} catch {denied=true;}
  assert(denied);
});
