import { jsonResponse } from "../lib/response.js";
import { sha256Hex } from "../lib/crypto.js";
import { deleteDnsRecord, CfApiError } from "../lib/cf.js";

export async function handleRelease(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse(400, { error: "invalid_json" });
  }
  const token = body && typeof body === "object" ? body.install_token : null;
  if (typeof token !== "string" || token.length < 10 || token.length > 256) {
    return jsonResponse(400, { error: "missing_install_token" });
  }

  const hash = await sha256Hex(token);
  const subdomain = await env.TOKEN_INDEX.get(hash);

  // Idempotent — uninstall.sh must not blow up if the slot was already
  // reclaimed or never existed. Always 200 with note for unknown tokens.
  if (!subdomain) {
    return jsonResponse(200, { ok: true, released: false, note: "unknown_token" });
  }

  const raw = await env.SUBDOMAIN_RESERVATIONS.get(subdomain);
  if (!raw) {
    await env.TOKEN_INDEX.delete(hash);
    return jsonResponse(200, { ok: true, released: false, note: "no_reservation" });
  }

  const reservation = JSON.parse(raw);

  // Best-effort: a CF DNS delete failure shouldn't block KV cleanup —
  // sweep will retry the record later, and we don't want stuck KV entries
  // leaking the slot.
  if (reservation.cf_record_id) {
    try {
      await deleteDnsRecord(env, reservation.cf_record_id);
    } catch (e) {
      console.error("release: dns_delete_failed", {
        subdomain,
        record_id: reservation.cf_record_id,
        status: e instanceof CfApiError ? e.status : null,
        message: e.message,
      });
    }
  }

  await Promise.all([
    env.SUBDOMAIN_RESERVATIONS.delete(subdomain),
    env.TOKEN_INDEX.delete(hash),
  ]);

  console.log("release: ok", { subdomain });

  return jsonResponse(200, {
    ok: true,
    released: true,
    fqdn: `${subdomain}.${env.SYGEN_DOMAIN}`,
  });
}
