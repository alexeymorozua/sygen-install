// Cloudflare API client — thin wrapper around CF v4 REST endpoints used by
// this service. All calls authenticate with env.CF_MASTER_API_TOKEN, which
// must carry:
//   - Zone:DNS:Edit on the sygen.pro zone (records create/delete)
//   - User API Tokens:Edit (mint short-lived scoped tokens for DNS-01)

const API_BASE = "https://api.cloudflare.com/client/v4";

export class CfApiError extends Error {
  constructor(message, status, payload) {
    super(message);
    this.name = "CfApiError";
    this.status = status;
    this.payload = payload;
  }
}

async function cfFetch(env, path, init = {}) {
  const resp = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers: {
      "Authorization": `Bearer ${env.CF_MASTER_API_TOKEN}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  let body = null;
  try {
    body = await resp.json();
  } catch {
    throw new CfApiError(`CF ${resp.status} (non-JSON response)`, resp.status, null);
  }
  if (!resp.ok || body.success === false) {
    const reason = (body.errors || [])
      .map((e) => `${e.code}: ${e.message}`)
      .join("; ") || resp.statusText;
    throw new CfApiError(`CF ${resp.status}: ${reason}`, resp.status, body);
  }
  return body.result;
}

export async function createDnsRecord(env, fqdn, ip, type) {
  return cfFetch(env, `/zones/${env.SYGEN_CF_ZONE_ID}/dns_records`, {
    method: "POST",
    body: JSON.stringify({
      type,
      name: fqdn,
      content: ip,
      ttl: 60,
      proxied: false,
      comment: "auto-provisioned by sygen-subdomain-service",
    }),
  });
}

export async function deleteDnsRecord(env, recordId) {
  return cfFetch(env, `/zones/${env.SYGEN_CF_ZONE_ID}/dns_records/${recordId}`, {
    method: "DELETE",
  });
}

// Mint a short-lived API token with DNS:Edit permission on the sygen.pro
// zone. Used by install.sh to perform a one-shot Let's Encrypt DNS-01
// challenge. After the (configurable) TTL elapses CF auto-revokes the
// token. CF's per-record scoping is not currently exposed for tokens —
// the closest we can get is whole-zone DNS:Edit limited by short TTL.
//
// env.CF_DNS_WRITE_PERMISSION_GROUP_ID — wrangler.toml [vars] entry. The
// permission group ID is account-specific; obtain via
//   curl -H "Authorization: Bearer <master>" \
//        https://api.cloudflare.com/client/v4/user/tokens/permission_groups
// and pick the entry whose name is "DNS Write" (scope=zone).
export async function mintScopedDnsToken(env, subdomain, ttlSeconds) {
  const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();
  const payload = {
    name: `sygen-install-${subdomain}-dns01-${Date.now()}`,
    policies: [
      {
        effect: "allow",
        resources: {
          [`com.cloudflare.api.account.zone.${env.SYGEN_CF_ZONE_ID}`]: "*",
        },
        permission_groups: [
          { id: env.CF_DNS_WRITE_PERMISSION_GROUP_ID },
        ],
      },
    ],
    expires_on: expiresAt,
  };
  const result = await cfFetch(env, "/user/tokens", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  return { token: result.value, expires_at: expiresAt, token_id: result.id };
}
