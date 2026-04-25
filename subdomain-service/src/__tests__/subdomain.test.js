import { test } from "node:test";
import assert from "node:assert/strict";

import {
  ALPHABET,
  generateSubdomain,
  isReserved,
  isValidShape,
  dnsRecordTypeForIp,
  RESERVED_SUBDOMAINS,
} from "../lib/subdomain.js";

test("ALPHABET excludes ambiguous chars", () => {
  // 26 letters - {i,l,o} + 8 digits {2..9} = 31 chars.
  assert.equal(ALPHABET.length, 31);
  for (const c of ["0", "1", "i", "l", "o"]) {
    assert.ok(!ALPHABET.includes(c), `should not contain '${c}'`);
  }
});

test("generateSubdomain produces requested length and only uses ALPHABET", () => {
  for (let i = 0; i < 200; i++) {
    const s = generateSubdomain(8);
    assert.equal(s.length, 8);
    for (const ch of s) {
      assert.ok(ALPHABET.includes(ch), `unexpected char '${ch}' in '${s}'`);
    }
  }
});

test("generateSubdomain length is configurable", () => {
  assert.equal(generateSubdomain(4).length, 4);
  assert.equal(generateSubdomain(12).length, 12);
});

test("generateSubdomain has no detectable bias across alphabet", () => {
  const counts = Object.fromEntries(Array.from(ALPHABET, (c) => [c, 0]));
  const samples = 5000;
  for (let i = 0; i < samples; i++) {
    for (const ch of generateSubdomain(8)) counts[ch]++;
  }
  // 5000*8=40000 samples over 31 buckets → expected ~1290/bucket. Generous
  // ±50% bounds keep this non-flaky.
  for (const [ch, n] of Object.entries(counts)) {
    assert.ok(n > 0, `'${ch}' never produced`);
    assert.ok(n > 600, `'${ch}' produced only ${n} times (expected ~1290)`);
    assert.ok(n < 2000, `'${ch}' produced ${n} times (expected ~1290)`);
  }
  assert.equal(
    Object.values(counts).reduce((a, b) => a + b, 0),
    samples * 8,
  );
});

test("isReserved catches well-known names case-insensitively", () => {
  for (const name of ["admin", "API", "WWW", "install", "ns3", "dns7", "sygen", "mail"]) {
    assert.ok(isReserved(name), `${name} should be reserved`);
  }
});

test("isReserved misses random 8-char tokens", () => {
  // None of the reserved names is exactly 8 chars from ALPHABET, so a fresh
  // generator output should never collide. (Probabilistic but with the seed
  // space we use, deterministic in practice.)
  for (let i = 0; i < 100; i++) {
    assert.ok(!isReserved(generateSubdomain(8)));
  }
});

test("RESERVED_SUBDOMAINS includes ns1..ns9 and dns1..dns9", () => {
  for (let i = 1; i <= 9; i++) {
    assert.ok(RESERVED_SUBDOMAINS.has(`ns${i}`), `missing ns${i}`);
    assert.ok(RESERVED_SUBDOMAINS.has(`dns${i}`), `missing dns${i}`);
  }
});

test("isValidShape rejects malformed input", () => {
  assert.ok(isValidShape("abcdefgh"));
  assert.ok(!isValidShape(""));
  assert.ok(!isValidShape("abc"));
  assert.ok(!isValidShape("ABCdef12"));
  assert.ok(!isValidShape("abc.def"));
  assert.ok(!isValidShape("foo-bar1"));
  assert.ok(!isValidShape(null));
  assert.ok(!isValidShape(123));
});

test("dnsRecordTypeForIp", () => {
  assert.equal(dnsRecordTypeForIp("203.0.113.45"), "A");
  assert.equal(dnsRecordTypeForIp("0.0.0.0"), "A");
  assert.equal(dnsRecordTypeForIp("255.255.255.255"), "A");
  assert.equal(dnsRecordTypeForIp("2001:db8::1"), "AAAA");
  assert.equal(dnsRecordTypeForIp("::1"), "AAAA");
  assert.equal(dnsRecordTypeForIp("not-an-ip"), null);
  assert.equal(dnsRecordTypeForIp(""), null);
  assert.equal(dnsRecordTypeForIp(null), null);
  assert.equal(dnsRecordTypeForIp("999.999.999.999"), null);
});
