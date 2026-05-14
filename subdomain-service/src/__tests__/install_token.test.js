import { test } from "node:test";
import assert from "node:assert/strict";

import { handleInstallToken } from "../handlers/install_token.js";
import { sha256Hex } from "../lib/crypto.js";

function makeKv(initial = {}) {
  const data = new Map(Object.entries(initial));
  return {
    data,
    async get(key) { return data.has(key) ? data.get(key) : null; },
    async put(key, value /* opts ignored — TTL is best-effort in tests */) {
      data.set(key, value);
    },
    async delete(key) { data.delete(key); },
  };
}

function makeEnv() {
  return {
    SUBDOMAIN_RESERVATIONS: makeKv(),
    TOKEN_INDEX: makeKv(),
  };
}

function tokenRequest({ method = "POST", ip = "203.0.113.10" } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (ip) headers["CF-Connecting-IP"] = ip;
  return new Request("https://install.sygen.pro/api/bootstrap/install-token", {
    method,
    headers,
  });
}

test("install_token: returns token + ttl on POST with valid IP", async () => {
  const env = makeEnv();
  const resp = await handleInstallToken(tokenRequest(), env);
  assert.equal(resp.status, 200);
  const body = await resp.json();
  assert.equal(body.ok, true);
  assert.ok(typeof body.install_token === "string");
  assert.ok(body.install_token.startsWith("sit_anon_"));
  assert.equal(body.ttl_seconds, 3600);
});

test("install_token: 405 on GET (not POST)", async () => {
  const env = makeEnv();
  const resp = await handleInstallToken(tokenRequest({ method: "GET" }), env);
  assert.equal(resp.status, 405);
  const body = await resp.json();
  assert.equal(body.error, "method_not_allowed");
});

test("install_token: rate-limited after 60 issuances per IP per hour", async () => {
  const env = makeEnv();
  for (let i = 0; i < 60; i++) {
    const resp = await handleInstallToken(tokenRequest(), env);
    assert.equal(resp.status, 200, `request #${i + 1} should be allowed`);
  }
  const blocked = await handleInstallToken(tokenRequest(), env);
  assert.equal(blocked.status, 429);
  const body = await blocked.json();
  assert.equal(body.error, "rate_limited");
});

test("install_token: rate-limit isolated per IP", async () => {
  const env = makeEnv();
  // Burn IP A's bucket.
  for (let i = 0; i < 60; i++) {
    await handleInstallToken(tokenRequest({ ip: "203.0.113.10" }), env);
  }
  const blockedA = await handleInstallToken(tokenRequest({ ip: "203.0.113.10" }), env);
  assert.equal(blockedA.status, 429);

  // IP B starts fresh.
  const okB = await handleInstallToken(tokenRequest({ ip: "203.0.113.11" }), env);
  assert.equal(okB.status, 200, "second IP should not share first IP's bucket");
});

test("install_token: registers issued token in TOKEN_INDEX with 'anonymous' value", async () => {
  const env = makeEnv();
  const resp = await handleInstallToken(tokenRequest(), env);
  assert.equal(resp.status, 200);
  const body = await resp.json();
  const hash = await sha256Hex(body.install_token);
  const stored = await env.TOKEN_INDEX.get(hash);
  assert.equal(stored, "anonymous");
});

test("install_token: handles missing CF-Connecting-IP header (uses 'unknown' bucket)", async () => {
  const env = makeEnv();
  const headers = { "Content-Type": "application/json" };
  const req = new Request("https://install.sygen.pro/api/bootstrap/install-token", {
    method: "POST",
    headers,
  });
  const resp = await handleInstallToken(req, env);
  assert.equal(resp.status, 200);
});

test("install_token: each call returns a unique token", async () => {
  const env = makeEnv();
  const a = await (await handleInstallToken(tokenRequest(), env)).json();
  const b = await (await handleInstallToken(tokenRequest(), env)).json();
  assert.notEqual(a.install_token, b.install_token);
});
