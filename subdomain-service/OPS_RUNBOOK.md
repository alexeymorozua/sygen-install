# Sygen Subdomain Service — Operations Runbook

Day-2 procedures for the Cloudflare Worker that hands out
`<id>.sygen.pro` subdomains. For deploy bootstrap see
[`README.md`](./README.md). For end-to-end smoke testing see
[`INTEGRATION_TEST_README.md`](./INTEGRATION_TEST_README.md) (Phase 3
Task F output, lives next to this file once that task lands).

---

## 1. Architecture overview

```
                   ┌────────────────────┐
        install.sh │ POST /api/provision│──▶ Worker ──▶ CF DNS API (A record)
        (one-shot) │                    │       │
                   └────────────────────┘       └──▶ KV (SUBDOMAIN_RESERVATIONS,
                                                          TOKEN_INDEX)
                              ▲
                              │ install_token, fqdn, heartbeat_url
                              ▼
                   ┌────────────────────┐
        core (cron │ POST /api/heartbeat│──▶ Worker ──▶ KV update (extend TTL)
        weekly)    └────────────────────┘
                              │
                              │ on uninstall
                              ▼
        uninstall  │ DELETE /api/release│──▶ Worker ──▶ CF DNS delete + KV cleanup
                              │
        certbot    │ POST/DELETE        │──▶ Worker ──▶ CF DNS TXT add/remove
        manual     │   /api/dns-challenge│           (scoped to owned subdomain)
        hooks      │                    │
                   └────────────────────┘

        Cron (Worker scheduled, daily 02:00 UTC)
        └──▶ sweep KV for expires_at < now → delete A record + KV row
```

Three external dependencies:
- **Cloudflare DNS API** — Worker holds a single `CF_MASTER_API_TOKEN` with
  `Zone:DNS:Edit` on `sygen.pro`. Customers never see a CF token.
- **Cloudflare KV** — two namespaces. `SUBDOMAIN_RESERVATIONS` keyed by
  subdomain (also stores `RATELIMIT:` keys); `TOKEN_INDEX` keyed by
  `sha256(install_token)` and pointing at the subdomain.
- **Cloudflare Workers runtime** — bound to `install.sygen.pro/api/*` via
  the route in `wrangler.toml`.

The Worker is stateless across requests — all state lives in KV. Losing
the Worker (rollback, accidental delete) is recoverable; losing KV is
where customers feel pain (see §4).

---

## 2. Day-2 operations

### 2.1 Health monitoring

`GET /api/health` is **admin-token gated**. It does *not* return a public
liveness probe — `ADMIN_TOKEN` is required:

```bash
curl https://install.sygen.pro/api/health \
  -H "Authorization: Bearer $ADMIN_TOKEN"
# 200 {"status":"ok","active_reservations_first_page":<N>,
#      "list_complete":<bool>,"timestamp":"..."}
# 401 if token wrong; 503 if ADMIN_TOKEN unset on the Worker.
```

Do **not** point a public uptime monitor at this endpoint with the bearer
token in plaintext. Either use a private healthcheck (UptimeRobot custom
header, internal probe) or add a public `/api/ping` later if needed.

For real-time observability:
- **Cloudflare dashboard → Workers & Pages → `sygen-subdomain-service`
  → Logs** — live tail of `console.log/warn/error` plus per-request
  metrics (request count, error rate, p50/p95/p99 latency).
- **Cloudflare dashboard → Workers KV → `SUBDOMAIN_RESERVATIONS`** —
  total keys, storage size. Same for `TOKEN_INDEX`.

### 2.2 Manual ops via wrangler

Run from `subdomain-service/` on a machine logged into the CF account
that owns `sygen.pro`. (`wrangler login` once.)

```bash
# Live log stream (Ctrl-C to exit)
wrangler tail --format pretty

# Inspect current reservations
wrangler kv key list --binding SUBDOMAIN_RESERVATIONS

# Read a single reservation row
wrangler kv key get --binding SUBDOMAIN_RESERVATIONS <subdomain>

# Inspect rate-limit state for an IP
wrangler kv key list --binding SUBDOMAIN_RESERVATIONS --prefix "RATELIMIT:"
wrangler kv key get  --binding SUBDOMAIN_RESERVATIONS "RATELIMIT:1.2.3.4:<window>"

# Inspect the token→subdomain index
wrangler kv key list --binding TOKEN_INDEX

# Manually trigger the daily sweep (off-cycle)
wrangler dispatch scheduled --cron "0 2 * * *"
```

