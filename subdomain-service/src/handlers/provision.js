import { jsonResponse } from "../lib/response.js";
import { generateInstallToken, sha256Hex } from "../lib/crypto.js";
import { generateSubdomain, isReserved, dnsRecordTypeForIp } from "../lib/subdomain.js";
import { createDnsRecord, deleteDnsRecord, CfApiError } from "../lib/cf.js";
import { checkRateLimit } from "../lib/ratelimit.js";

const MAX_CLAIM_ATTEMPTS = 4;

export async function handleProvision(request, env) {
  // Body must be valid JSON or empty. Reject anything else early so we
  // don't silently accept malformed callers.
  const ct = request.headers.get("Content-Type") || "";
  let body = null;
  if (request.body) {
    if (!ct.toLowerCase().startsWith("application/json") && ct !== "") {
      return jsonResponse(415, { error: "unsupported_media_type" });
    }
    const text = await request.text();
    if (text.trim().length > 0) {
      try { body = JSON.parse(text); } catch {
        return jsonResponse(400, { error: "invalid_json" });
      }
      if (body === null || typeof body !== "object" || Array.isArray(body)) {
        return jsonResponse(400, { error: "invalid_json" });
      }
    }
  }

  // CF-Connecting-IP is the rate-limit key (always the TCP peer). Body's
  // optional {public_ip} overrides only the DNS record target — used by
  // macOS publicdomain mode where the install.sh runs from inside the LAN
  // but needs the A record to point at the WAN IP discovered via STUN.
  // The override is restricted to public unicast IPs (RFC1918/CGNAT/etc
  // would brick the subdomain — see dnsRecordTypeForIp).
  const callerIp = request.headers.get("CF-Connecting-IP");
  const callerDnsType = dnsRecordTypeForIp(callerIp);
  if (!callerDnsType) {
    return jsonResponse(400, { error: "missing_or_invalid_caller_ip" });
  }

  let dnsTargetIp = callerIp;
  let dnsType = callerDnsType;
  if (body && typeof body.public_ip === "string" && body.public_ip.length > 0) {
    const overrideType = dnsRecordTypeForIp(body.public_ip);
    if (!overrideType) {
      return jsonResponse(400, { error: "invalid_public_ip" });
    }
    dnsTargetIp = body.public_ip;
    dnsType = overrideType;
  }

  // Defense-in-depth IP rate limit. Operator is also asked to configure a
  // CF WAF rule with the same shape; this guard kicks in even if that's
  // skipped so an attacker can't burn the 1200/5min CF API quota for the
  // zone.
  const rl = await checkRateLimit(env, callerIp);
  if (!rl.allowed) {
    console.warn("provision: rate_limited", { ip: callerIp, cap: rl.cap });
    return jsonResponse(
      429,
      { error: "rate_limited", retry_after: rl.retryAfter },
      { "Retry-After": String(rl.retryAfter) },
    );
  }

  // Atomic-ish claim. KV has no native CAS, so race window is the read↔write
  // gap (~50 ms). At 32^8 address space the probability of a real collision
  // is vanishing; retries are belt-and-braces.
  let subdomain = null;
  for (let i = 0; i < MAX_CLAIM_ATTEMPTS; i++) {
    const candidate = generateSubdomain(parseInt(env.SUBDOMAIN_LENGTH || "8", 10));
    if (isReserved(candidate)) continue;
    const existing = await env.SUBDOMAIN_RESERVATIONS.get(candidate);
    if (existing !== null) continue;
    subdomain = candidate;
    break;
  }
  if (!subdomain) {
    console.error("provision: claim_exhausted", { attempts: MAX_CLAIM_ATTEMPTS });
    return jsonResponse(503, { error: "subdomain_pool_exhausted" });
  }

  const fqdn = `${subdomain}.${env.SYGEN_DOMAIN}`;
  const installToken = generateInstallToken();
  const tokenHash = await sha256Hex(installToken);

  let record;
  try {
    record = await createDnsRecord(env, fqdn, dnsTargetIp, dnsType);
  } catch (e) {
    console.error("provision: dns_create_failed", {
      subdomain,
      status: e instanceof CfApiError ? e.status : null,
      message: e.message,
    });
    return jsonResponse(503, { error: "dns_create_failed" });
  }

  const now = new Date();
  const ttlDays = parseInt(env.TTL_DAYS || "30", 10);
  const expiresAt = new Date(now.getTime() + ttlDays * 86400 * 1000);

  const reservation = {
    subdomain,
    install_token_hash: tokenHash,
    created_at: now.toISOString(),
    last_heartbeat_at: now.toISOString(),
    expires_at: expiresAt.toISOString(),
    allocated_to_ip: dnsTargetIp,
    cf_record_id: record.id,
  };

  try {
    await Promise.all([
      env.SUBDOMAIN_RESERVATIONS.put(subdomain, JSON.stringify(reservation)),
      env.TOKEN_INDEX.put(tokenHash, subdomain),
    ]);
  } catch (e) {
    // KV write failed — without a reservation row the daily sweep can't
    // reclaim the just-created A record, so roll it back synchronously.
    console.error("provision: kv_put_failed", {
      subdomain,
      record_id: record.id,
      message: e.message,
    });
    try {
      await deleteDnsRecord(env, record.id);
    } catch (rollbackErr) {
      console.error("provision: dns_rollback_failed", {
        subdomain,
        record_id: record.id,
        message: rollbackErr.message,
      });
    }
    return jsonResponse(503, { error: "kv_put_failed" });
  }

  console.log("provision: ok", {
    subdomain,
    record_id: record.id,
    ip_hash: tokenHash.slice(0, 8),
  });

  return jsonResponse(200, {
    fqdn,
    install_token: installToken,
    ttl_days: ttlDays,
    heartbeat_url: `https://install.${env.SYGEN_DOMAIN}/api/heartbeat`,
    release_url: `https://install.${env.SYGEN_DOMAIN}/api/release`,
    dns_challenge_url: `https://install.${env.SYGEN_DOMAIN}/api/dns-challenge`,
  });
}
