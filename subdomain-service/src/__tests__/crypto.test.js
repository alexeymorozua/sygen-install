import { test } from "node:test";
import assert from "node:assert/strict";

import { generateInstallToken, sha256Hex } from "../lib/crypto.js";

test("generateInstallToken produces sit_ prefix and stable length", () => {
  for (let i = 0; i < 50; i++) {
    const t = generateInstallToken();
    assert.ok(t.startsWith("sit_"), `missing sit_ prefix: ${t}`);
    // 48 random bytes → 64 base64url chars, plus 4-char prefix = 68.
    assert.equal(t.length, 68);
    assert.ok(/^sit_[A-Za-z0-9_-]+$/.test(t), `unexpected chars in ${t}`);
  }
});

test("generateInstallToken produces unique tokens", () => {
  const seen = new Set();
  for (let i = 0; i < 200; i++) {
    const t = generateInstallToken();
    assert.ok(!seen.has(t), `duplicate: ${t}`);
    seen.add(t);
  }
});

test("sha256Hex matches known vector", async () => {
  // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  const got = await sha256Hex("abc");
  assert.equal(got, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

test("sha256Hex matches empty-string vector", async () => {
  // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  const got = await sha256Hex("");
  assert.equal(got, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
});

test("sha256Hex is deterministic and 64 hex chars", async () => {
  const a = await sha256Hex("sit_example_token_xyz");
  const b = await sha256Hex("sit_example_token_xyz");
  assert.equal(a, b);
  assert.equal(a.length, 64);
  assert.ok(/^[0-9a-f]{64}$/.test(a));
});
