import { test } from "node:test";
import assert from "node:assert/strict";

import { handleProvision } from "../handlers/provision.js";

// In-memory KV stub matching the surface used by the provision handler.
function makeKv(initial = {}) {
  const data = new Map(Object.entries(initial));
  return {
    data,
    async get(key) { return data.has(key) ? data.get(key) : null; },
    async put(key, value /* opts ignored */) { data.set(key, value); },
    async delete(key) { data.delete(key); },
  };
}

// KV stub that throws on put for non-rate-limit keys. The rate limiter
// shares the SUBDOMAIN_RESERVATIONS namespace (with a RATELIMIT: prefix);
// failing those would block the request before the H-1 path is reached.
function makeFailingKv(initial = {}) {
  const kv = makeKv(initial);
  const realPut = kv.put.bind(kv);
  kv.put = async (key, value, opts) => {
    if (key.startsWith("RATELIMIT:")) return realPut(key, value, opts);
    throw new Error("kv unavailable");
  };
  return kv;
}

function provisionRequest(ip = "203.0.113.45") {
  return new Request("https://install.sygen.pro/api/provision", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "CF-Connecting-IP": ip,
    },
    body: "{}",
  });
}

function makeEnv(overrides = {}) {
  return {
    SYGEN_DOMAIN: "sygen.pro",
    SYGEN_CF_ZONE_ID: "ZONE",
    CF_MASTER_API_TOKEN: "stub",
    SUBDOMAIN_LENGTH: "8",
    TTL_DAYS: "30",
    SUBDOMAIN_RESERVATIONS: makeKv(),
    TOKEN_INDEX: makeKv(),
    ...overrides,
  };
}

function cfSuccess(result) {
  return new Response(
    JSON.stringify({ success: true, result, errors: [], messages: [] }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

// Stub global fetch with a programmable handler. fn(call) → Response.
function withMockFetch(fn, body) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const call = { url: String(url), method: init?.method || "GET", body: init?.body || null };
    calls.push(call);
    return fn(call);
  };
  return Promise.resolve(body(calls)).finally(() => { globalThis.fetch = original; });
}

test("provision: happy path creates DNS record and KV rows", () => {
  return withMockFetch(
    () => cfSuccess({ id: "rec-new-a" }),
    async (calls) => {
      const env = makeEnv();
      const resp = await handleProvision(provisionRequest(), env);
      assert.equal(resp.status, 200);
      const body = await resp.json();
      assert.ok(body.fqdn.endsWith(".sygen.pro"));
      assert.ok(body.install_token.startsWith("sit_"));
      // CF was called once to create A record.
      const posts = calls.filter((c) => c.method === "POST");
      assert.equal(posts.length, 1);
      // KV has the reservation + token index entry.
      assert.equal(env.SUBDOMAIN_RESERVATIONS.data.size, 2); // reservation + ratelimit bucket
      assert.equal(env.TOKEN_INDEX.data.size, 1);
    },
  );
});

test("H-1: KV put failure rolls back A record and returns 503", () => {
  const fetchCalls = [];
  return withMockFetch(
    (call) => {
      // CF responses: POST creates record, DELETE removes it.
      if (call.method === "POST") return cfSuccess({ id: "rec-orphan-candidate" });
      if (call.method === "DELETE") return cfSuccess({ id: "rec-orphan-candidate" });
      return cfSuccess({});
    },
    async (calls) => {
      const env = makeEnv({
        SUBDOMAIN_RESERVATIONS: makeFailingKv(),
        TOKEN_INDEX: makeKv(),
      });
      const resp = await handleProvision(provisionRequest(), env);
      assert.equal(resp.status, 503);
      const body = await resp.json();
      assert.equal(body.error, "kv_put_failed");

      // Both POST (create) and DELETE (rollback) must have happened.
      const posts = calls.filter((c) => c.method === "POST");
      const deletes = calls.filter((c) => c.method === "DELETE");
      assert.equal(posts.length, 1, "A record should have been created");
      assert.equal(deletes.length, 1, "A record should have been rolled back");
      assert.ok(
        deletes[0].url.endsWith("/dns_records/rec-orphan-candidate"),
        "rollback DELETE should target the just-created record id",
      );
      fetchCalls.push(...calls);
    },
  );
});

test("H-1: rollback failure is logged but still returns 503", () => {
  const origErr = console.error;
  const errLogs = [];
  console.error = (...args) => errLogs.push(args);
  return withMockFetch(
    (call) => {
      if (call.method === "POST") return cfSuccess({ id: "rec-stuck" });
      // DELETE fails — record stays orphaned, but we still need to surface
      // the original KV failure to the client.
      return new Response(
        JSON.stringify({ success: false, errors: [{ code: 9999, message: "down" }] }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    },
    async () => {
      const env = makeEnv({
        SUBDOMAIN_RESERVATIONS: makeFailingKv(),
        TOKEN_INDEX: makeKv(),
      });
      const resp = await handleProvision(provisionRequest(), env);
      assert.equal(resp.status, 503);
      const body = await resp.json();
      assert.equal(body.error, "kv_put_failed");
      assert.ok(
        errLogs.some(([msg]) => msg === "provision: dns_rollback_failed"),
        "rollback failure should be logged",
      );
    },
  ).finally(() => { console.error = origErr; });
});

test("H-2: 6th provision from same IP within window returns 429 with Retry-After", () => {
  return withMockFetch(
    () => cfSuccess({ id: "rec" }),
    async () => {
      const env = makeEnv();
      const ip = "198.51.100.7";
      // First 5 succeed.
      for (let i = 0; i < 5; i++) {
        const resp = await handleProvision(provisionRequest(ip), env);
        assert.equal(resp.status, 200, `request ${i + 1} should succeed`);
      }
      // 6th hits the limiter.
      const blocked = await handleProvision(provisionRequest(ip), env);
      assert.equal(blocked.status, 429);
      const body = await blocked.json();
      assert.equal(body.error, "rate_limited");
      const retryAfter = blocked.headers.get("Retry-After");
      assert.ok(retryAfter, "Retry-After header should be set");
      const seconds = parseInt(retryAfter, 10);
      assert.ok(seconds > 0 && seconds <= 3600, `Retry-After ${seconds}s should be within window`);
      assert.equal(body.retry_after, seconds);
    },
  );
});

test("H-2: rate limit isolated per-IP — different IP gets fresh window", () => {
  return withMockFetch(
    () => cfSuccess({ id: "rec" }),
    async () => {
      const env = makeEnv();
      // Burn through quota for first IP.
      for (let i = 0; i < 5; i++) {
        const r = await handleProvision(provisionRequest("198.51.100.7"), env);
        assert.equal(r.status, 200);
      }
      const blocked = await handleProvision(provisionRequest("198.51.100.7"), env);
      assert.equal(blocked.status, 429);
      // Different IP is fresh.
      const fresh = await handleProvision(provisionRequest("198.51.100.99"), env);
      assert.equal(fresh.status, 200, "fresh IP should bypass other IP's bucket");
    },
  );
});

test("H-2: rate limit honours PROVISION_RATE_LIMIT override", () => {
  return withMockFetch(
    () => cfSuccess({ id: "rec" }),
    async () => {
      const env = makeEnv({ PROVISION_RATE_LIMIT: "2" });
      const ip = "198.51.100.42";
      for (let i = 0; i < 2; i++) {
        const r = await handleProvision(provisionRequest(ip), env);
        assert.equal(r.status, 200);
      }
      const blocked = await handleProvision(provisionRequest(ip), env);
      assert.equal(blocked.status, 429);
    },
  );
});
