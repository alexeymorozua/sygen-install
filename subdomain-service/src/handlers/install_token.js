// POST /api/bootstrap/install-token — issue an ephemeral install_token
// for use with /api/bootstrap/apns. Anonymous (no reservation), rate
// limited per CF-Connecting-IP.
//
// Context: install_token was previously only minted by /api/provision
// (the auto-mode subdomain path). Tailscale-mode installs never hit
// provision → no token → bootstrap_apns_key() skipped → .p8 never
// distributed → push stayed off. This endpoint closes that gap by
// minting a short-lived token without requiring subdomain reservation.
//
// Auth posture: anonymous + per-IP rate limit. Threat model is that a
// leaked .p8 lets an attacker push to our devices; no RCE / data
// exfil; recoverable by rotating the key in Apple Developer Portal.
// Follow-up (1-2 weeks): replace with App Attest gated endpoint.
//
// TOKEN_INDEX value is the literal string "anonymous" — bootstrap_apns
// detects this sentinel and skips the SUBDOMAIN_RESERVATIONS lookup,
// so anonymous tokens never collide with real subdomains.

import { jsonResponse } from "../lib/response.js";
import { sha256Hex } from "../lib/crypto.js";

const RATE_LIMIT_KEY_PREFIX = "IP_BOOTSTRAP:";
const RATE_LIMIT_TTL_SECONDS = 3600;
const RATE_LIMIT_MAX = 60;
const TOKEN_TTL_SECONDS = 3600;

function extractClientIP(request) {
  // CF-Connecting-IP is populated by Cloudflare edge and cannot be set
  // by the client. Safe to trust when this Worker runs behind CF.
  return request.headers.get("CF-Connecting-IP") || "unknown";
}

function generateToken() {
  const buf = new Uint8Array(32);
  crypto.getRandomValues(buf);
  let hex = "";
  for (let i = 0; i < buf.length; i++) {
    hex += buf[i].toString(16).padStart(2, "0");
  }
  return `sit_anon_${hex}`;
}

export async function handleInstallToken(request, env) {
  if (request.method !== "POST") {
    return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  }

  const ip = extractClientIP(request);
  const ipHash = await sha256Hex(ip);
  const ipPrefix = ipHash.slice(0, 8);
  const rateKey = `${RATE_LIMIT_KEY_PREFIX}${ipHash}`;

  const currentRaw = await env.SUBDOMAIN_RESERVATIONS.get(rateKey);
  const current = currentRaw ? parseInt(currentRaw, 10) : 0;
  if (current >= RATE_LIMIT_MAX) {
    console.warn("install_token: rate_limited", { ip_prefix: ipPrefix });
    return jsonResponse(429, { ok: false, error: "rate_limited" });
  }

  const token = generateToken();
  const tokenHash = await sha256Hex(token);

  await env.TOKEN_INDEX.put(tokenHash, "anonymous", {
    expirationTtl: TOKEN_TTL_SECONDS,
  });
  await env.SUBDOMAIN_RESERVATIONS.put(rateKey, String(current + 1), {
    expirationTtl: RATE_LIMIT_TTL_SECONDS,
  });

  console.log("install_token: issued", {
    ip_prefix: ipPrefix,
    count: current + 1,
  });

  return jsonResponse(200, {
    ok: true,
    install_token: token,
    ttl_seconds: TOKEN_TTL_SECONDS,
  });
}
