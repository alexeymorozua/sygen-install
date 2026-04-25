// Cloudflare API client — thin wrapper around CF v4 REST endpoints used by
// this service. All calls authenticate with env.CF_MASTER_API_TOKEN, which
// must carry Zone:DNS:Edit on the sygen.pro zone (records create/delete).

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

export async function createTxtRecord(env, name, value, ttl = 60) {
  return cfFetch(env, `/zones/${env.SYGEN_CF_ZONE_ID}/dns_records`, {
    method: "POST",
    body: JSON.stringify({
      type: "TXT",
      name,
      content: value,
      ttl,
      proxied: false,
      comment: "ACME DNS-01 challenge by sygen-subdomain-service",
    }),
  });
}

// Fallback for cleanup when the stored record_id is missing — list TXT
// records by exact name. CF returns up to 100 by default; ACME challenges
// produce at most a few simultaneous TXTs per name, so one page is enough.
export async function listTxtRecords(env, name) {
  const q = new URLSearchParams({ type: "TXT", name });
  return cfFetch(env, `/zones/${env.SYGEN_CF_ZONE_ID}/dns_records?${q.toString()}`, {
    method: "GET",
  });
}

export async function deleteDnsRecord(env, recordId) {
  return cfFetch(env, `/zones/${env.SYGEN_CF_ZONE_ID}/dns_records/${recordId}`, {
    method: "DELETE",
  });
}
