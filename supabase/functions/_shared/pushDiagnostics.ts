import { ALL_STREAMS, PushProtocolError } from './registry.ts';

// Closed vocabulary: diagnostics must never contain record bodies, tenant identifiers,
// object keys, SQL messages, or a caller-supplied correlation value.
export const INGEST_STAGES = [
  'receipt_lookup', 'quota', 'wal', 'device', 'archive', 'archive_manifest',
  'archive_write', 'archive_verify', 'projection', 'replacement', 'ack', 'wal_cleanup',
] as const;
export type IngestStage = typeof INGEST_STAGES[number];
export type PushErrorVersion = '1.0' | '1.1' | '1.2';

/** Inspect only the bounded NDJSON header, retaining no record/identity fields. */
export function inlineRequestProtocol(bytes: Uint8Array): '1.0' | '1.1' {
  const newline = bytes.indexOf(10);
  const end = newline < 0 ? bytes.length : newline;
  if (end > 64 * 1024) return '1.1';
  try {
    const header = JSON.parse(new TextDecoder().decode(bytes.subarray(0, end)));
    if (header?.type === 'batch' && (header.protocolVersion === '1.0' || header.protocolVersion === '1.1')) {
      return header.protocolVersion;
    }
  } catch { /* Malformed requests have no validated response version. */ }
  return '1.1';
}

export class PushIngestFailure extends Error {
  readonly stage: IngestStage;
  readonly stream: string | undefined;

  constructor(stage: IngestStage, stream: string) {
    super('push_failed');
    this.name = 'PushIngestFailure';
    this.stage = stage;
    this.stream = ALL_STREAMS.has(stream) ? stream : undefined;
  }
}

export async function ingestStep<T>(stage: IngestStage, stream: string, run: () => Promise<T>): Promise<T> {
  try {
    return await run();
  } catch (error) {
    if (error instanceof Error &&
        (error as Error & { receiverCode?: string }).receiverCode === 'scoring_input_gate_busy') {
      throw new PushProtocolError('scoring_input_gate_busy', 503);
    }
    // Existing protocol status/retry semantics are unchanged. Preserve a more precise
    // nested archive stage instead of replacing it with the outer archive label.
    if (error instanceof PushProtocolError || error instanceof PushIngestFailure ||
        (error instanceof Error && error.message === 'batch_id_conflict')) throw error;
    throw new PushIngestFailure(stage, stream);
  }
}

/** Safe response/log pair. The generated ID ties a phone failure to one server request. */
export function unexpectedIngestDiagnostic(error: unknown, protocolVersion: PushErrorVersion = '1.1') {
  return {
    type: 'error', protocolVersion, code: 'push_failed',
    correlationId: crypto.randomUUID(),
    ...(error instanceof PushIngestFailure ? { stage: error.stage, stream: error.stream } : {}),
  };
}

export function ingestProtocolErrorResponse(error: PushProtocolError, protocolVersion: PushErrorVersion = '1.1'): Response {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (error.code === 'scoring_input_gate_busy') headers['retry-after'] = '2';
  return new Response(JSON.stringify({ type: 'error', protocolVersion, code: error.message,
    ...(Array.isArray(error.fields) ? { fields: error.fields } : {}) }),
    { status: error.status, headers });
}
