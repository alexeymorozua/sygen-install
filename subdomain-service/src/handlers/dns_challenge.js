import { jsonResponse } from "../lib/response.js";
import { sha256Hex } from "../lib/crypto.js";
import {
  createTxtRecord,
  deleteDnsRecord,
  listTxtRecords,
  CfApiError,
} from "../lib/cf.js";

// Worker-mediated ACME DNS-01 challenge. install.sh's certbot manual hooks
// POST/DELETE here instead of holding a Cloudflare token themselves. The
// Worker only mutates the single TXT name that belongs to the install_token's
// own subdomain — see PHASE3_TLS_token_scoping_decision.md for the rationale.

async function readBody(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return { error: jsonResponse(400, { error: "invalid_json" }) };
  }
  if (!body || typeof body !== "object") {
    return { error: jsonResponse(400, { error: "invalid_body" }) };
  }
  return { body };
}

function isValidToken(token) {
  return typeof token === "string" && token.length >= 10 && token.length <= 256;
}

async function lookupSubdomain(env, token) {
  const hash = await sha256Hex(token);
  const subdomain = await env.TOKEN_INDEX.get(hash);
  if (!subdomain) return { error: jsonResponse(401, { error: "invalid_install_token" }) };
  const raw = await env.SUBDOMAIN_RESERVATIONS.get(subdomain);
  if (!raw) {
    await env.TOKEN_INDEX.delete(hash);
    return { error: jsonResponse(401, { error: "invalid_install_token" }) };
  }
  return { subdomain, reservation: JSON.parse(raw) };
}

function expectedChallengeName(subdomain, env) {
  return `_acme-challenge.${subdomain}.${env.SYGEN_DOMAIN}`;
}

export async function handleDnsChallengePost(request, env) {
  const parsed = await readBody(request);
  if (parsed.error) return parsed.error;
  const { install_token: token, name, value, ttl } = parsed.body;

  if (!isValidToken(token)) {
    return jsonResponse(400, { error: "missing_install_token" });
  }
  if (typeof name !== "string" || typeof value !== "string" || value.length === 0) {
    return jsonResponse(400, { error: "missing_name_or_value" });
  }

  const lookup = await lookupSubdomain(env, token);
  if (lookup.error) return lookup.error;
  const { subdomain, reservation } = lookup;

  const expected = expectedChallengeName(subdomain, env);
  if (name !== expected) {
    console.error("dns_challenge: name_mismatch", {
      subdomain,
      got: name,
      expected,
    });
    return jsonResponse(403, { error: "name_outside_owned_subdomain" });
  }

  const ttlSec = Number.isInteger(ttl) && ttl >= 60 && ttl <= 600 ? ttl : 60;

  let record;
  try {
    record = await createTxtRecord(env, name, value, ttlSec);
  } catch (e) {
    console.error("dns_challenge: cf_create_failed", {
      subdomain,
      status: e instanceof CfApiError ? e.status : null,
      message: e.message,
    });
    return jsonResponse(502, { error: "dns_create_failed" });
  }

  reservation.dns_challenge_record_id = record.id;
  await env.SUBDOMAIN_RESERVATIONS.put(subdomain, JSON.stringify(reservation));

  console.log("dns_challenge: created", { subdomain, record_id: record.id });
  return jsonResponse(200, { ok: true, record_id: record.id });
}

export async function handleDnsChallengeDelete(request, env) {
  const parsed = await readBody(request);
  if (parsed.error) return parsed.error;
  const { install_token: token, name } = parsed.body;

  if (!isValidToken(token)) {
    return jsonResponse(400, { error: "missing_install_token" });
  }
  if (typeof name !== "string") {
    return jsonResponse(400, { error: "missing_name" });
  }

  const lookup = await lookupSubdomain(env, token);
  if (lookup.error) return lookup.error;
  const { subdomain, reservation } = lookup;

  const expected = expectedChallengeName(subdomain, env);
  if (name !== expected) {
    return jsonResponse(403, { error: "name_outside_owned_subdomain" });
  }

  // Prefer the stored id (cheap), fall back to listing — handles the case
  // where install.sh restarted between auth + cleanup hooks and lost the
  // reservation update from POST.
  let recordIds = [];
  if (reservation.dns_challenge_record_id) {
    recordIds.push(reservation.dns_challenge_record_id);
  } else {
    try {
      const list = await listTxtRecords(env, name);
      recordIds = (list || []).map((r) => r.id);
    } catch (e) {
      console.error("dns_challenge: cf_list_failed", {
        subdomain,
        status: e instanceof CfApiError ? e.status : null,
        message: e.message,
      });
      return jsonResponse(502, { error: "dns_list_failed" });
    }
  }

  if (recordIds.length === 0) {
    // Already gone — idempotent.
    return jsonResponse(200, { ok: true, deleted: 0 });
  }

  let deleted = 0;
  for (const id of recordIds) {
    try {
      await deleteDnsRecord(env, id);
      deleted++;
    } catch (e) {
      // 404 = already gone. Anything else is logged but doesn't block —
      // cleanup is best-effort, sweep will retry.
      if (e instanceof CfApiError && e.status === 404) {
        deleted++;
      } else {
        console.error("dns_challenge: cf_delete_failed", {
          subdomain,
          record_id: id,
          status: e instanceof CfApiError ? e.status : null,
          message: e.message,
        });
      }
    }
  }

  if (reservation.dns_challenge_record_id) {
    delete reservation.dns_challenge_record_id;
    await env.SUBDOMAIN_RESERVATIONS.put(subdomain, JSON.stringify(reservation));
  }

  console.log("dns_challenge: deleted", { subdomain, deleted });
  return jsonResponse(200, { ok: true, deleted });
}