`wrangler tail` accepts filters: `--status error`, `--method POST`,
`--search subdomain` etc. Useful when grepping live noise.

---

## 3. Rotation procedures

### 3.1 Master CF API token

Triggered when the token is suspected leaked, or on routine schedule
(annually).

1. **Mint a new token** in CF dashboard → My Profile → API Tokens →
   Create. Permissions: `Zone → DNS → Edit` on `sygen.pro`. Nothing
   else.
2. **Stage it** on the Worker:
   ```bash
   wrangler secret put CF_MASTER_API_TOKEN
   # paste the new token at the prompt
   ```
   This atomically replaces the secret. The Worker picks it up on the
   next request — no redeploy needed.
3. **Smoke test** end-to-end (provision → DNS-challenge → heartbeat →
   release) using
   [`INTEGRATION_TEST_README.md`](./INTEGRATION_TEST_README.md).
4. **Revoke the old token** in CF dashboard → API Tokens → Roll/Delete.
5. **Customer impact: NONE.** `install_token`s are independent of the
   master CF token — they are random opaque strings stored as sha256
   in KV, not signed by anything that depends on the master token.

### 3.2 ADMIN_TOKEN

Same procedure as above but for `ADMIN_TOKEN`. Generate with
`openssl rand -base64 32`. Update any external healthcheck that uses
the bearer token *before* revoking the old one.

### 3.3 Worker route / hostname change

`install.sh` hardcodes `https://install.sygen.pro` as the install base
URL, and the heartbeat/release/dns-challenge URLs are pinned into each
host's `.env` at install time (`SYGEN_INSTALL_HEARTBEAT_URL`).

If the Worker hostname must change:

- **New installs** — update the route in `wrangler.toml`, redeploy, and
  update `install.sh` defaults. Existing one-liner URLs (Pages CDN at
  `install.sygen.pro/install.sh`) keep working until you flip the CDN
  too.
- **Existing installs** — they will keep heartbeating to the *old* URL.
  Options:
  - Keep a permanent CNAME / route alias from the old URL to the new
    Worker (preferred — zero customer impact).
  - Force a re-install on each host (uninstall → reinstall picks up the
    new heartbeat_url; same `install_token` cannot be reused, customer
    gets a NEW fqdn).

This is a **planned** operation — never break the old URL without a
fallback in place.

---

## 4. KV backup + recovery

### 4.1 Why backup matters

KV is the only place reservations live. Cloudflare does not currently
offer point-in-time backup for KV. An operator-fat-fingered
`wrangler kv namespace delete` is unrecoverable from CF's side.

### 4.2 Backup procedure

Run weekly. Both namespaces. Skip `RATELIMIT:` keys (cheap to lose,
auto-expire on a 2h TTL).

```bash
DATE=$(date -u +%F)
BACKUP_DIR=~/sygen-kv-backups/$DATE
mkdir -p "$BACKUP_DIR"

# SUBDOMAIN_RESERVATIONS (excluding rate-limit buckets)
wrangler kv key list --binding SUBDOMAIN_RESERVATIONS \
  | jq -c '.[] | select(.name | startswith("RATELIMIT:") | not)' \
  > "$BACKUP_DIR/reservations.keys.jsonl"

while read -r line; do
  name=$(echo "$line" | jq -r .name)
  value=$(wrangler kv key get --binding SUBDOMAIN_RESERVATIONS "$name")
  jq -nc --arg n "$name" --arg v "$value" '{name:$n, value:$v}' \
    >> "$BACKUP_DIR/reservations.values.jsonl"
done < "$BACKUP_DIR/reservations.keys.jsonl"

# TOKEN_INDEX (sha256 hash → subdomain)
wrangler kv key list --binding TOKEN_INDEX > "$BACKUP_DIR/token_index.keys.json"
jq -c '.[]' "$BACKUP_DIR/token_index.keys.json" | while read -r line; do
  name=$(echo "$line" | jq -r .name)
  value=$(wrangler kv key get --binding TOKEN_INDEX "$name")
  jq -nc --arg n "$name" --arg v "$value" '{name:$n, value:$v}' \
    >> "$BACKUP_DIR/token_index.values.jsonl"
done

# Encrypt and offload
tar czf - "$BACKUP_DIR" | age -r "$AGE_RECIPIENT" > "$BACKUP_DIR.tar.gz.age"
aws s3 cp "$BACKUP_DIR.tar.gz.age" "s3://sygen-ops-backups/kv/"
```

