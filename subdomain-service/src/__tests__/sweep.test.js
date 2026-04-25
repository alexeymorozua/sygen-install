import { test } from "node:test";
import assert from "node:assert/strict";

import { sweepExpired } from "../sweep.js";

// Minimal in-memory KV stub matching the Cloudflare KV surface used by sweep.
function makeKv(initial = {}) {
  const data = new Map(Object.entries(initial));
  return {
    data,
    async get(key) { return data.has(key) ? data.get(key) : null; },
    async put(key, value) { data.set(key, value); },
    async delete(key) { data.delete(key); },
    async list({ cursor, limit = 1000 } = {}) {
      const keys = [...data.keys()].sort();
      const start = cursor ? parseInt(cursor, 10) : 0;
      const slice = keys.slice(start, start + limit);
      const next = start + slice.length;
      return {
        keys: slice.map((name) => ({ name })),
        list_complete: next >= keys.length,
        cursor: String(next),
      };
    },
  };
}

// Stub out global fetch so the CF API calls in sweep behave deterministically.
function withMockFetch(fn) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push({ url, method: init?.method || "GET" });
    return new Response(
      JSON.stringify({ success: true, result: { id: "deleted" }, errors: [], messages: [] }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  };
  return Promise.resolve(fn(calls)).finally(() => { globalThis.fetch = original; });
}

test("sweepExpired removes only entries with expires_at < now", () => {
  return withMockFetch(async (cfCalls) => {
    const now = Date.parse("2026-04-25T12:00:00Z");
    const past = new Date(now - 86400_000).toISOString();
    const future = new Date(now + 86400_000).toISOString();

    const subs = makeKv({
      "aaaa1111": JSON.stringify({
        subdomain: "aaaa1111",
        cf_record_id: "rec-aaaa",
        install_token_hash: "hash-aaaa",
        expires_at: past,
      }),
      "bbbb2222": JSON.stringify({
        subdomain: "bbbb2222",
        cf_record_id: "rec-bbbb",
        install_token_hash: "hash-bbbb",
        expires_at: future,
      }),
      "cccc3333": JSON.stringify({
        subdomain: "cccc3333",
        cf_record_id: "rec-cccc",
        install_token_hash: "hash-cccc",
        expires_at: past,
      }),
    });
    const tokens = makeKv({
      "hash-aaaa": "aaaa1111",
      "hash-bbbb": "bbbb2222",
      "hash-cccc": "cccc3333",
    });

    const env = {
      SUBDOMAIN_RESERVATIONS: subs,
      TOKEN_INDEX: tokens,
      SYGEN_CF_ZONE_ID: "ZONE",
      CF_MASTER_API_TOKEN: "stub",
    };

    const result = await sweepExpired(env, now);

    assert.equal(result.swept, 2);
    assert.equal(result.scanned, 3);
    assert.equal(result.dnsErrors, 0);
    assert.equal(result.entryErrors, 0);

    // Expired entries gone.
    assert.equal(subs.data.has("aaaa1111"), false);
    assert.equal(subs.data.has("cccc3333"), false);
    assert.equal(tokens.data.has("hash-aaaa"), false);
    assert.equal(tokens.data.has("hash-cccc"), false);

    // Non-expired entry preserved.
    assert.equal(subs.data.has("bbbb2222"), true);
    assert.equal(tokens.data.has("hash-bbbb"), true);

    // CF DNS deletes only for expired records.
    const deletes = cfCalls.filter((c) => c.method === "DELETE");
    assert.equal(deletes.length, 2);
    const deletedRecords = deletes.map((c) => c.url).sort();
    assert.ok(deletedRecords[0].endsWith("/dns_records/rec-aaaa"));
    assert.ok(deletedRecords[1].endsWith("/dns_records/rec-cccc"));
  });
});

test("sweepExpired tolerates 404 from CF (record already gone)", () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({ success: false, errors: [{ code: 81044, message: "Record not found" }] }),
      { status: 404, headers: { "Content-Type": "application/json" } },
    );

  return (async () => {
    const now = Date.parse("2026-04-25T12:00:00Z");
    const past = new Date(now - 86400_000).toISOString();
    const subs = makeKv({
      "ghost123": JSON.stringify({
        subdomain: "ghost123",
        cf_record_id: "rec-ghost",
        install_token_hash: "hash-ghost",
        expires_at: past,
      }),
    });
    const tokens = makeKv({ "hash-ghost": "ghost123" });

    const result = await sweepExpired(
      { SUBDOMAIN_RESERVATIONS: subs, TOKEN_INDEX: tokens, SYGEN_CF_ZONE_ID: "Z", CF_MASTER_API_TOKEN: "x" },
      now,
    );

    assert.equal(result.swept, 1);
    assert.equal(result.dnsErrors, 0);
    assert.equal(subs.data.has("ghost123"), false);
    assert.equal(tokens.data.has("hash-ghost"), false);
  })().finally(() => { globalThis.fetch = original; });
});

test("sweepExpired counts CF errors but does not crash", () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({ success: false, errors: [{ code: 9999, message: "boom" }] }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );

  return (async () => {
    const now = Date.parse("2026-04-25T12:00:00Z");
    const past = new Date(now - 86400_000).toISOString();
    const subs = makeKv({
      "errr1234": JSON.stringify({
        subdomain: "errr1234",
        cf_record_id: "rec-err",
        install_token_hash: "hash-err",
        expires_at: past,
      }),
    });
    const tokens = makeKv({ "hash-err": "errr1234" });

    const result = await sweepExpired(
      { SUBDOMAIN_RESERVATIONS: subs, TOKEN_INDEX: tokens, SYGEN_CF_ZONE_ID: "Z", CF_MASTER_API_TOKEN: "x" },
      now,
    );

    assert.equal(result.dnsErrors, 1);
    assert.equal(result.swept, 0);
    // KV entry preserved on DNS failure — sweep retries tomorrow.
    assert.equal(subs.data.has("errr1234"), true);
  })().finally(() => { globalThis.fetch = original; });
});
