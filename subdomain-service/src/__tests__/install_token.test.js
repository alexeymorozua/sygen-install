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
  // 4h TTL — see TOKEN_TTL_SECONDS rationale in handler.
  assert.equal(body.ttl_seconds, 14400);
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

test("install_token: IPv6 addresses in same /64 share rate-limit bucket", async () => {
  const env = makeEnv();
  // Burn the bucket using one IPv6 address inside the /64.
  for (let i = 0; i < 60; i++) {
    const resp = await handleInstallToken(
      tokenRequest({ ip: "2001:db8:1:2:0:0:0:1" }),
      env,
    );
    assert.equal(resp.status, 200, `request #${i + 1} should be allowed`);
  }
  // A different host in the SAME /64 should now be blocked — without
  // /64 normalization this address would get its own 60-quota bucket.
  const blocked = await handleInstallToken(
    tokenRequest({ ip: "2001:db8:1:2:ffff:ffff:ffff:ffff" }),
    env,
  );
  assert.equal(blocked.status, 429);

  // A host in a DIFFERENT /64 must still be fresh.
  const ok = await handleInstallToken(
    tokenRequest({ ip: "2001:db8:1:3::1" }),
    env,
  );
  assert.equal(ok.status, 200, "different /64 should not share the bucket");
});

test("install_token: IPv6 :: shorthand collapses to the same /64 bucket", async () => {
  const env = makeEnv();
  // ::1 expands to 0:0:0:0:0:0:0:1; both should hash to the same /64.
  for (let i = 0; i < 60; i++) {
    const resp = await handleInstallToken(tokenRequest({ ip: "::1" }), env);
    assert.equal(resp.status, 200);
  }
  const blocked = await handleInstallToken(
    tokenRequest({ ip: "0:0:0:0:1234:5678:9abc:def0" }),
    env,
  );
  assert.equal(blocked.status, 429);
});

test("install_token: IPv4 unchanged (no /64 normalization)", async () => {
  const env = makeEnv();
  // Two IPv4 addresses that would share an IPv6-style /64 if mishandled
  // — but IPv4 must remain per-address.
  for (let i = 0; i < 60; i++) {
    await handleInstallToken(tokenRequest({ ip: "203.0.113.10" }), env);
  }
  const blocked = await handleInstallToken(
    tokenRequest({ ip: "203.0.113.10" }),
    env,
  );
  assert.equal(blocked.status, 429);
  // Different IPv4 address must NOT be affected.
  const ok = await handleInstallToken(
    tokenRequest({ ip: "203.0.113.11" }),
    env,
  );
  assert.equal(ok.status, 200);
});
