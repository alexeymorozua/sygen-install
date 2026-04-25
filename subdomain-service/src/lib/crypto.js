// Cryptographic helpers — uses Web Crypto API (available in CF Workers and
// Node 18+ as globalThis.crypto / crypto.subtle).

const BASE64URL_CHARS =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

function base64url(bytes) {
  let bits = 0;
  let value = 0;
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    value = (value << 8) | bytes[i];
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      out += BASE64URL_CHARS[(value >> bits) & 0x3f];
    }
  }
  if (bits > 0) {
    out += BASE64URL_CHARS[(value << (6 - bits)) & 0x3f];
  }
  return out;
}

// 48 random bytes → 64 base64url chars. No padding.
export function generateInstallToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(48));
  return "sit_" + base64url(bytes);
}

export async function sha256Hex(input) {
  const buf = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", buf);
  const bytes = new Uint8Array(digest);
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}
