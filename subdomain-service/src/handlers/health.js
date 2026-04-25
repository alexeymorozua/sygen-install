import { jsonResponse } from "../lib/response.js";

// Constant-time string compare. Workers don't ship a native primitive,
// and the value is short — JS-level loop is sufficient against same-length
// timing attacks. (KV lookups dominate handler runtime anyway.)
function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

export async function handleHealth(request, env) {
  if (!env.ADMIN_TOKEN) {
    return jsonResponse(503, { error: "admin_token_unset" });
  }
  const auth = request.headers.get("Authorization") || "";
  const prefix = "Bearer ";
  if (!auth.startsWith(prefix) || !timingSafeEqual(auth.slice(prefix.length), env.ADMIN_TOKEN)) {
    return jsonResponse(401, { error: "unauthorized" });
  }

  // Cheap check: first page only. Full counts are not free at scale.
  const list = await env.SUBDOMAIN_RESERVATIONS.list({ limit: 1000 });
  return jsonResponse(200, {
    status: "ok",
    active_reservations_first_page: list.keys.length,
    list_complete: list.list_complete,
    timestamp: new Date().toISOString(),
  });
}
