import { test } from "node:test";
import assert from "node:assert/strict";

import {
  handleDnsChallengePost,
  handleDnsChallengeDelete,
} from "../handlers/dns_challenge.js";
import { sha256Hex } from "../lib/crypto.js";

// In-memory KV stub matching the surface used by the dns_challenge handler.
function makeKv(initial = {}) {
  const data = new Map(Object.entries(initial));
  return {
    data,
    async get(key) { return data.has(key) ? data.get(key) : null; },
    async put(key, value) { data.set(key, value); },
    async delete(key) { data.delete(key); },
  };
}

function jsonRequest(method, body) {
  return new Request("https://install.sygen.pro/api/dns-challenge", {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

// Build env with one valid reservation that the test owns. Returns a tuple
// of (env, install_token) so tests can address it without re-hashing.
async function makeEnv(extraOverrides = {}) {
  const installToken = "sit_test_token_for_unit_check_aaaa";
  const tokenHash = await sha256Hex(installToken);
  const subdomain = "abcd2345";
  const reservation = {
    subdomain,
    install_token_hash: tokenHash,
    created_at: "2026-04-25T12:00:00Z",
    last_heartbeat_at: "2026-04-25T12:00:00Z",
    expires_at: "2026-05-25T12:00:00Z",
    allocated_to_ip: "203.0.113.45",
    cf_record_id: "rec-a-record",
    ...(extraOverrides.reservation || {}),
  };
  const env = {
    SYGEN_DOMAIN: "sygen.pro",
    SYGEN_CF_ZONE_ID: "ZONE",
    CF_MASTER_API_TOKEN: "stub",
    SUBDOMAIN_RESERVATIONS: makeKv({ [subdomain]: JSON.stringify(reservation) }),
    TOKEN_INDEX: makeKv({ [tokenHash]: subdomain }),
    ...extraOverrides.env,
  };
  return { env, installToken, subdomain };
}

// Stub out global fetch with a programmable handler. fn(call) → Response.
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

function cfSuccess(result) {
  return new Response(
    JSON.stringify({ success: true, result, errors: [], messages: [] }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

test("POST /dns-challenge creates TXT for owned subdomain", () => {
  return withMockFetch(
    () => cfSuccess({ id: "rec-txt-new" }),
    async (calls) => {
      const { env, installToken, subdomain } = await makeEnv();
      const req = jsonRequest("POST", {
        install_token: installToken,
        name: `_acme-challenge.${subdomain}.sygen.pro`,
        value: "v" + "a".repeat(42),
      });

      const resp = await handleDnsChallengePost(req, env);
      assert.equal(resp.status, 200);
      const body = await resp.json();
      assert.equal(body.ok, true);
      assert.equal(body.record_id, "rec-txt-new");

      assert.equal(calls.length, 1);
      assert.equal(calls[0].method, "POST");
      assert.ok(calls[0].url.endsWith("/zones/ZONE/dns_records"));
      const sent = JSON.parse(calls[0].body);
      assert.equal(sent.type, "TXT");
      assert.equal(sent.name, `_acme-challenge.${subdomain}.sygen.pro`);

      // Reservation now carries the new record id so DELETE is cheap.
      const stored = JSON.parse(await env.SUBDOMAIN_RESERVATIONS.get(subdomain));
      assert.equal(stored.dns_challenge_record_id, "rec-txt-new");
    },
  );
});

test("POST /dns-challenge rejects name outside owned subdomain (403)", async () => {
  const { env, installToken } = await makeEnv();
  const req = jsonRequest("POST", {
    install_token: installToken,
    name: "_acme-challenge.someoneelse.sygen.pro",
    value: "irrelevant",
  });
  const resp = await handleDnsChallengePost(req, env);
  assert.equal(resp.status, 403);
  const body = await resp.json();
  assert.equal(body.error, "name_outside_owned_subdomain");
});

test("POST /dns-challenge rejects bare apex / wildcard / variant names (403)", async () => {
  const { env, installToken, subdomain } = await makeEnv();
  const variants = [
    `${subdomain}.sygen.pro`,
    `_acme-challenge.${subdomain}.sygen.pro.`,
    `_ACME-challenge.${subdomain}.sygen.pro`,
    `_acme-challenge.foo.${subdomain}.sygen.pro`,
    `_acme-challenge.${subdomain}.sygen.pro.evil.com`,
  ];
  for (const name of variants) {
    const req = jsonRequest("POST", {
      install_token: installToken,
      name,
      value: "x".repeat(43),
    });
    const resp = await handleDnsChallengePost(req, env);
    assert.equal(resp.status, 403, `name '${name}' should be rejected`);
  }
});

test("POST /dns-challenge with unknown token returns 401", async () => {
  const { env } = await makeEnv();
  const req = jsonRequest("POST", {
    install_token: "sit_does_not_exist_in_token_index_xx",
    name: "_acme-challenge.abcd2345.sygen.pro",
    value: "v".repeat(43),
  });
  const resp = await handleDnsChallengePost(req, env);
  assert.equal(resp.status, 401);
});

test("POST /dns-challenge with missing fields returns 400", async () => {
  const { env, installToken, subdomain } = await makeEnv();
  for (const body of [
    {},
    { install_token: installToken },
    { install_token: installToken, name: `_acme-challenge.${subdomain}.sygen.pro` },
    { install_token: installToken, value: "x" },
    { name: `_acme-challenge.${subdomain}.sygen.pro`, value: "x" },
  ]) {
    const resp = await handleDnsChallengePost(jsonRequest("POST", body), env);
    assert.equal(resp.status, 400);
  }
});

test("POST /dns-challenge returns 502 when CF refuses", () => {
  return withMockFetch(
    () => new Response(
      JSON.stringify({ success: false, errors: [{ code: 9999, message: "boom" }] }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    ),
    async () => {
      const { env, installToken, subdomain } = await makeEnv();
      const req = jsonRequest("POST", {
        install_token: installToken,
        name: `_acme-challenge.${subdomain}.sygen.pro`,
        value: "x".repeat(43),
      });
      const resp = await handleDnsChallengePost(req, env);
      assert.equal(resp.status, 502);
    },
  );
});

test("DELETE /dns-challenge removes stored record id", () => {
  return withMockFetch(
    () => cfSuccess({ id: "rec-txt-existing" }),
    async (calls) => {
      const { env, installToken, subdomain } = await makeEnv({
        reservation: { dns_challenge_record_id: "rec-txt-existing" },
      });
      const req = jsonRequest("DELETE", {
        install_token: installToken,
        name: `_acme-challenge.${subdomain}.sygen.pro`,
      });
      const resp = await handleDnsChallengeDelete(req, env);
      assert.equal(resp.status, 200);
      const body = await resp.json();
      assert.equal(body.ok, true);
      assert.equal(body.deleted, 1);

      const deletes = calls.filter((c) => c.method === "DELETE");
      assert.equal(deletes.length, 1);
      assert.ok(deletes[0].url.endsWith("/dns_records/rec-txt-existing"));

      const stored = JSON.parse(await env.SUBDOMAIN_RESERVATIONS.get(subdomain));
      assert.equal(stored.dns_challenge_record_id, undefined);
    },
  );
});

test("DELETE /dns-challenge falls back to listing when record id missing", () => {
  return withMockFetch(
    (call) => {
      if (call.method === "GET") {
        return cfSuccess([{ id: "rec-txt-listed-1" }, { id: "rec-txt-listed-2" }]);
      }
      return cfSuccess({ id: "deleted" });
    },
    async (calls) => {
      const { env, installToken, subdomain } = await makeEnv();
      const req = jsonRequest("DELETE", {
        install_token: installToken,
        name: `_acme-challenge.${subdomain}.sygen.pro`,
      });
      const resp = await handleDnsChallengeDelete(req, env);
      assert.equal(resp.status, 200);
      const body = await resp.json();
      assert.equal(body.deleted, 2);

      const list = calls.find((c) => c.method === "GET");
      assert.ok(list, "list call missing");
      assert.ok(list.url.includes("type=TXT"));
      assert.ok(list.url.includes(`name=${encodeURIComponent(`_acme-challenge.${subdomain}.sygen.pro`)}`));

      const deletes = calls.filter((c) => c.method === "DELETE");
      assert.equal(deletes.length, 2);
    },
  );
});

test("DELETE /dns-challenge returns 200/0 when nothing to delete (idempotent)", () => {
  return withMockFetch(
    () => cfSuccess([]),
    async () => {
      const { env, installToken, subdomain } = await makeEnv();
      const req = jsonRequest("DELETE", {
        install_token: installToken,
        name: `_acme-challenge.${subdomain}.sygen.pro`,
      });
      const resp = await handleDnsChallengeDelete(req, env);
      assert.equal(resp.status, 200);
      const body = await resp.json();
      assert.equal(body.deleted, 0);
    },
  );
});

test("DELETE /dns-challenge rejects mismatched name (403)", async () => {
  const { env, installToken } = await makeEnv({
    reservation: { dns_challenge_record_id: "rec-stored" },
  });
  const req = jsonRequest("DELETE", {
    install_token: installToken,
    name: "_acme-challenge.attacker.sygen.pro",
  });
  const resp = await handleDnsChallengeDelete(req, env);
  assert.equal(resp.status, 403);
});

test("DELETE /dns-challenge tolerates CF 404 (record already gone)", () => {
  return withMockFetch(
    () => new Response(
      JSON.stringify({ success: false, errors: [{ code: 81044, message: "Record not found" }] }),
      { status: 404, headers: { "Content-Type": "application/json" } },
    ),
    async () => {
      const { env, installToken, subdomain } = await makeEnv({
        reservation: { dns_challenge_record_id: "rec-ghost" },
      });
      const req = jsonRequest("DELETE", {
        install_token: installToken,
        name: `_acme-challenge.${subdomain}.sygen.pro`,
      });
      const resp = await handleDnsChallengeDelete(req, env);
      assert.equal(resp.status, 200);
      const body = await resp.json();
      assert.equal(body.deleted, 1);
    },
  );
});
