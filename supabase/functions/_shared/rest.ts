// Port of the retired Node receiver — service-role PostgREST client.
// In the edge runtime SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected by the platform;
// locally they come from `supabase functions serve --env-file`.

export interface RestConfig {
  supabaseUrl: string;
  supabaseServiceRoleKey: string;
}

export function restConfigFromEnv(env: Record<string, string | undefined> = Deno.env.toObject()): RestConfig {
  const pick = (...names: string[]) => {
    for (const name of names) {
      const v = env[name];
      if (v != null && String(v).trim() !== '') return String(v).trim();
    }
    return '';
  };
  return {
    supabaseUrl: pick('SUPABASE_URL', 'PROJECT_URL').replace(/\/$/, ''),
    supabaseServiceRoleKey: pick('SUPABASE_SERVICE_ROLE_KEY', 'SERVICE_ROLE_KEY'),
  };
}

export function createSupabaseRest({ cfg, fetchImpl = fetch }: { cfg: RestConfig; fetchImpl?: typeof fetch }) {
  const url = cfg.supabaseUrl;
  const configured = Boolean(url && cfg.supabaseServiceRoleKey);

  function restHeaders() {
    return {
      apikey: cfg.supabaseServiceRoleKey,
      authorization: `Bearer ${cfg.supabaseServiceRoleKey}`,
      'content-type': 'application/json',
      prefer: 'return=representation',
    } as Record<string, string>;
  }

  async function request(path: string, { method = 'GET', body, query, prefer, schema }: {
    method?: string;
    body?: unknown;
    query?: string;
    prefer?: string;
    schema?: string;
  } = {}): Promise<any> {
    if (!configured) throw new Error('supabase_service_role_required');
    const headers = restHeaders();
    if (prefer) headers.prefer = prefer;
    if (schema) headers['content-profile'] = schema;
    const q = query ? `?${query}` : '';
    const res = await fetchImpl(`${url}/rest/v1/${path}${q}`, {
      method,
      headers,
      body: body == null ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    const json = text ? (() => { try { return JSON.parse(text); } catch { return text; } })() : null;
    if (!res.ok) {
      const msg = typeof json === 'string' ? json : (json?.message || json?.hint || text);
      const err: any = new Error(`${method} ${path} failed (${res.status}) ${String(msg || '').slice(0, 180)}`);
      err.status = res.status;
      // Only this exact server-controlled condition is exposed as a retryable protocol error.
      // Arbitrary SQL messages/codes remain private and are not copied into diagnostics.
      if (json?.code === '55P03' && json?.message === 'scoring_input_gate_busy') {
        err.receiverCode = 'scoring_input_gate_busy';
      }
      throw err;
    }
    return json;
  }

  return {
    configured,
    request,
    async upsert(table: string, rows: unknown, { onConflict, prefer }: { onConflict?: string; prefer?: string } = {}) {
      const list = Array.isArray(rows) ? rows : [rows];
      if (!list.length) return [];
      return request(table, {
        method: 'POST',
        body: list.length === 1 ? list[0] : list,
        prefer: prefer || 'resolution=merge-duplicates,return=representation',
        query: onConflict ? `on_conflict=${encodeURIComponent(onConflict)}` : undefined,
      });
    },
    async select(table: string, query?: string) {
      const rows = await request(table, { query: query || 'select=*' });
      return Array.isArray(rows) ? rows : [];
    },
    async delete(table: string, query: string) {
      return request(table, { method: 'DELETE', query });
    },
    async patch(table: string, body: unknown, query: string) {
      return request(table, { method: 'PATCH', body, query });
    },
    async rpc(name: string, args: unknown) {
      return request(`rpc/${name}`, { method: 'POST', body: args || {} });
    },
    async adminDeleteAuthUser(userId: string) {
      const res = await fetchImpl(`${url}/auth/v1/admin/users/${userId}`, {
        method: 'DELETE',
        headers: {
          apikey: cfg.supabaseServiceRoleKey,
          authorization: `Bearer ${cfg.supabaseServiceRoleKey}`,
        },
      });
      if (res.status === 404) return { deleted: true, missing: true };
      if (!res.ok) throw new Error(`auth delete failed (${res.status})`);
      return { deleted: true, missing: false };
    },
  };
}

export type SupabaseRest = ReturnType<typeof createSupabaseRest>;
