// Sygen subdomain provisioning Worker.
//
// Endpoints (see PHASE3_subdomain_provisioning_design.md in sygen-clean):
//   POST   /api/provision  — allocate a fresh <id>.sygen.pro
//   POST   /api/heartbeat  — extend reservation TTL
//   DELETE /api/release    — free reservation on uninstall
//   GET    /api/health     — admin health check
//
// Scheduled:
//   Daily cron — sweep expired reservations (cf_record_id + KV).
//
// Per-IP / per-token rate limits are enforced by Cloudflare zone rules
// in front of the Worker; see README.md for setup.

import { jsonResponse } from "./lib/response.js";
import { handleProvision } from "./handlers/provision.js";
import { handleHeartbeat } from "./handlers/heartbeat.js";
import { handleRelease } from "./handlers/release.js";
import { handleHealth } from "./handlers/health.js";
import { sweepExpired } from "./sweep.js";

async function route(request, env) {
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
}

export default {
  async fetch(request, env, ctx) {
    try {
      return await route(request, env);
    } catch (e) {
      console.error("worker: unhandled", { message: e?.message, stack: e?.stack });
      return jsonResponse(500, { error: "internal_error" });
    }
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(sweepExpired(env).catch((e) => {
      console.error("scheduled: sweep_failed", { message: e?.message });
    }));
  },
};
