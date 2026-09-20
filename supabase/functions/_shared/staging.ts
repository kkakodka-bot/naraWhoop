// Port of the retired Node receiver with one deliberate change: the generation
// store is Postgres (noop_push_staging_parts) instead of process memory, because edge isolates
// are stateless — an in-memory port would silently drop parts whenever two invocations of the
// same window land on different isolates. The observable state machine (error codes, completion
// semantics) is identical to the Node original.
//
// The protocol requires each sender to serialize generations per source/device/stream. Protocol
// version is deliberately absent: a version change is still a new generation in the same
// authoritative replacement scope and must supersede older incomplete work.
import { PushProtocolError } from './registry.ts';
import type { SupabaseRest } from './rest.ts';

function scopeKey(userId: string, header: any): string {
  return `${userId}|${header.sourceId}|${header.deviceId}|${header.stream}`;
}

function windowIdentity(window: any): string {
  return JSON.stringify({
    replacementId: window.replacementId,
    selector: window.selector,
    startInclusive: window.startInclusive,
    endExclusive: window.endExclusive,
    parts: window.parts,
  });
}

function validateWindow(header: any) {
  const window = header?.window;
  if (!window || typeof window !== 'object') {
    throw new PushProtocolError('missing_window', 422);
  }
  const { replacementId, selector, startInclusive, endExclusive, part, parts } = window;
  if (!replacementId || !selector || startInclusive == null || endExclusive == null) {
    throw new PushProtocolError('invalid_window', 422);
  }
  if (!Number.isInteger(part) || !Number.isInteger(parts) || part < 1 || parts < 1 || part > parts) {
    throw new PushProtocolError('invalid_window_part', 422);
  }
  if (header.startCursor != null || header.endCursor != null) {
    throw new PushProtocolError('invalid_replace_cursor', 422);
  }
  return window;
}

interface StagedPartRow {
  replacement_id: string;
  window_identity: string;
  part: number;
  parts_total: number;
  batch_id: string;
  body_sha256: string;
  records: any[];
}

/**
 * Durably stage replace_window parts; apply only when every part is present.
 * A completing part is not acknowledged until apply succeeds (caller responsibility).
 */
export function createPushReplacementStaging({ rest }: { rest: SupabaseRest }) {
  async function loadRows(userId: string, scope: string): Promise<StagedPartRow[]> {
    return rest.select(
      'noop_push_staging_parts',
      `user_id=eq.${userId}&scope=eq.${encodeURIComponent(scope)}&select=replacement_id,window_identity,part,parts_total,batch_id,body_sha256,records&order=part.asc`,
    );
  }

  async function deleteScope(userId: string, scope: string, replacementId?: string) {
    let q = `user_id=eq.${userId}&scope=eq.${encodeURIComponent(scope)}`;
    if (replacementId) q += `&replacement_id=eq.${encodeURIComponent(replacementId)}`;
    await rest.delete('noop_push_staging_parts', q);
  }

  return {
    async stagePart({ userId, header, records, bodySha256 }: {
      userId: string;
      header: any;
      records: any[];
      bodySha256: string;
    }) {
      const window = validateWindow(header);
      const scope = scopeKey(userId, header);
      const identity = windowIdentity(window);

      let rows = await loadRows(userId, scope);

      // A different replacementId under the same scope is a new generation. A superseded
      // incomplete generation is abandoned. A complete generation may be the residue of a
      // projection/clear/ACK failure; return its records so the caller can idempotently apply and
      // clear it before staging the newer authoritative snapshot.
      const priorIds = new Set(rows.map((r) => r.replacement_id));
      if (priorIds.size && !priorIds.has(window.replacementId)) {
        const priorCompleteId = [...priorIds].find((id) => {
          const parts = rows.filter((r) => r.replacement_id === id);
          return parts.length > 0 && parts.length >= parts[0].parts_total;
        });
        if (priorCompleteId) {
          const parts = rows.filter((r) => r.replacement_id === priorCompleteId);
          let priorWindow: any;
          try {
            priorWindow = JSON.parse(parts[0].window_identity);
          } catch {
            throw new PushProtocolError('replacement_staging_corrupt', 500);
          }
          if (!priorWindow || priorWindow.replacementId !== priorCompleteId ||
              !Number.isInteger(priorWindow.parts) || priorWindow.parts !== parts[0].parts_total) {
            throw new PushProtocolError('replacement_staging_corrupt', 500);
          }
          return {
            complete: false,
            isCompletingPart: false,
            records: [],
            window,
            header,
            alreadyStaged: false,
            supersededComplete: {
              header: {
                ...header,
                batchId: parts[parts.length - 1].batch_id,
                window: { ...priorWindow, part: priorWindow.parts },
              },
              records: collectRecords(parts),
            },
          };
        }
        for (const priorId of priorIds) await deleteScope(userId, scope, priorId);
        rows = [];
      }

      const generation = rows.filter((r) => r.replacement_id === window.replacementId);
      if (generation.length && generation[0].window_identity !== identity) {
        throw new PushProtocolError('replacement_window_conflict', 409);
      }

      const prior = generation.find((r) => r.part === window.part);
      if (prior) {
        if (prior.batch_id !== header.batchId) {
          throw new PushProtocolError('replacement_part_conflict', 409);
        }
        if (prior.body_sha256 !== bodySha256) {
          throw new PushProtocolError('batch_id_conflict', 409);
        }
        const complete = generation.length >= window.parts;
        return {
          complete,
          // A prior projection or generation-clear may have failed after the final part was
          // staged. Re-applying the complete replacement is idempotent and gives the caller a
          // chance to clear that generation; skipping it leaves a permanent supersede conflict.
          isCompletingPart: complete,
          records: collectRecords(generation),
          window,
          header,
          alreadyStaged: true,
        };
      }

      await rest.upsert('noop_push_staging_parts', {
        user_id: userId,
        scope,
        replacement_id: String(window.replacementId),
        window_identity: identity,
        part: window.part,
        parts_total: window.parts,
        batch_id: String(header.batchId || ''),
        body_sha256: bodySha256,
        records,
      }, { onConflict: 'user_id,scope,replacement_id,part', prefer: 'resolution=ignore-duplicates' });

      const staged = [...generation, {
        replacement_id: String(window.replacementId),
        window_identity: identity,
        part: window.part,
        parts_total: window.parts,
        batch_id: String(header.batchId || ''),
        body_sha256: bodySha256,
        records,
      }];

      const complete = staged.length === window.parts;
      return {
        complete,
        isCompletingPart: complete,
        records: complete ? collectRecords(staged) : [],
        window,
        header,
        alreadyStaged: false,
      };
    },

    async clearGeneration({ userId, header }: { userId: string; header: any }) {
      const replacementId = validateWindow(header).replacementId;
      await deleteScope(userId, scopeKey(userId, header), String(replacementId));
    },
  };
}

function collectRecords(rows: StagedPartRow[]): any[] {
  const parts = [...rows].sort((a, b) => a.part - b.part);
  const records: any[] = [];
  for (const part of parts) {
    records.push(...(part.records || []));
  }
  return records;
}

export type PushReplacementStaging = ReturnType<typeof createPushReplacementStaging>;
