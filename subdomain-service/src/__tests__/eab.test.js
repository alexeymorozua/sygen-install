import { test } from "node:test";
import assert from "node:assert/strict";

import { handleEab } from "../handlers/eab.js";
import { sha256Hex } from "../lib/crypto.js";

function makeKv(initial = {}) {
  const data = new Map(Object.entries(initial));
  return {
    data,
    async get(key) { return data.has(key) ? data.get(key) : null; },
    async put(key, value) { data.set(key, value); },
    async delete(key) { data.delete(key); },
  };
}

async function makeEnvWithReservation({ withSecrets = true } = {}) {
  const token = "sit_test_eab_token_123456789abcdef";
  const hash = await sha256Hex(token);
  const subdomain = "abcd2345";
  const reservation = {
    subdomain,
    install_token_hash: hash,
    created_at: "2026-04-26T00:00:00Z",
    last_heartbeat_at: "2026-04-26T00:00:00Z",
    expires_at: "2026-05-26T00:00:00Z",
    allocated_to_ip: "203.0.113.7",
    cf_record_id: "rec-abc",
  };
  const env = {
    SYGEN_DOMAIN: "sygen.pro",
    SUBDOMAIN_RESERVATIONS: makeKv({ [subdomain]: JSON.stringify(reservation) }),
    TOKEN_INDEX: makeKv({ [hash]: subdomain }),
  };
  if (withSecrets) {
    env.ZEROSSL_EAB_KID = "test-kid-DzBKsOIo";
    env.ZEROSSL_EAB_HMAC = "test-hmac-fdWlPwxdEScrtcHuE8eWgtq";
    env.GTS_EAB_KID = "test-kid-d4a54bdc";
    env.GTS_EAB_HMAC = "test-hmac-HLTWM97KHrrfuIGOjdQ";
  }
  return { env, token, subdomain };
}

