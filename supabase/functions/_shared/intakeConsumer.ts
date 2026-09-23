import type { SupabaseRest } from './rest.ts';
import type { S3Store } from './s3.ts';
import { reconcileObjectVerification } from './objectVerification.ts';
import { reconcileIntake } from './durability.ts';
import { reconcileProjections } from './projections.ts';

export const INTAKE_CONTRACT_VERSION = 1;
export const INTAKE_LANES = ['verification', 'projection', 'legacy'] as const;
export type IntakeLane = typeof INTAKE_LANES[number];
export type IntakeIdentity = { processId: string; instanceId: string; sourceRevision: string };

export function validateIntakeEnvironment(env: Record<string, string | undefined>, packagedRevision: string) {
  const sourceRevision = env.INTAKE_WORKER_SOURCE_REVISION ?? '';
  const instanceId = env.INTAKE_WORKER_INSTANCE_ID ?? '';
  const project = env.INTAKE_EXPECTED_SUPABASE_PROJECT ?? '';
  if (!/^[0-9a-f]{40}$/.test(sourceRevision) || sourceRevision !== packagedRevision.trim() ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(instanceId) ||
      !/^[a-z0-9]{20}$/.test(project)) throw new Error('intake_identity_required');
  const url = new URL(env.SUPABASE_URL ?? '');
  if (url.protocol !== 'https:' || url.hostname !== `${project}.supabase.co` ||
      url.username || url.password || url.port || !['', '/'].includes(url.pathname) || url.search || url.hash ||
      !env.SUPABASE_SERVICE_ROLE_KEY) throw new Error('intake_project_binding_required');
  return { sourceRevision, instanceId, processId: crypto.randomUUID() };
}

/** No timer heartbeat: a lane records progress only after its real bounded queue call returns. */
export function createIntakeConsumer(rest: SupabaseRest, raw: S3Store, identity: IntakeIdentity) {
  async function preflight() {
    const contract = await rest.rpc('noop_intake_consumer_contract', {});
    if (contract?.contract_version !== INTAKE_CONTRACT_VERSION || contract.completion !== 'verified_indexed' ||
        contract.projection !== 'atomic_lifecycle_v1' ||
        JSON.stringify(contract.lanes) !== JSON.stringify(INTAKE_LANES)) throw new Error('intake_contract_mismatch');
  }
  async function poll(lane: IntakeLane) {
    let claimed: number, completed: number, failures: number;
    if (lane === 'verification') {
      const r = await reconcileObjectVerification(rest, raw, { limit: 1 });
      claimed = r.claimed; completed = r.verifiedIndexed; failures = r.retry + r.paused + r.leaseLost;
    } else if (lane === 'projection') {
      const r = await reconcileProjections(rest, raw, 1);
      claimed = r.scanned; completed = r.settled; failures = r.deferred;
    } else {
      const r = await reconcileIntake(rest, raw, 1);
      claimed = r.scanned; completed = r.verifiedIndexed; failures = r.deferred;
    }
    await rest.rpc('noop_intake_consumer_poll', { p_process: identity.processId, p_instance: identity.instanceId,
      p_source_revision: identity.sourceRevision, p_lane: lane, p_claimed: claimed, p_completed: completed, p_failures: failures });
    return { lane, claimed, completed, failures };
  }
  return { preflight, poll };
}

/** Independent single-concurrency lanes keep storage verification separate from scalar projection. */
export async function runIntakeConsumer(consumer: ReturnType<typeof createIntakeConsumer>, {
  signal, once = false, sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)),
  report = (_event: { lane: IntakeLane; claimed?: number; completed?: number; failures?: number; error?: string }) => {},
}: { signal?: AbortSignal; once?: boolean; sleep?: (ms: number) => Promise<void>;
  report?: (event: { lane: IntakeLane; claimed?: number; completed?: number; failures?: number; error?: string }) => void } = {}) {
  await consumer.preflight();
  await Promise.all(INTAKE_LANES.map(async (lane) => {
    do {
      let progressed = false;
      try {
        const result = await consumer.poll(lane); report(result); progressed = result.completed > 0;
      } catch {
        report({ lane, error: 'intake_lane_failed' });
        if (once) throw new Error('intake_lane_failed');
      }
      if (once || signal?.aborted) break;
      await sleep(progressed ? 10 : 1000);
    } while (!signal?.aborted);
  }));
}
