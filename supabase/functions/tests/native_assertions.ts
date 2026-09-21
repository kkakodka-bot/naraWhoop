import assert from 'node:assert/strict';
import { PushIngestFailure, type IngestStage } from '../_shared/pushDiagnostics.ts';

/** Native faults must cross the same privacy boundary as a real receiver request. */
export function ingestFailure(stage: IngestStage, stream: string) {
  return (error: unknown) => {
    assert(error instanceof PushIngestFailure);
    assert.equal(error.message, 'push_failed');
    assert.equal(error.stage, stage);
    assert.equal(error.stream, stream);
    return true;
  };
}
