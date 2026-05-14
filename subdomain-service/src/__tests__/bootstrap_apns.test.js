import { test } from "node:test";
import assert from "node:assert/strict";

import { handleBootstrapApns } from "../handlers/bootstrap_apns.js";
import { sha256Hex } from "../lib/crypto.js";

function makeKv(initial = {}) {
  const data = new Map(Object.entries(initial));
  return {
    data,
    async get(key) { return data.has(key) ? data.get(key) : null; },
    async put(key, value /* opts ignored — TTL is best-effort */) {
      data.set(key, value);
    },
    async delete(key) { data.delete(key); },
  };
}

async function makeEnvWithReservation({ withSecret = true } = {}) {
  const token = "sit_test_bootstrap_token_123456789abcdef";
  const hash = await sha256Hex(token);
  const subdomain = "wxyz0987";
  const reservation = {
    subdomain,
    install_token_hash: hash,
    created_at: "2026-05-14T00:00:00Z",
    last_heartbeat_at: "2026-05-14T00:00:00Z",
    expires_at: "2026-06-13T00:00:00Z",
    allocated_to_ip: "203.0.113.7",
    cf_record_id: "rec-bootstrap",
  };
  const env = {
    SYGEN_DOMAIN: "sygen.pro",
    APNS_KEY_ID: "RBJZU2A5KU",
    SUBDOMAIN_RESERVATIONS: makeKv({ [subdomain]: JSON.stringify(reservation) }),
    TOKEN_INDEX: makeKv({ [hash]: subdomain }),
  };
  if (withSecret) {
    // Realistic-ish base64 of a short stand-in payload — content doesn't
    // matter for these tests, only that the handler passes it through verbatim.
    env.APNS_AUTH_KEY_B64 = "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCnN0dWIKLS0tLS1FTkQ=";
  }
  return { env, token, subdomain };
}

function bootstrapRequest({ token, method = "POST" } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (token !== undefined) {
    headers["Authorization"] = `Bearer ${token}`;
  }
  return new Request("https://install.sygen.pro/api/bootstrap/apns", {
    method,
    headers,
  });
}

test("bootstrap_apns: returns key_id + key_b64 on valid token", async () => {
  const { env, token } = await makeEnvWithReservation();
  const resp = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(resp.status, 200);
  const body = await resp.json();
  assert.equal(body.ok, true);
  assert.equal(body.key_id, "RBJZU2A5KU");
  assert.equal(body.key_b64, env.APNS_AUTH_KEY_B64);
});

test("bootstrap_apns: returns team_id + bundle_id + environment when configured", async () => {
  const { env, token } = await makeEnvWithReservation();
  env.APNS_TEAM_ID = "4KQZ8D8P7T";
  env.APNS_BUNDLE_ID = "com.timedesign.sygen.ios";
  env.APNS_DEFAULT_ENVIRONMENT = "production";
  const resp = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(resp.status, 200);
  const body = await resp.json();
  assert.equal(body.team_id, "4KQZ8D8P7T");
  assert.equal(body.bundle_id, "com.timedesign.sygen.ios");
  assert.equal(body.environment, "production");
});

test("bootstrap_apns: falls back to empty team/bundle and 'production' env when not configured", async () => {
  const { env, token } = await makeEnvWithReservation();
  // No APNS_TEAM_ID / APNS_BUNDLE_ID / APNS_DEFAULT_ENVIRONMENT in env.
  const resp = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(resp.status, 200);
  const body = await resp.json();
  assert.equal(body.team_id, "");
  assert.equal(body.bundle_id, "");
  assert.equal(body.environment, "production");
});

test("bootstrap_apns: anonymous token (TOKEN_INDEX='anonymous') skips reservation lookup", async () => {
  const env = {
    SYGEN_DOMAIN: "sygen.pro",
    APNS_KEY_ID: "RBJZU2A5KU",
    APNS_AUTH_KEY_B64: "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCnN0dWIKLS0tLS1FTkQ=",
    SUBDOMAIN_RESERVATIONS: makeKv(),
    TOKEN_INDEX: makeKv(),
  };
  const anonToken = "sit_anon_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const hash = await sha256Hex(anonToken);
  await env.TOKEN_INDEX.put(hash, "anonymous");

  const resp = await handleBootstrapApns(bootstrapRequest({ token: anonToken }), env);
  assert.equal(resp.status, 200);
  const body = await resp.json();
  assert.equal(body.ok, true);
  assert.equal(body.key_id, "RBJZU2A5KU");
  // Anonymous lookup should NOT have created or required any reservation row.
  assert.equal(env.SUBDOMAIN_RESERVATIONS.data.has("anonymous"), false);
});

test("bootstrap_apns: anonymous token rate-limit still applies (one fetch per token / 24h)", async () => {
  const env = {
    SYGEN_DOMAIN: "sygen.pro",
    APNS_KEY_ID: "RBJZU2A5KU",
    APNS_AUTH_KEY_B64: "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCnN0dWIKLS0tLS1FTkQ=",
    SUBDOMAIN_RESERVATIONS: makeKv(),
    TOKEN_INDEX: makeKv(),
  };
  const anonToken = "sit_anon_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  const hash = await sha256Hex(anonToken);
  await env.TOKEN_INDEX.put(hash, "anonymous");

  const first = await handleBootstrapApns(bootstrapRequest({ token: anonToken }), env);
  assert.equal(first.status, 200);
  const second = await handleBootstrapApns(bootstrapRequest({ token: anonToken }), env);
  assert.equal(second.status, 429);
});

