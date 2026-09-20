// Enrolled owner/device score reads, registration and sleep edits use the personal + fleet credentials.
import { createSupabaseRest, restConfigFromEnv } from '../_shared/rest.ts';
import { pushConfig } from '../_shared/config.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';

const cfg = pushConfig();
const rest = createSupabaseRest({ cfg: restConfigFromEnv() });

Deno.serve((req: Request) => handleScoresRequest(req, { rest, cfg }));
