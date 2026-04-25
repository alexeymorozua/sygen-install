# Sygen Subdomain Provisioning Service

Cloudflare Worker that hands out free `<id>.sygen.pro` subdomains to fresh
Sygen installs. See `sygen-clean/PHASE3_subdomain_provisioning_design.md`
for the full architecture.

## Layout

```
subdomain-service/
├── wrangler.toml            # CF Worker config + KV bindings + cron trigger
├── package.json             # node --test runner config (no runtime deps)
├── README.md                # this file
└── src/
    ├── worker.js            # entry — router + scheduled trigger
    ├── sweep.js             # daily sweep of expired reservations
    ├── handlers/
    │   ├── provision.js
    │   ├── heartbeat.js
    │   ├── release.js
    │   ├── dns_challenge.js # ACME DNS-01 TXT add/remove for owned subdomain
    │   └── health.js
    ├── lib/
    │   ├── cf.js            # Cloudflare API client
    │   ├── crypto.js        # install_token gen + sha256
    │   ├── response.js      # JSON response helper
    │   └── subdomain.js     # alphabet, generator, blacklist
    └── __tests__/
        ├── crypto.test.js
        ├── subdomain.test.js
        ├── dns_challenge.test.js
        └── sweep.test.js
```

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/provision` | Allocate fresh `<id>.sygen.pro` + install_token. Worker also creates the A record from CF-Connecting-IP. |
| `POST` | `/api/heartbeat` | Extend reservation TTL by `TTL_DAYS` (default 30) |
| `DELETE` | `/api/release` | Free reservation on uninstall (idempotent) |
| `POST` | `/api/dns-challenge` | Add ACME DNS-01 TXT for `_acme-challenge.<owned-subdomain>.sygen.pro`. Auth: `install_token` in body. |
| `DELETE` | `/api/dns-challenge` | Remove the TXT created above. Idempotent. |
| `GET` | `/api/health` | Admin health (requires `Authorization: Bearer $ADMIN_TOKEN`) |

Full request/response contracts: `PHASE3_subdomain_provisioning_design.md` §2.

`/api/dns-challenge` is the Worker-mediated path that lets `install.sh` answer
Let's Encrypt DNS-01 challenges without ever holding a Cloudflare token. The
Worker derives the expected TXT name (`_acme-challenge.<sub>.sygen.pro`) from
the install_token and rejects any name outside that owned subdomain. See
`PHASE3_TLS_token_scoping_decision.md` for the rationale.

## Scheduled tasks

`0 2 * * *` (daily, 02:00 UTC) — sweep entries with `expires_at < now()`,
delete corresponding DNS records and KV entries. Capped at 200 expirations
per run.

## Pre-deploy checklist (operator)

The Worker is **not** auto-deployed. Run these steps from
`subdomain-service/` on a machine logged into the Cloudflare account that
owns `sygen.pro`.

### 1. Cloudflare account prerequisites

- An API token (`CF_MASTER_API_TOKEN`) with these permissions:
  - **Zone → DNS → Edit** on `sygen.pro` — used to create the A record
    during `/api/provision` and the TXT record during `/api/dns-challenge`.

  No `User → API Tokens → Edit` permission is required — the Worker no
  longer mints per-install scoped tokens.

### 2. Install wrangler and authenticate

```bash
npm install -g wrangler
wrangler login
```

### 3. Create KV namespaces

```bash
wrangler kv namespace create SUBDOMAIN_RESERVATIONS
wrangler kv namespace create TOKEN_INDEX
```

Each command prints an `id`. Paste those IDs into the matching
`[[kv_namespaces]]` blocks in `wrangler.toml`, replacing the
`REPLACE_WITH_KV_ID_AFTER_CREATE` placeholders.

### 4. Set secrets

```bash
wrangler secret put CF_MASTER_API_TOKEN   # paste token from step 1
wrangler secret put ADMIN_TOKEN           # any opaque random string
```

`ADMIN_TOKEN` gates `GET /api/health`. Generate with:
```bash
openssl rand -base64 32
```

### 5. Deploy

```bash
wrangler deploy
```

The Worker binds to `install.sygen.pro/api/*`. Static install.sh and
docker-compose.yml continue to be served via Pages on the same hostname;
only `/api/*` paths route to this Worker.

### 6. Configure rate limits in CF dashboard

These are enforced by Cloudflare zone rules in front of the Worker, **not**
by the Worker itself. Set up under
**Security → WAF → Rate limiting rules** on `sygen.pro`:

| Rule | Path | Limit | Action |
|---|---|---|---|
| `provision` | `/api/provision` | 5 / hour / IP | 429 |
| `heartbeat` | `/api/heartbeat` | 60 / hour / IP | 429 |
| `release` | `/api/release` | 10 / hour / IP | 429 |
| `dns-challenge` | `/api/dns-challenge` | 20 / hour / IP | 429 |

(LE typically does 1–2 challenges per cert; 20/hour absorbs renewal retries.)

### 7. Smoke test

```bash
# Allocate
curl -X POST https://install.sygen.pro/api/provision \
  -H "Content-Type: application/json" -d '{}'
# → {"fqdn":"...","install_token":"sit_...","heartbeat_url":"...","dns_challenge_url":"..."}

# Wait ~30s for DNS propagation, then verify
dig +short <fqdn>

# DNS-01 challenge (Worker-mediated; install.sh's certbot hooks call these)
curl -X POST https://install.sygen.pro/api/dns-challenge \
  -H "Content-Type: application/json" \
  -d '{"install_token":"<token>","name":"_acme-challenge.<sub>.sygen.pro","value":"<acme-validation>"}'
curl -X DELETE https://install.sygen.pro/api/dns-challenge \
  -H "Content-Type: application/json" \
  -d '{"install_token":"<token>","name":"_acme-challenge.<sub>.sygen.pro"}'

# Heartbeat
curl -X POST https://install.sygen.pro/api/heartbeat \
  -H "Content-Type: application/json" \
  -d '{"install_token":"<token>"}'

# Release (idempotent)
curl -X DELETE https://install.sygen.pro/api/release \
  -H "Content-Type: application/json" \
  -d '{"install_token":"<token>"}'

# Health (admin)
curl https://install.sygen.pro/api/health \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

## Local dev

```bash
wrangler dev
# Worker available at http://localhost:8787
```

`wrangler dev` in remote mode hits real Cloudflare — useful for end-to-end
testing on a staging zone but will create real DNS records. Use a separate
test zone for this.

## Tests

Pure-function unit tests run on Node 18+ with the built-in test runner:

```bash
npm test
# or directly:
node --test 'src/__tests__/*.test.js'
```

No runtime dependencies; tests use Web Crypto from `globalThis`.

## Implementation notes

- **KV is eventually consistent** but reads after writes within the same
  colocation are strongly consistent. Provision retries claim attempts up
  to 4 times if the random subdomain happens to collide.
- **install.sh never receives a Cloudflare token.** Per-record CF token
  scoping is not exposed by the API today, so we don't ship any CF token
  to the host. The Worker mediates the DNS-01 challenge via
  `/api/dns-challenge` and enforces the name scope (`_acme-challenge.<sub>.sygen.pro`)
  in code we control. See `PHASE3_TLS_token_scoping_decision.md`.
- **install_token is stored only as sha256 hex.** Plaintext lives only on
  the requesting client and in flight over TLS.
- **DNS rollback on token-mint failure**: provision deletes the just-created
  A record if the scoped token mint fails — otherwise we'd leak unused
  records into the zone.
- **Release is idempotent**: unknown tokens return `200 {ok:true,
  released:false}` so `uninstall.sh` doesn't blow up on a double-uninstall
  or already-swept slot.
- **Sweep tolerates CF 404** (record already gone elsewhere) but logs and
  preserves the KV entry on other CF errors so the next run retries.
