// In-process rate limiter for /api/provision. Defense-in-depth alongside the
// CF WAF rule the operator is asked to configure — the Worker enforces this
// even if the WAF rule is missing, so an attacker can't burn through the
// 1200/5min CF API quota for our zone.
//
// Sliding window is implemented as a fixed 1-hour bucket keyed on
// CF-Connecting-IP. KV has no atomic increment, but at the configured cap
// (5/h) the read↔write race is harmless: at worst a single extra request
// slips through per concurrent burst.

const WINDOW_MS = 3600_000;
const DEFAULT_CAP = 5;
const KEY_PREFIX = "RATELIMIT:";
// TTL > window so the bucket is still readable for the full window even if
// it was written near the start. Worker KV expires keys best-effort.
const EXPIRATION_TTL = 7200;

export async function checkRateLimit(env, ip, now = Date.now()) {
  const cap = parseInt(env.PROVISION_RATE_LIMIT || String(DEFAULT_CAP), 10);
  const window = Math.floor(now / WINDOW_MS);
  const key = `${KEY_PREFIX}${ip}:${window}`;

  const current = parseInt(
    (await env.SUBDOMAIN_RESERVATIONS.get(key)) ?? "0",
    10,
  );
  if (current >= cap) {
    const retryAfter = Math.ceil((WINDOW_MS - (now % WINDOW_MS)) / 1000);
    return { allowed: false, retryAfter, current, cap };
  }

  await env.SUBDOMAIN_RESERVATIONS.put(key, String(current + 1), {
    expirationTtl: EXPIRATION_TTL,
  });
  return { allowed: true, current: current + 1, cap };
}