Both `.values.jsonl` files are the source of truth for restore. Keep
the encryption recipient (`age`/`gpg`) under change control —
reservations contain `allocated_to_ip`, which is mildly sensitive.

### 4.3 Restore from backup

```bash
# Decrypt
age -d -i ~/.age/key.txt < "$BACKUP_DIR.tar.gz.age" | tar xz

# Restore reservations
while read -r line; do
  name=$(echo "$line" | jq -r .name)
  value=$(echo "$line" | jq -r .value)
  wrangler kv key put --binding SUBDOMAIN_RESERVATIONS "$name" "$value"
done < "$BACKUP_DIR/reservations.values.jsonl"

# Restore token index
while read -r line; do
  name=$(echo "$line" | jq -r .name)
  value=$(echo "$line" | jq -r .value)
  wrangler kv key put --binding TOKEN_INDEX "$name" "$value"
done < "$BACKUP_DIR/token_index.values.jsonl"

# Sanity-check via /api/health (active_reservations_first_page should be
# back to expected count) and via end-to-end heartbeat from a known token.
```

Restore is idempotent — re-running over partially-restored state is
safe (puts overwrite).

### 4.4 Disaster: KV completely lost

Failure mode: a CF outage, account-level mistake, or namespace deletion
wipes both KV namespaces.

Customer-visible effects:
- `POST /api/heartbeat` returns `404 unknown_token` for every existing
  install. Core logs the error but keeps running — its TLS cert and IP
  binding are local, the heartbeat is only there to keep the *DNS slot*
  alive.
- `DELETE /api/release` returns `200 {released: false}` — idempotent,
  no error surfaced to the user.
- `POST /api/dns-challenge` returns `401 invalid_install_token` — TLS
  renewal via the Worker is broken until restore.
- The fqdn keeps resolving — A records still live in CF DNS, they
  just have no KV row backing them. The daily sweep finds nothing
  (no expired KV row → no DNS delete). **Orphan A records leak forever
  unless cleaned up manually**.
- Customer's existing site keeps working until their LE cert expires
  (~90 days). After that, certbot renewal fails, HTTPS breaks.

Recovery paths, in order of preference:

1. **Restore from latest backup** (§4.3). All reservations come back,
   heartbeats resume, TLS renewals work. Customers see no break.
2. **No backup, but DNS records survive**: re-import each A record into
   KV by reading CF DNS (filter by `comment` or by fqdn pattern
   `*.sygen.pro`), reconstruct a synthetic reservation row with a fresh
   `expires_at` (now + 30d) and a placeholder `install_token_hash`
   (record `RECONSTRUCTED:<fqdn>` so heartbeat returns 404 — customer
   re-runs `install.sh` to get a real token bound to the same fqdn).
   Document this as a recovery script if it ever becomes necessary —
   not pre-built.
3. **No backup, no recovery**: post a status page notice. Each customer
   runs `install.sh` again, gets a NEW `<random>.sygen.pro`. Their old
   A records are now unowned and never get swept (sweep only looks at
   KV, not at DNS). Manually delete orphan A records via the CF
   dashboard or a one-shot `for r in $(cf-cli list); cf-cli delete $r`
   pass — search by `comment="sygen-install:*"` if those tags exist.

**Mitigation** (encouraged but not enforced):
- Keep `~/sygen-kv-backups/` weekly cron green (set up with §4.2).
- Customer-side: `uninstall.sh` writes `install_token` into the `.env`
  archive. A user reinstalling on a new VPS with the preserved `.env`
  keeps their fqdn (no re-provision needed). Document this in the
  customer FAQ (§8).

---

## 5. Incident response

### 5.1 Service down (Worker errors / CF outage)

1. **CF outage check** — visit `https://www.cloudflarestatus.com/`. If
   CF is degraded, there is nothing to do on our side beyond posting a
   status notice.
2. **Live error stream**:
   ```bash
   wrangler tail --status error --format pretty
   ```
   Look for repeated `provision: dns_create_failed`, `kv_put_failed`,
   `dns_challenge: cf_create_failed`. Pattern of failures usually points
   at CF API issues, KV write degradation, or token expiry.
3. **Code regression** — if the failures correlate with the most recent
   `wrangler deploy`:
   ```bash
   wrangler deployments list                    # find prior version
   wrangler rollback --message "rollback: <reason>"
   ```
   Rollback is instant. Confirm with `wrangler deployments list` that
   the active version flipped, then re-run smoke test.

