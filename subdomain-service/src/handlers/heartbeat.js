import { jsonResponse } from "../lib/response.js";
import { sha256Hex } from "../lib/crypto.js";

async function readToken(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return { error: jsonResponse(400, { error: "invalid_json" }) };
  }
  const token = body && typeof body === "object" ? body.install_token : null;
  if (typeof token !== "string" || token.length < 10 || token.length > 256) {
    return { error: jsonResponse(400, { error: "missing_install_token" }) };
  }
  return { token };
}

export async function handleHeartbeat(request, env) {
  const parsed = await readToken(request);
  if (parsed.error) return parsed.error;

  const hash = await sha256Hex(parsed.token);
  const subdomain = await env.TOKEN_INDEX.get(hash);
  if (!subdomain) {
    return jsonResponse(404, { error: "unknown_token" });
  }

  const raw = await env.SUBDOMAIN_RESERVATIONS.get(subdomain);
  if (!raw) {
    // TOKEN_INDEX points to a missing reservation — most likely a swept
    // entry whose index entry leaked. Clean up and tell the caller.
    await env.TOKEN_INDEX.delete(hash);
    return jsonResponse(404, { error: "unknown_token" });
  }

  const reservation = JSON.parse(raw);
  const now = new Date();
  const ttlDays = parseInt(env.TTL_DAYS || "30", 10);
  reservation.last_heartbeat_at = now.toISOString();
  reservation.expires_at = new Date(now.getTime() + ttlDays * 86400 * 1000).toISOString();

  await env.SUBDOMAIN_RESERVATIONS.put(subdomain, JSON.stringify(reservation));

  return jsonResponse(200, {
    fqdn: `${subdomain}.${env.SYGEN_DOMAIN}`,
    expires_at: reservation.expires_at,
  });
}
