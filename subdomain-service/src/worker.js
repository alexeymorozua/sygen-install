// Sygen subdomain provisioning Worker — SKELETON.
//
// Endpoints (see PHASE3_subdomain_provisioning_design.md in sygen-clean):
//   POST   /api/provision  — allocate a fresh <id>.sygen.pro
//   POST   /api/heartbeat  — extend reservation TTL
//   DELETE /api/release    — free reservation on uninstall
//   GET    /api/health     — admin health check
//
// Scheduled:
//   cron "0 2 * * *" — sweep expired reservations
//
// This file is a skeleton. Logic stubs throw 501; implementation lands in
// Phase 3 task A.

const JSON_HEADERS = { "Content-Type": "application/json" };

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function notImplemented(name) {
  return jsonResponse(501, { error: "not_implemented", endpoint: name });
}

// ---------- handlers ----------

async function handleProvision(request, env) {
  // TODO(phase3-A):
  // 1. Rate-limit by source IP (5 req / hour).
  // 2. Generate 8-char base32 subdomain (Crockford alphabet, retry x3 on
  //    collision against env.SUBDOMAIN_RESERVATIONS and blacklist).
  // 3. Look up public IP of the caller from CF-Connecting-IP header.
  // 4. Mint short-lived scoped CF token (Zone.DNS:Edit on the new record_id)
  //    via CF Account API using env.CF_MASTER_API_TOKEN.
  // 5. Create A record <subdomain>.sygen.pro -> <caller IP> via CF API.
  // 6. Generate install_token (64-char base64url random) + sha256 hash.
  // 7. Write KV entry: SUBDOMAIN_RESERVATIONS[subdomain] = {...},
  //    TOKEN_INDEX[hash] = subdomain.
  // 8. Return JSON contract from §2.1.
  return notImplemented("provision");
}

async function handleHeartbeat(request, env) {
  // TODO(phase3-A):
  // 1. Rate-limit by install_token (60 req / hour).
  // 2. Parse body: {install_token}.
  // 3. hash = sha256(install_token); subdomain = TOKEN_INDEX.get(hash).
  //    If null -> 404.
  // 4. Read SUBDOMAIN_RESERVATIONS[subdomain]. If null -> 404.
  // 5. Update last_heartbeat_at = now, expires_at = now + TTL_DAYS.
  // 6. Return {fqdn, expires_at}.
  return notImplemented("heartbeat");
}

async function handleRelease(request, env) {
  // TODO(phase3-A):
  // 1. Parse body: {install_token}.
  // 2. hash = sha256(install_token); subdomain = TOKEN_INDEX.get(hash).
  //    If null -> 404 (idempotent for uninstall).
  // 3. Read reservation for cf_record_id.
  // 4. Delete CF DNS record via CF API.
  // 5. Delete TOKEN_INDEX[hash], SUBDOMAIN_RESERVATIONS[subdomain].
  // 6. Return {released: true}.
  return notImplemented("release");
}

async function handleHealth(request, env) {
  // TODO(phase3-A): require Authorization: Bearer env.ADMIN_TOKEN.
  // Return {status, active_reservations, uptime_seconds}.
  return notImplemented("health");
}

// ---------- scheduled sweep ----------

async function sweepExpired(env) {
  // TODO(phase3-A):
  // 1. List SUBDOMAIN_RESERVATIONS keys (paginated).
  // 2. For each: read value, if expires_at < now() ->
  //    a. Delete CF DNS record (cf_record_id).
  //    b. Delete TOKEN_INDEX[install_token_hash].
  //    c. Delete SUBDOMAIN_RESERVATIONS[subdomain].
  // 3. Emit metric: swept_count.
  console.log("sweepExpired: not implemented");
}

// ---------- router ----------

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    if (method === "POST" && path === "/api/provision") {
      return handleProvision(request, env);
    }
    if (method === "POST" && path === "/api/heartbeat") {
      return handleHeartbeat(request, env);
    }
    if (method === "DELETE" && path === "/api/release") {
      return handleRelease(request, env);
    }
    if (method === "GET" && path === "/api/health") {
      return handleHealth(request, env);
    }

    return jsonResponse(404, { error: "not_found", path });
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(sweepExpired(env));
  },
};
