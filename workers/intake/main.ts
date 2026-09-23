import { pushConfig } from '../../supabase/functions/_shared/config.ts';
import { createSupabaseRest, restConfigFromEnv } from '../../supabase/functions/_shared/rest.ts';
import { createS3 } from '../../supabase/functions/_shared/s3.ts';
import { createIntakeConsumer, runIntakeConsumer, validateIntakeEnvironment } from '../../supabase/functions/_shared/intakeConsumer.ts';

if (import.meta.main) {
  try {
    if (Deno.args.length>1 || Deno.args.some((x) => !['--once','--status'].includes(x))) throw new Error('invalid_intake_mode');
    const env = Deno.env.toObject();
    const packagedRevision = await Deno.readTextFile(new URL('./source-revision', import.meta.url));
    const identity = validateIntakeEnvironment(env, packagedRevision);
    const rest = createSupabaseRest({ cfg: restConfigFromEnv(env),
      fetchImpl: (input, init) => fetch(input, { ...init, signal: AbortSignal.timeout(30_000) }) });
    if (Deno.args.includes('--status')) {
      console.log(JSON.stringify(await rest.rpc('noop_intake_status', {})));
      Deno.exit(0);
    }
    const cfg = pushConfig(env);
    if (cfg.rawStore !== 'b2' || !cfg.b2KeyId || !cfg.b2ApplicationKey || !cfg.b2Bucket || !cfg.b2S3Endpoint) {
      throw new Error('intake_storage_required');
    }
    const storage = new URL(cfg.b2S3Endpoint);
    if (storage.protocol !== 'https:' || storage.username || storage.password || storage.search || storage.hash) {
      throw new Error('intake_storage_binding_required');
    }
    const raw = createS3({ endpoint: cfg.b2S3Endpoint, bucket: cfg.b2Bucket, region: cfg.b2Region,
      accessKeyId: cfg.b2KeyId, secretAccessKey: cfg.b2ApplicationKey, style: 'path' });
    const stop = new AbortController();
    Deno.addSignalListener('SIGTERM', () => stop.abort());
    Deno.addSignalListener('SIGINT', () => stop.abort());
    await runIntakeConsumer(createIntakeConsumer(rest, raw, identity), { signal: stop.signal,
      once: Deno.args.includes('--once'), report: (event) => console.log(JSON.stringify(event)) });
  } catch {
    console.error('intake_worker_failed'); Deno.exitCode = 1;
  }
}
