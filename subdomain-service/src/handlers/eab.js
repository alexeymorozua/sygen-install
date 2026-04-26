// /api/eab — return ACME External Account Binding credentials for the
// fallback CA chain. install.sh calls this only when its primary CA
// (Let's Encrypt) is rate-limited and it needs to retry against ZeroSSL.
//
// Auth: install_token must resolve to a live reservation (same check as
// heartbeat / dns-challenge — token binds to a single FQDN).
//
// Currently supports:
//   ca = "zerossl"  → returns Worker's master ZeroSSL EAB pair. Multiple
//                     ACME accounts can be registered against the same
//                     EAB; each install gets its own ACME account keypair
//                     locally so rate-limit accounting is independent
//                     per-install on ZeroSSL's side.
//
// Why we don't bake EAB into the /api/provision response:
//   - EAB is sensitive (whoever holds it can register fake ACME accounts
//     under our ZeroSSL umbrella). install.sh only needs it on cert-issue
//     fallback, which is rare. Lazy-load minimizes exposure.
//   - Future per-CA expansion (GTS, etc.) — separate endpoint keeps the
//     provision response stable.

import { jsonResponse } from "../lib/response.js";
import { sha256Hex } from "../lib/crypto.js";

const SUPPORTED_CAS = new Set(["zerossl"]);

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

  if (parsed.ca === "zerossl") {
    const kid = env.ZEROSSL_EAB_KID;
    const hmac = env.ZEROSSL_EAB_HMAC;
    if (!kid || !hmac) {
      console.error("eab: zerossl_secrets_missing", { subdomain });
      return jsonResponse(503, { error: "ca_not_configured", ca: "zerossl" });
    }
    console.log("eab: issued", { subdomain, ca: "zerossl", token_hash_prefix: hash.slice(0, 8) });
    return jsonResponse(200, {
      ca: "zerossl",
      acme_directory_url: "https://acme.zerossl.com/v2/DV90",
      eab_kid: kid,
      eab_hmac_key: hmac,
      // ZeroSSL requires a registration email on ACME account creation.
      // Use the install's FQDN-derived address — ZeroSSL only sends cert-
      // expiry notices there, and we control sygen.pro.
      acme_account_email: `${subdomain}@${env.SYGEN_DOMAIN}`,
    });
  }

  // Should be unreachable thanks to SUPPORTED_CAS check above.
  return jsonResponse(400, { error: "unsupported_ca" });
}