function eabRequest(body) {
  return new Request("https://install.sygen.pro/api/eab", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

test("eab: happy path returns ZeroSSL credentials for live token", async () => {
  const { env, token, subdomain } = await makeEnvWithReservation();
  const resp = await handleEab(eabRequest({ install_token: token, ca: "zerossl" }), env);
  assert.equal(resp.status, 200);
  const body = await resp.json();
  assert.equal(body.ca, "zerossl");
  assert.equal(body.eab_kid, "test-kid-DzBKsOIo");
  assert.equal(body.eab_hmac_key, "test-hmac-fdWlPwxdEScrtcHuE8eWgtq");
  assert.equal(body.acme_directory_url, "https://acme.zerossl.com/v2/DV90");
  assert.equal(body.acme_account_email, `${subdomain}@sygen.pro`);
});

test("eab: defaults ca to zerossl when omitted", async () => {
  const { env, token } = await makeEnvWithReservation();
  const resp = await handleEab(eabRequest({ install_token: token }), env);
  assert.equal(resp.status, 200);
  const body = await resp.json();
  assert.equal(body.ca, "zerossl");
});

test("eab: rejects unknown CA", async () => {
  const { env, token } = await makeEnvWithReservation();
  const resp = await handleEab(eabRequest({ install_token: token, ca: "buypass" }), env);
  assert.equal(resp.status, 400);
  const body = await resp.json();
  assert.equal(body.error, "unsupported_ca");
  assert.deepEqual(body.supported.sort(), ["gts", "zerossl"]);
});

test("eab: GTS happy path returns Google Trust Services credentials", async () => {
  const { env, token, subdomain } = await makeEnvWithReservation();
  const resp = await handleEab(eabRequest({ install_token: token, ca: "gts" }), env);
  assert.equal(resp.status, 200);
  const body = await resp.json();
  assert.equal(body.ca, "gts");
  assert.equal(body.eab_kid, "test-kid-d4a54bdc");
  assert.equal(body.eab_hmac_key, "test-hmac-HLTWM97KHrrfuIGOjdQ");
  assert.equal(body.acme_directory_url, "https://dv.acme-v02.api.pki.goog/directory");
  assert.equal(body.acme_account_email, `${subdomain}@sygen.pro`);
});

test("eab: GTS 503 when secrets missing", async () => {
  const { env, token } = await makeEnvWithReservation({ withSecrets: false });
  const resp = await handleEab(eabRequest({ install_token: token, ca: "gts" }), env);
  assert.equal(resp.status, 503);
  const body = await resp.json();
  assert.equal(body.error, "ca_not_configured");
  assert.equal(body.ca, "gts");
});

test("eab: 404 for unknown install_token (not in TOKEN_INDEX)", async () => {
  const { env } = await makeEnvWithReservation();
  const resp = await handleEab(
    eabRequest({ install_token: "sit_unknown_xxxxxxxxxxxxxxxx", ca: "zerossl" }),
    env,
  );
  assert.equal(resp.status, 404);
  const body = await resp.json();
  assert.equal(body.error, "unknown_token");
});

test("eab: 404 + cleans stale TOKEN_INDEX when reservation gone", async () => {
  const { env, token } = await makeEnvWithReservation();
  // Simulate a swept reservation: token index still points but reservation deleted.
  await env.SUBDOMAIN_RESERVATIONS.delete("abcd2345");

  const resp = await handleEab(eabRequest({ install_token: token, ca: "zerossl" }), env);
  assert.equal(resp.status, 404);
  const body = await resp.json();
  assert.equal(body.error, "unknown_token");

  // Stale TOKEN_INDEX entry was purged.
  const hash = await sha256Hex(token);
  assert.equal(await env.TOKEN_INDEX.get(hash), null);
});

test("eab: 503 when ZeroSSL secrets missing in env", async () => {
  const { env, token } = await makeEnvWithReservation({ withSecrets: false });
  const resp = await handleEab(eabRequest({ install_token: token, ca: "zerossl" }), env);
  assert.equal(resp.status, 503);
  const body = await resp.json();
  assert.equal(body.error, "ca_not_configured");
  assert.equal(body.ca, "zerossl");
});

test("eab: 400 on missing install_token", async () => {
  const { env } = await makeEnvWithReservation();
  const resp = await handleEab(eabRequest({}), env);
  assert.equal(resp.status, 400);
  const body = await resp.json();
  assert.equal(body.error, "missing_install_token");
});

test("eab: 400 on too-short install_token (<10 chars)", async () => {
  const { env } = await makeEnvWithReservation();
  const resp = await handleEab(eabRequest({ install_token: "short" }), env);
  assert.equal(resp.status, 400);
  const body = await resp.json();
  assert.equal(body.error, "missing_install_token");
});

test("eab: 400 on too-long install_token (>256 chars)", async () => {
  const { env } = await makeEnvWithReservation();
  const longToken = "x".repeat(257);
  const resp = await handleEab(eabRequest({ install_token: longToken }), env);
  assert.equal(resp.status, 400);
});

test("eab: 400 on non-object body (array/null/scalar)", async () => {
  const { env } = await makeEnvWithReservation();
  for (const bad of ["null", "[]", '"hi"', "42"]) {
    const resp = await handleEab(eabRequest(bad), env);
    assert.equal(resp.status, 400, `body ${bad} should reject`);
  }
});

test("eab: 400 on malformed JSON", async () => {
  const { env } = await makeEnvWithReservation();
  const req = new Request("https://install.sygen.pro/api/eab", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{not json}",
  });
  const resp = await handleEab(req, env);
  assert.equal(resp.status, 400);
  const body = await resp.json();
  assert.equal(body.error, "invalid_json");
});

test("eab: ca field validates string type", async () => {
  const { env, token } = await makeEnvWithReservation();
  const resp = await handleEab(eabRequest({ install_token: token, ca: 42 }), env);
  assert.equal(resp.status, 400);
  const body = await resp.json();
  assert.equal(body.error, "unsupported_ca");
});
