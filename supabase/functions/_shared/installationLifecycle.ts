import {
  bearerToken,
  hashIngestToken,
  IdentityError,
  resolveFleetAuthorization,
  resolveUploadIdentity,
} from "./tokens.ts";
import {
  createDeviceRegistrar,
  createNoopDeviceResolver,
  findNoopDevice,
  scopedExternalDeviceId,
} from "./devices.ts";
import type { SupabaseRest } from "./rest.ts";
import { isSafeExternalDeviceId, isUuid, noopDeviceId } from "./keys.ts";

/** All owner/source arguments come from credentials. Retirement also accepts its own revoked token
 * solely to retrieve the same retirement receipt after a lost response. */
export function createInstallationLifecycle(rest: SupabaseRest) {
  return async (
    req: Request,
    action: "retire" | "confirm" | "handoff",
  ): Promise<Response> => {
    const reply = (body: unknown, status = 200) =>
      Response.json(body, {
        status,
        headers: { "cache-control": "no-store" },
      });
    try {
      if (action === "retire") {
        await resolveFleetAuthorization({ headers: req.headers, rest });
        const token = bearerToken(req.headers);
        if (!/^noop_[A-Za-z0-9_-]{1,256}$/.test(token)) {
          throw new IdentityError("installation required");
        }
        return reply(
          await rest.rpc("retire_noop_installation", {
            p_token_hash: hashIngestToken(token),
          }),
        );
      }
      const identity = await resolveUploadIdentity({
        headers: req.headers,
        rest,
      });
      if (identity.authMode !== "installation") {
        throw new IdentityError("installation required");
      }
      if (
        !await rest.rpc("admit_noop_request", {
          p_user: identity.id,
          p_source: identity.sourceId,
        })
      ) {
        return reply({ code: "installation_rate_limit" }, 429);
      }
      const reader = req.body?.getReader();
      const chunks: Uint8Array[] = [];
      let size = 0;
      if (reader) {
        try {
          while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            size += value.length;
            if (size > 4096) return reply({ code: "payload_too_large" }, 413);
            chunks.push(value);
          }
        } finally {
          await reader.cancel();
        }
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }
      let body: any;
      try {
        body = JSON.parse(new TextDecoder().decode(bytes));
      } catch {
        return reply({ code: "invalid_lifecycle_request" }, 400);
      }
      const userId = identity.id;
      const sourceId = identity.sourceId!;
      if (action === "confirm") {
        const evidence = body?.evidence;
        if (
          evidence?.method !== "device_information_serial_v1" ||
          !/^[A-Z0-9-]{6,64}$/.test(evidence?.serial || "") ||
          isUuid(evidence.serial) ||
          !/^[a-f0-9]{64}$/.test(evidence?.receiptSha256 || "")
        ) {
          return reply({ code: "supported_serial_evidence_required" }, 422);
        }
        if (!isSafeExternalDeviceId(body.provisionalExternalDeviceId)) {
          return reply({ code: "invalid_device" }, 422);
        }
        let provisional = await findNoopDevice({
          rest,
          userId,
          sourceId,
          externalDeviceId: body.provisionalExternalDeviceId,
          resolveAlias: false,
        });
        if (!provisional) {
          const external = scopedExternalDeviceId(
            body.provisionalExternalDeviceId,
            sourceId,
          );
          if (!external.startsWith(`installation:${sourceId}:`)) {
            return reply({ code: "provisional_identity_required" }, 422);
          }
          provisional = noopDeviceId(userId, external);
          await createDeviceRegistrar(rest)({
            id: provisional,
            user_id: userId,
            external_device_id: external,
            last_seen_at: new Date().toISOString(),
          });
        }
        const canonical = await createNoopDeviceResolver({ rest })({
          userId,
          sourceId,
          externalDeviceId: `whoop-${evidence.serial}`,
        });
        const deviceId = await rest.rpc("confirm_noop_wearable", {
          p_user: userId,
          p_source: sourceId,
          p_provisional: provisional,
          p_canonical: canonical,
          p_evidence: evidence,
        });
        return reply({ userId, sourceId, deviceId, state: "confirmed" });
      }
      const device = await findNoopDevice({
        rest,
        userId,
        sourceId,
        externalDeviceId: body.externalDeviceId,
      });
      if (!device) return reply({ code: "device_not_found" }, 404);
      if (body.expectedGeneration != null && !isUuid(body.expectedGeneration)) {
        return reply({ code: "invalid_generation" }, 422);
      }
      return reply(
        await rest.rpc("handoff_noop_collection", {
          p_user: userId,
          p_source: sourceId,
          p_device: device,
          p_expected: body.expectedGeneration ?? null,
          p_seconds: 120,
        }),
      );
    } catch (error) {
      const status = (error as { status?: number })?.status;
      if (error instanceof IdentityError || status === 401 || status === 403) {
        return reply({ code: "unauthorized" }, 401);
      }
      if (status === 409 || /conflict|reconciled_retry/.test(String(error))) {
        return reply({ code: "lifecycle_conflict" }, 409);
      }
      return reply({ code: "lifecycle_unavailable" }, 503);
    }
  };
}