**Customer impact during outage:**
- Existing installs: unaffected. Core heartbeats once a week and
  tolerates failure — DNS reservation TTL is 30 days. The outage has
  to last *weeks* before any reservation actually expires.
- New installs: `install.sh` auto-mode fails fast. Customers fall back
  to `--custom-domain` mode (BYO domain).

### 5.2 Abuse spike (sudden /api/provision spam)

Layered defenses:

1. **Worker in-process rate limit** — 5/h/IP, KV-backed. First defense.
   Already enforced; no action needed.
2. **CF WAF rate-limit rules** (defense-in-depth, configured in
   dashboard per `README.md` §6). If an aggregate flood from many IPs
   bypasses the per-IP limit, escalate the WAF rule to country-block,
   challenge, or stricter caps.
3. **Kill switch** — if abuse is overwhelming and you need an
   immediate stop:
   ```bash
   wrangler delete sygen-subdomain-service
   ```
   This **disables `/api/*` entirely**. Existing installs keep working
   on their already-provisioned A records (no Worker involvement until
   next heartbeat). New installs fail until the Worker is redeployed.
   Document the affected customer fallback (use `--custom-domain` mode)
   on a status page.
4. **Targeted IP block** — for a single bad actor, add a CF firewall
   rule: `(ip.src in {1.2.3.4})` → block. Surgical, no Worker change.

After the incident, raise the sweep cap if KV size grew during the
spike (orphaned reservations from rate-limited or failed calls — though
the rate limiter rejects *before* we touch KV/DNS, so this should be
small).

### 5.3 KV namespace at quota

CF KV limits (Workers Paid plan, current as of 2026-04):
- 1B keys, 25 GB storage per namespace
- 1M writes/day, 10M reads/day on the included quota; pay-per-use
  beyond.

Current expected steady state (1k active users, see §6) is ~2k keys
total — three orders of magnitude below the limit.