test("bootstrap_apns: 401 on missing Authorization header", async () => {
  const { env } = await makeEnvWithReservation();
  const resp = await handleBootstrapApns(bootstrapRequest(), env);
  assert.equal(resp.status, 401);
  const body = await resp.json();
  assert.equal(body.ok, false);
  assert.equal(body.error, "invalid_token");
});

test("bootstrap_apns: 401 on malformed Authorization header (not Bearer)", async () => {
  const { env, token } = await makeEnvWithReservation();
  const req = new Request("https://install.sygen.pro/api/bootstrap/apns", {
    method: "POST",
    headers: { "Authorization": `Basic ${token}` },
  });
  const resp = await handleBootstrapApns(req, env);
  assert.equal(resp.status, 401);
  const body = await resp.json();
  assert.equal(body.error, "invalid_token");
});

test("bootstrap_apns: 401 on too-short token (<10 chars)", async () => {
  const { env } = await makeEnvWithReservation();
  const resp = await handleBootstrapApns(bootstrapRequest({ token: "short" }), env);
  assert.equal(resp.status, 401);
  const body = await resp.json();
  assert.equal(body.error, "invalid_token");
});

test("bootstrap_apns: 401 on too-long token (>256 chars)", async () => {
  const { env } = await makeEnvWithReservation();
  const longToken = "x".repeat(257);
  const resp = await handleBootstrapApns(bootstrapRequest({ token: longToken }), env);
  assert.equal(resp.status, 401);
});

test("bootstrap_apns: 401 on token not in TOKEN_INDEX", async () => {
  const { env } = await makeEnvWithReservation();
  const resp = await handleBootstrapApns(
    bootstrapRequest({ token: "sit_unknown_xxxxxxxxxxxxxxxx" }),
    env,
  );
  assert.equal(resp.status, 401);
  const body = await resp.json();
  assert.equal(body.error, "invalid_token");
});

test("bootstrap_apns: 401 + cleans stale TOKEN_INDEX when reservation gone", async () => {
  const { env, token, subdomain } = await makeEnvWithReservation();
  await env.SUBDOMAIN_RESERVATIONS.delete(subdomain);
  const resp = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(resp.status, 401);
  const hash = await sha256Hex(token);
  assert.equal(await env.TOKEN_INDEX.get(hash), null);
});

test("bootstrap_apns: 503 when APNS_AUTH_KEY_B64 secret not configured", async () => {
  const { env, token } = await makeEnvWithReservation({ withSecret: false });
  const resp = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(resp.status, 503);
  const body = await resp.json();
  assert.equal(body.ok, false);
  assert.equal(body.error, "apns_not_configured");
});

test("bootstrap_apns: 503 when APNS_KEY_ID var not configured", async () => {
  const { env, token } = await makeEnvWithReservation();
  delete env.APNS_KEY_ID;
  const resp = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(resp.status, 503);
  const body = await resp.json();
  assert.equal(body.error, "apns_not_configured");
});

test("bootstrap_apns: rate-limited (429) on second successful fetch for same token", async () => {
  const { env, token } = await makeEnvWithReservation();
  const first = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(first.status, 200);
  const second = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(second.status, 429);
  const body = await second.json();
  assert.equal(body.ok, false);
  assert.equal(body.error, "rate_limited");
});

test("bootstrap_apns: rate-limit isolated per token", async () => {
  const { env, token } = await makeEnvWithReservation();
  // First token is consumed.
  await handleBootstrapApns(bootstrapRequest({ token }), env);

  // A second, independent token gets a fresh bucket.
  const otherToken = "sit_other_token_aaaaaaaaaaaaaaaaaaaa";
  const otherHash = await sha256Hex(otherToken);
  const otherSubdomain = "qrst5678";
  await env.SUBDOMAIN_RESERVATIONS.put(otherSubdomain, JSON.stringify({
    subdomain: otherSubdomain,
    install_token_hash: otherHash,
    created_at: "2026-05-14T00:00:00Z",
    last_heartbeat_at: "2026-05-14T00:00:00Z",
    expires_at: "2026-06-13T00:00:00Z",
    allocated_to_ip: "203.0.113.8",
    cf_record_id: "rec-other",
  }));
  await env.TOKEN_INDEX.put(otherHash, otherSubdomain);

  const resp = await handleBootstrapApns(bootstrapRequest({ token: otherToken }), env);
  assert.equal(resp.status, 200, "second token should not share first token's bucket");
});

test("bootstrap_apns: rate-limit fires BEFORE returning the key (no double-issue)", async () => {
  const { env, token } = await makeEnvWithReservation();
  // Two near-simultaneous calls: first wins, second must be blocked.
  const first = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(first.status, 200);
  const firstBody = await first.json();
  assert.ok(firstBody.key_b64);

  const second = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(second.status, 429);
  const secondBody = await second.json();
  assert.equal(secondBody.key_b64, undefined, "rate-limited response must not leak the key");
});

test("bootstrap_apns: no rate-limit bucket set when secret missing (503 stays retryable)", async () => {
  const { env, token } = await makeEnvWithReservation({ withSecret: false });
  const first = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(first.status, 503);
  // Operator can now `wrangler secret put APNS_AUTH_KEY_B64` and the next
  // call should succeed without waiting 24h.
  env.APNS_AUTH_KEY_B64 = "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCnN0dWIKLS0tLS1FTkQ=";
  const second = await handleBootstrapApns(bootstrapRequest({ token }), env);
  assert.equal(second.status, 200);
});
