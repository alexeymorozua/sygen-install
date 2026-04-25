# Sygen Subdomain Provisioning Service

Cloudflare Worker that hands out free `<id>.sygen.pro` subdomains to fresh
Sygen installs. See `sygen-clean/PHASE3_subdomain_provisioning_design.md`
for the full architecture.

This directory is a **skeleton**. Endpoint logic is not yet implemented
(returns `501 not_implemented`). Implementation is tracked as Phase 3 Task A.

## Layout

```
subdomain-service/
├── wrangler.toml      # CF Worker config + KV bindings + cron trigger
├── src/worker.js      # router + endpoint stubs
└── README.md          # this file
```

## One-time setup

```bash
npm install -g wrangler
wrangler login

# Create the two KV namespaces and copy the returned IDs into wrangler.toml
wrangler kv:namespace create SUBDOMAIN_RESERVATIONS
wrangler kv:namespace create TOKEN_INDEX

# Set secrets (these are NOT committed)
wrangler secret put CF_MASTER_API_TOKEN   # Zone.DNS:Edit on sygen.pro
wrangler secret put ADMIN_TOKEN           # for /api/admin/* and /api/health
```

## Deploy

```bash
wrangler deploy
```

The Worker binds to `install.sygen.pro/api/*`. Static install.sh and
docker-compose.yml continue to be served via Pages on the same hostname;
only `/api/*` paths route to this Worker.

## Local dev

```bash
wrangler dev
# Worker available at http://localhost:8787
```

For local testing without hitting real Cloudflare DNS API, set a fake
`CF_MASTER_API_TOKEN` and stub the CF API client (TODO in implementation
task).

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/provision` | Allocate fresh `<id>.sygen.pro` + install_token |
| `POST` | `/api/heartbeat` | Extend reservation TTL by 30 days |
| `DELETE` | `/api/release` | Free reservation on uninstall |
| `GET` | `/api/health` | Admin health (requires `ADMIN_TOKEN`) |

Full request/response contracts: see `PHASE3_subdomain_provisioning_design.md`
§2 in sygen-clean repo.

## Scheduled tasks

- `0 2 * * *` (daily, 02:00 UTC) — sweep entries with `expires_at < now()`,
  delete corresponding DNS records and KV entries.

## Implementation status

| Endpoint | Status |
|---|---|
| `/api/provision` | Stub — 501 |
| `/api/heartbeat` | Stub — 501 |
| `/api/release` | Stub — 501 |
| `/api/health` | Stub — 501 |
| Scheduled sweep | Stub |

All `TODO(phase3-A)` markers in `src/worker.js` correspond to the
implementation steps of Phase 3 Task A.
