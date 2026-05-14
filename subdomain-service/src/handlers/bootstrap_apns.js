// /api/bootstrap/apns — return the APNs auth key (.p8 content) for a
// freshly-provisioned install so install.sh can drop it under
// ${SYGEN_HOME}/_secrets/AuthKey_<KEY_ID>.p8 and enable iOS push without
// the operator having to source the key by hand.
//
// Historically install.sh expected operators to manually copy the .p8 file
// onto every fresh VPS; that never happened for testers, so push stayed off
// for them. Distributing the key via this endpoint (gated by install_token,
// rate-limited per token) lets every install.sh run come up with push
// already wired.
//
// Auth: install_token must resolve to a live reservation (same shape as
// heartbeat / dns-challenge — token binds to a single FQDN). Token arrives
// via `Authorization: Bearer <token>` header. We reject everything else.
//
// Rate limit: one successful response per install_token per 24h. Reading
// the key once at provision time is the only legitimate flow; repeated
// pulls would be a sign the token leaked. KV-backed (no atomic CAS but
// the window is huge relative to the race so a duplicate-fetch slip is
// harmless).
//
// Graceful: if APNS_AUTH_KEY_B64 is not configured in the Worker, return
// 503 — install.sh treats this as "push disabled, continue install".

import { jsonResponse } from "../lib/response.js";
import { sha256Hex } from "../lib/crypto.js";

const RATE_LIMIT_PREFIX = "APNS_BOOTSTRAP:";
const RATE_LIMIT_TTL_SECONDS = 86400;

function readBearer(request) {
  const header = request.headers.get("Authorization") || "";
  if (!header.startsWith("Bearer ")) {
    return null;
  }
  const token = header.slice("Bearer ".length).trim();
  if (token.length < 10 || token.length > 256) {
    return null;
  }
  return token;
}

export async function handleBootstrapApns(request, env) {
  const token = readBearer(request);
  if (!token) {
    return jsonResponse(401, { ok: false, error: "invalid_token" });
  }

  const hash = await sha256Hex(token);
  const tokenPrefix = hash.slice(0, 8);
  const subdomain = await env.TOKEN_INDEX.get(hash);
  if (!subdomain) {
    console.warn("bootstrap_apns: invalid_token", { token_hash_prefix: tokenPrefix });
    return jsonResponse(401, { ok: false, error: "invalid_token" });
  }

  const raw = await env.SUBDOMAIN_RESERVATIONS.get(subdomain);
  if (!raw) {
    // Stale TOKEN_INDEX entry — same cleanup pattern as heartbeat/eab.
    await env.TOKEN_INDEX.delete(hash);
    console.warn("bootstrap_apns: invalid_token", { token_hash_prefix: tokenPrefix });
    return jsonResponse(401, { ok: false, error: "invalid_token" });
  }

  const rateKey = `${RATE_LIMIT_PREFIX}${hash}`;
  const seen = await env.SUBDOMAIN_RESERVATIONS.get(rateKey);
  if (seen) {
    console.warn("bootstrap_apns: rate_limited", { token_hash_prefix: tokenPrefix });
    return jsonResponse(429, { ok: false, error: "rate_limited" });
  }

  const keyB64 = env.APNS_AUTH_KEY_B64;
  const keyId = env.APNS_KEY_ID;
  if (!keyB64 || !keyId) {
    console.error("bootstrap_apns: not_configured", {
      have_key_id: !!keyId,
      have_key_b64: !!keyB64,
    });
    return jsonResponse(503, { ok: false, error: "apns_not_configured" });
  }

  await env.SUBDOMAIN_RESERVATIONS.put(rateKey, "1", {
    expirationTtl: RATE_LIMIT_TTL_SECONDS,
  });

  console.log("bootstrap_apns: issued", {
    subdomain,
    token_hash_prefix: tokenPrefix,
    key_id: keyId,
  });

  return jsonResponse(200, {
    ok: true,
    key_id: keyId,
    key_b64: keyB64,
  });
}
