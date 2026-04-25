// Crockford-style base32 alphabet, minus visually ambiguous 0/o/1/i/l.
// That leaves 23 letters + 8 digits = 31 symbols (the design doc says 32
// but the printed alphabet is 31 chars; we follow the printed alphabet).
// 31^8 ≈ 8.5e11 address space — ample for the foreseeable install volume.
export const ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

// Rejection sampling: 248 = 31 * 8, so bytes 0..247 map uniformly across
// the alphabet; we discard bytes ≥248 to avoid modulo bias.
const REJECT_THRESHOLD = ALPHABET.length * Math.floor(256 / ALPHABET.length);

export function generateSubdomain(length = 8) {
  const out = [];
  while (out.length < length) {
    // Over-allocate a bit so we usually finish in one buffer fill
    // (acceptance rate ~96.9%).
    const need = length - out.length;
    const buf = crypto.getRandomValues(new Uint8Array(need * 2));
    for (let i = 0; i < buf.length && out.length < length; i++) {
      if (buf[i] < REJECT_THRESHOLD) {
        out.push(ALPHABET[buf[i] % ALPHABET.length]);
      }
    }
  }
  return out.join("");
}

// Reserved subdomains — protects operational, admin, and well-known
// hostnames from being randomly allocated. See PHASE3 design §7. The
// 8-char generator essentially never produces these short tokens, but we
// retry on collision anyway.
export const RESERVED_SUBDOMAINS = new Set([
  "admin", "api", "www", "install", "docs", "app",
  "mail", "smtp", "imap", "pop", "ftp", "sftp",
  "ns", "ns1", "ns2", "ns3", "ns4", "ns5", "ns6", "ns7", "ns8", "ns9",
  "dns", "dns1", "dns2", "dns3", "dns4", "dns5", "dns6", "dns7", "dns8", "dns9",
  "support", "help", "status", "dashboard", "panel",
  "blog", "cdn", "static", "media", "files", "download", "upload",
  "vps", "srv", "server",
  "git", "gitlab", "github", "registry", "build", "ci", "cd",
  "dev", "staging", "prod", "test", "demo", "beta", "alpha", "sandbox",
  "root", "master", "main",
  "hr", "jobs", "careers",
  "billing", "account", "accounts", "login", "signin", "signup", "auth",
  "sso", "oauth", "security",
  "abuse", "postmaster", "hostmaster", "webmaster",
  "noreply", "no-reply", "info", "contact", "sales", "marketing",
  "news", "press", "investors",
  "legal", "privacy", "terms", "cookies", "gdpr",
  "system", "sygen", "store",
]);

export function isReserved(name) {
  return RESERVED_SUBDOMAINS.has(name.toLowerCase());
}

const VALID_RE = /^[a-z2-9]{4,32}$/;
export function isValidShape(name) {
  return typeof name === "string" && VALID_RE.test(name);
}

// IPv4 in dotted-quad with octets 0-255.
const IPV4_RE = /^(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;

// IPv4 ranges that must never end up in a public *.sygen.pro A record:
//   RFC1918 private   10/8, 172.16/12, 192.168/16
//   CGNAT             100.64/10
//   loopback          127/8
//   link-local        169.254/16
//   broadcast/this    0/8, 255.255.255.255
//   multicast/reserved 224/4, 240/4
function isPublicIPv4(ip) {
  const parts = ip.split(".").map(Number);
  const [a, b] = parts;
  if (a === 10) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 100 && b >= 64 && b <= 127) return false;
  if (a === 127) return false;
  if (a === 169 && b === 254) return false;
  if (a === 0) return false;
  if (a >= 224) return false;
  if (a === 255 && b === 255 && parts[2] === 255 && parts[3] === 255) return false;
  return true;
}

// IPv6 — minimal validation: presence of ':' and reject obvious non-public
// prefixes. We're not building a full IPv6 parser; CF-Connecting-IP is well-
// formed, and the {public_ip} body path is opt-in (publicdomain mode only,
// rarely IPv6 at the boundary).
function isPublicIPv6(ip) {
  const lower = ip.toLowerCase();
  if (lower === "::1") return false;                 // loopback
  if (lower === "::") return false;                  // unspecified
  if (lower.startsWith("fe80:")) return false;       // link-local
  if (lower.startsWith("fc") || lower.startsWith("fd")) return false; // ULA
  if (lower.startsWith("ff")) return false;          // multicast
  return true;
}

export function dnsRecordTypeForIp(ip) {
  if (typeof ip !== "string" || ip.length === 0) return null;
  if (IPV4_RE.test(ip)) return isPublicIPv4(ip) ? "A" : null;
  if (ip.includes(":")) return isPublicIPv6(ip) ? "AAAA" : null;
  return null;
}
