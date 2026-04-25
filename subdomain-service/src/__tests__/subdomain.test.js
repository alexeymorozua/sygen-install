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

test("dnsRecordTypeForIp accepts public unicast addresses", () => {
  // TEST-NET-3 / TEST-NET-2 / public IPv6 — all valid public targets.
  assert.equal(dnsRecordTypeForIp("203.0.113.45"), "A");
  assert.equal(dnsRecordTypeForIp("198.51.100.1"), "A");
  assert.equal(dnsRecordTypeForIp("8.8.8.8"), "A");
  assert.equal(dnsRecordTypeForIp("2001:db8::1"), "AAAA");
  assert.equal(dnsRecordTypeForIp("2606:4700:4700::1111"), "AAAA");
});

test("dnsRecordTypeForIp rejects malformed input", () => {
  assert.equal(dnsRecordTypeForIp("not-an-ip"), null);
  assert.equal(dnsRecordTypeForIp(""), null);
  assert.equal(dnsRecordTypeForIp(null), null);
  assert.equal(dnsRecordTypeForIp("999.999.999.999"), null);
});

test("dnsRecordTypeForIp rejects RFC1918 / CGNAT / loopback / link-local IPv4", () => {
  // These would create publicly-resolving DNS records pointing inside the
  // user's LAN — bricks the subdomain and leaks the topology.
  for (const ip of [
    "10.0.0.1", "10.255.255.255",          // RFC1918 /8
    "172.16.0.1", "172.31.255.255",        // RFC1918 /12
    "172.15.0.1", "172.32.0.1",            // boundary: outside RFC1918 → still public
    "192.168.0.1", "192.168.255.255",      // RFC1918 /16
    "100.64.0.1", "100.127.255.255",       // CGNAT /10
    "127.0.0.1", "127.255.255.255",        // loopback
    "169.254.1.1",                          // link-local
    "0.0.0.0", "0.255.255.255",            // 0/8
    "224.0.0.1", "239.255.255.255",        // multicast
    "240.0.0.1", "255.255.255.254",        // reserved
    "255.255.255.255",                      // broadcast
  ]) {
    const result = dnsRecordTypeForIp(ip);
    if (ip === "172.15.0.1" || ip === "172.32.0.1") {
      assert.equal(result, "A", `${ip} is outside RFC1918 — should be public`);
    } else {
      assert.equal(result, null, `${ip} should be rejected as non-public`);
    }
  }
});

test("dnsRecordTypeForIp rejects loopback / link-local / ULA / multicast IPv6", () => {
  for (const ip of [
    "::1",                  // loopback
    "::",                   // unspecified
    "fe80::1",              // link-local
    "fc00::1",              // ULA
    "fd12:3456:789a::1",    // ULA
    "ff02::1",              // multicast
    "FE80::1",              // case-insensitive link-local
  ]) {
    assert.equal(dnsRecordTypeForIp(ip), null, `${ip} should be rejected`);
  }
});
