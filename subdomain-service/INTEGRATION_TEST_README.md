# Subdomain Service — Integration Test

`integration-test.sh` is the end-to-end smoke test for the deployed
Worker. Run it after `wrangler deploy` to verify the live Worker actually
talks to Cloudflare DNS + KV correctly. It is not a substitute for
`npm test` (the Node unit suite); the two cover different layers.

## What it tests

Eleven steps against a real Worker:

| #   | Step                                                                 |
|-----|----------------------------------------------------------------------|
| 1   | `POST /api/provision` returns 200 + all required fields              |
| 2   | The new fqdn resolves via public DNS to the caller's IP              |
| 3   | `POST /api/dns-challenge` for the owned `_acme-challenge.<sub>` name |
| 4   | `POST /api/dns-challenge` for an out-of-scope name → **403**         |
| 5   | `DELETE /api/dns-challenge` removes the TXT record                   |
| 6   | `POST /api/heartbeat` extends `expires_at` into the future           |
| 7   | `POST /api/heartbeat` with a bogus token → **404**                   |
| 8   | Repeated `POST /api/provision` from the same IP → **429** within batch |
| 9   | `DELETE /api/release` with the valid token → 200, A record gone      |
| 10  | `DELETE /api/release` with the same token again → 200 `released:false` (idempotent) |
| 11  | Cleanup: release every subdomain allocated during the rate-limit batch |

## What it does NOT test

- **Actual Let's Encrypt cert issuance.** The script verifies the
  Worker's DNS-01 mediation endpoint, but does not run certbot or fetch
  a real certificate. End-to-end TLS issuance happens during a real
  `install.sh` run on a VPS — see the Phase 3 Task G runbook.
- **Cloudflare WAF rate-limit rules.** Only the Worker's in-process
  rate limit (`PROVISION_RATE_LIMIT`, default 5/h/IP) is exercised.
- **Daily sweep cron.** Tested by `src/__tests__/sweep.test.js` against
  in-memory KV; live cron firing isn't asserted here.

## Prerequisites

On the host running the script:

- `bash` 4+ (macOS default `/bin/bash` is 3.2 — Homebrew bash works)
- `curl`
- `jq`
- `dig` (BIND `dnsutils` / `bind-tools`)

On the Cloudflare side:

- The Worker is deployed and bound to `install.sygen.pro/api/*`.
- KV namespaces and `CF_MASTER_API_TOKEN` are configured per the main
  README's pre-deploy checklist.
- The host's outbound IP is **not** already over the 5/h
  `/api/provision` cap (i.e. don't re-run the script back-to-back).

## Quick run

```bash
cd subdomain-service
./integration-test.sh
```

Exit code `0` = all checks passed. Non-zero = the failing step number
and reason are printed to stderr.

## Overrides

| Env var                     | Default                       | Purpose                                    |
|-----------------------------|-------------------------------|--------------------------------------------|
| `WORKER_URL`                | `https://install.sygen.pro`   | Target Worker (use for staging zones)      |
| `DIG_RESOLVER`              | `1.1.1.1`                     | Public resolver for `dig` checks           |
| `DNS_PROPAGATION_TIMEOUT`   | `60` (sec)                    | Wait budget for DNS appear/disappear       |
| `RATE_LIMIT_MAX_ATTEMPTS`   | `6`                           | Max provision retries in the rate-limit step |

Examples:

```bash
WORKER_URL=https://my-staging.workers.dev ./integration-test.sh
DNS_PROPAGATION_TIMEOUT=120 ./integration-test.sh    # slow resolver
```

## Cleanup behavior

- Step 9 releases the primary subdomain, step 11 releases every
  rate-limit batch token.
- An `EXIT` trap also releases anything still tracked, so a mid-script
  failure won't leak orphan subdomains.
- Worst case (network failure during cleanup): the daily sweep
  reclaims the slot after `TTL_DAYS` (default 30).

## Common failures and what to do

**Step 1 fails with HTTP 429**
Your IP already burned its 5/h `/api/provision` budget — wait an hour
or run from a different IP. The script's own retries don't reset the
window.

**Step 2 times out / wrong IP**
DNS propagation is slower than the budget, or the host is behind a NAT
where outbound IP differs from the Worker's `CF-Connecting-IP`. The
script downgrades the IP-mismatch case to a warning, but a complete
no-resolve is a hard fail. Re-run with `DNS_PROPAGATION_TIMEOUT=120`
or query the authoritative NS directly:

```bash
dig @1.1.1.1 +trace <fqdn>
```

**Step 4 returns 200 instead of 403**
The Worker is not enforcing the name-scope check on
`/api/dns-challenge`. This is a security regression — check
`src/handlers/dns_challenge.js` and `dns_challenge.test.js`. Do not
ship the Worker until fixed.

**Step 7 returns 200 instead of 404**
Heartbeat is accepting unknown tokens. Check
`src/handlers/heartbeat.js` and the matching unit tests.

**Step 8 never sees a 429**
Either `PROVISION_RATE_LIMIT` is set very high, or the in-process
rate limit isn't wired up. Check `src/lib/ratelimit.js` and
`wrangler tail` while re-running.

**Anything else / Worker offline**
Watch live logs:

```bash
wrangler tail
```

Then re-run the script in a second terminal.

## Safety

The script creates real DNS records and KV entries on the live zone.
It cleans up after itself on the happy path and on most failure paths.
Don't run it against a production Worker that has live customers
without coordinating — the rate-limit step temporarily burns through
the IP-level provision budget.