Alert thresholds (recommend):
- Storage > 50% of plan → investigate
- Active reservations > 100k → audit for stuck rows (no heartbeat in
  60+ days; sweep should have caught these — if not, it's a sweep bug)

If approaching limit:
1. Increase `MAX_PER_RUN` in `src/sweep.js` to drain the backlog faster
   (default 200/day → bump to 1000 for a few days, then revert).
2. Manually inspect for `expires_at` dates in the past:
   ```bash
   wrangler kv key list --binding SUBDOMAIN_RESERVATIONS --prefix "" \
     | jq -r '.[].name' \
     | while read k; do
         v=$(wrangler kv key get --binding SUBDOMAIN_RESERVATIONS "$k")
         echo "$k $(echo "$v" | jq -r .expires_at)"
       done
   ```
3. If thousands of stuck rows: trigger the sweep manually multiple
   times in succession (`wrangler dispatch scheduled --cron "0 2 * * *"`).

### 5.4 Rate-limit false positives

Customer reports "I can't install — Worker says 429 / rate_limited".

```bash
# Find the offending key. CF-Connecting-IP is the customer's egress IP.
wrangler kv key list --binding SUBDOMAIN_RESERVATIONS --prefix "RATELIMIT:"

# Confirm with the customer's claimed IP, then:
wrangler kv key delete --binding SUBDOMAIN_RESERVATIONS "RATELIMIT:<ip>:<window>"
```

Or have the customer wait — buckets are 1-hour fixed windows and KV
keys carry a 2h `expirationTtl`, so the cap resets within the hour
naturally.

If the customer is on a NATed network (corporate/university) and the
shared egress IP keeps tripping the limit, raise the cap once
permanently:

```bash
wrangler secret put PROVISION_RATE_LIMIT       # set to "20"
# or set [vars] PROVISION_RATE_LIMIT="20" in wrangler.toml and redeploy
```

(Vars are non-secret; secrets are appropriate if you'd rather not bake
the cap into the toml.)

---

## 6. Capacity planning

| Resource | Free tier | Paid (Workers Paid, $5/mo) | At 1k users |
|---|---|---|---|
| Worker requests | 100k/day | 10M/mo | ~7k/day (heartbeats) + bursty provision |
| KV writes | 1k/day | 1M/day | ~150/day heartbeats + provisions |
| KV reads | 100k/day | 10M/day | ~150/day + admin lookups |
| KV storage | 1 GB | 25 GB | ~2 MB (1k×~1 KB rows + index) |
| CF DNS API | zone-shared 1200 req / 5 min | same | ~150/day = trivial |

Headroom is enormous; the dominant scaling concern is CF DNS API rate
on burst provisions, not Workers/KV. The in-process rate limiter
already caps a single IP to 5/h, so a 1200/5min zone burn requires
~60 distinct attacker IPs — at which point CF WAF rules kick in.

CF Pro plan on the zone is recommended (faster propagation + higher
WAF rule allowance). Not required.

---

## 7. Monitoring + alerting (recommendations)

This runbook documents *what* to monitor, not the deployment. Pick the
tooling that fits your ops stack.

| Signal | Source | Alert condition |
|---|---|---|
| Worker availability | External probe (UptimeRobot etc.) on a public surface (e.g. `GET /api/health` with stored bearer, or a yet-to-add `/api/ping`) | 5xx for >10 min |
| Error rate | `wrangler tail` piped to log aggregator | `level=error` count > 5/min |
| p95 latency | CF Workers Analytics | p95 > 1s sustained |
| KV size | weekly `wrangler kv key list ... \| wc -l` | > 50% of capacity |
| Sweep liveness | `wrangler tail --search "sweep: done"` | no `sweep: done` log in 36h |
| DNS API failures | `wrangler tail --search "cf_create_failed"` | > 5/h |

CF Workers Analytics (dashboard → Workers → Metrics) gives request
count, error rate, p50/p95/p99 latency out of the box. Enable it once
on the Worker; no setup beyond that.

---

## 8. Common questions (customer-facing FAQ source)

- **Q: Why can't I use my own domain?** Free `*.sygen.pro` mode is the
  default. Custom domains are supported via `install.sh --custom-domain`
  (BYO DNS). Direct ownership in the Worker UI is deferred to v2.

- **Q: How long does my subdomain live?** 30 days from the last
  successful heartbeat. Core auto-pings weekly. If the host is offline
  for 30+ days, the daily sweep reclaims the slot.

- **Q: Can I keep my fqdn after reinstalling on a different VPS?** Yes.
  `uninstall.sh` preserves `install_token` inside the archived `.env`.
  Restore that `.env` on the new VPS and re-run `install.sh` — same
  fqdn, new IP. (The Worker's per-install_token mapping doesn't care
  about IP changes.)

- **Q: My fqdn got reclaimed accidentally — can I get it back?** Once
  the daily sweep deletes the slot it's available for the next caller.
  Re-run `install.sh` to get a fresh `<random>.sygen.pro`. If you have
  a `.env` backup from before reclamation, restore it first — same
  install_token will reattach to the original fqdn *only if* the slot
  hasn't been reissued.

- **Q: How do I see all my reservations?** We don't track per-user
  ownership (no auth on the Worker). Each `install_token` maps to one
  fqdn. Lose the token → can't recover the slot.

- **Q: Why is /api/health locked behind admin token?** It exposes
  reservation counts; we don't want public scraping. A separate
  unauthenticated `/api/ping` could be added if external uptime
  monitoring needs it.

---

## 9. Worker source map

Quick reference for "where does *X* live?":

| Concern | File |
|---|---|
| Routing + scheduled trigger | `src/worker.js` |
| Provision handler | `src/handlers/provision.js` |
| Heartbeat handler | `src/handlers/heartbeat.js` |
| Release handler | `src/handlers/release.js` |
| ACME DNS-01 challenge | `src/handlers/dns_challenge.js` |
| Admin health | `src/handlers/health.js` |
| Daily sweep | `src/sweep.js` |
| Cloudflare API client | `src/lib/cf.js` |
| Token gen + sha256 | `src/lib/crypto.js` |
| Per-IP rate limit | `src/lib/ratelimit.js` |
| JSON response helper | `src/lib/response.js` |
| Subdomain alphabet + blacklist | `src/lib/subdomain.js` |
| Worker config (route, KV, cron, vars) | `wrangler.toml` |
| Tests | `src/__tests__/*.test.js` |
| Pre-deploy checklist | [`README.md`](./README.md) |
| End-to-end smoke tests | [`INTEGRATION_TEST_README.md`](./INTEGRATION_TEST_README.md) |

For architectural rationale see
`sygen-clean/PHASE3_subdomain_provisioning_design.md` and
`PHASE3_TLS_token_scoping_decision.md`.
