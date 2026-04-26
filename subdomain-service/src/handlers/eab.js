// /api/eab — return ACME External Account Binding credentials for the
// fallback CA chain. install.sh calls this only when its primary CA
// (Let's Encrypt) is rate-limited and it needs to retry against ZeroSSL.
//
// Auth: install_token must resolve to a live reservation (same check as
// heartbeat / dns-challenge — token binds to a single FQDN).
//
// Currently supports:
//   ca = "zerossl"  → Worker's master ZeroSSL EAB pair. Free, ~unlimited
//                     for verified accounts.
//   ca = "gts"      → Google Trust Services EAB pair. Independent
//                     rate-limit budget; free Public CA tier (no GCP
//                     billing charges, project must have billing
//                     account attached for API enable).
//
// Multiple ACME accounts can be registered against the same EAB; each
// install gets its own ACME account keypair locally, so rate-limit
// accounting is independent per-install on the CA's side.
//
// Why we don't bake EAB into the /api/provision response:
//   - EAB is sensitive (whoever holds it can register fake ACME accounts
//     under our umbrella). install.sh only needs it on cert-issue
//     fallback, which is rare. Lazy-load minimizes exposure.
//   - Per-CA expansion stays simple — separate endpoint keeps the
//     provision response stable.

import { jsonResponse } from "../lib/response.js";
import { sha256Hex } from "../lib/crypto.js";

const SUPPORTED_CAS = new Set(["zerossl", "gts"]);

const CA_DESCRIPTORS = {
  zerossl: {
    directory: "https://acme.zerossl.com/v2/DV90",
    kidEnv: "ZEROSSL_EAB_KID",
    hmacEnv: "ZEROSSL_EAB_HMAC",
  },
  gts: {
    // Google Trust Services Public CA (production endpoint).
    directory: "https://dv.acme-v02.api.pki.goog/directory",
    kidEnv: "GTS_EAB_KID",
    hmacEnv: "GTS_EAB_HMAC",
  },
};

async function readBody(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return { error: jsonResponse(400, { error: "invalid_json" }) };
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return { error: jsonResponse(400, { error: "invalid_json" }) };
  }
  const token = body.install_token;
  if (typeof token !== "string" || token.length < 10 || token.length > 256) {
    return { error: jsonResponse(400, { error: "missing_install_token" }) };
  }
  const ca = body.ca || "zerossl";
  if (typeof ca !== "string" || !SUPPORTED_CAS.has(ca)) {
    return { error: jsonResponse(400, { error: "unsupported_ca", supported: [...SUPPORTED_CAS] }) };
  }
  return { token, ca };
}

export async function handleEab(request, env) {
  const parsed = await readBody(request);
  if (parsed.error) return parsed.error;

  const hash = await sha256Hex(parsed.token);
  const subdomain = await env.TOKEN_INDEX.get(hash);
  if (!subdomain) {
    return jsonResponse(404, { error: "unknown_token" });
  }

  const raw = await env.SUBDOMAIN_RESERVATIONS.get(subdomain);
  if (!raw) {
    // Stale index entry — clean up so future polls fail fast.
    await env.TOKEN_INDEX.delete(hash);
    return jsonResponse(404, { error: "unknown_token" });
  }

  const desc = CA_DESCRIPTORS[parsed.ca];
  const kid = env[desc.kidEnv];
  const hmac = env[desc.hmacEnv];
  if (!kid || !hmac) {
    console.error("eab: secrets_missing", { subdomain, ca: parsed.ca });
    return jsonResponse(503, { error: "ca_not_configured", ca: parsed.ca });
  }
  console.log("eab: issued", { subdomain, ca: parsed.ca, token_hash_prefix: hash.slice(0, 8) });
  return jsonResponse(200, {
    ca: parsed.ca,
    acme_directory_url: desc.directory,
    eab_kid: kid,
    eab_hmac_key: hmac,
    // CAs require a registration email on ACME account creation. The
    // install's FQDN-derived address is fine — only used for cert-
    // expiry notices, and we control sygen.pro.
    acme_account_email: `${subdomain}@${env.SYGEN_DOMAIN}`,
  });
}
