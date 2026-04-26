# Sygen — Frequently Asked Questions

Quick answers to the most common questions. If your question isn't here, open an [issue](https://github.com/alexeymorozua/sygen-install/issues) or contact support.

---

## Getting started

### What is Sygen?

Sygen is a self-hosted AI assistant framework. You run it on your own VPS or Mac/PC, connect Anthropic's Claude (or OpenAI Codex / Google Gemini), and get a personal AI assistant accessible through iOS, Android, or a web admin panel. Your conversations, files, and memory live entirely on your hardware — Sygen never sees your data.

### Where should I install it?

Three paths, pick by your situation:

| Path | Best for | Setup difficulty |
|------|----------|------------------|
| **VPS auto-mode** | You want it always-on, accessible from anywhere | Easy — iOS wizard handles everything |
| **Mac/PC + Tailscale** | You already have a Mac that's on most of the time | Easy — install Tailscale on Mac + iPhone, run wizard |
| **Mac/PC + public domain** | Advanced: own domain, want public access without VPS | Hard — requires router port forwarding |

The iOS app's "Add server" wizard walks you through all three.

### What VPS providers do you recommend?

Three globally-recommended providers (good price, reliable, ample regions):

- **Hetzner Cloud** — best value in EU, ~€4/mo
- **DigitalOcean** — easy onboarding, ~$6/mo
- **Vultr** — widest region coverage, ~$6/mo

The full list of 48 supported providers (with regional filters) is in the iOS app. You can also use any other provider — Sygen works on any Debian 12+ / Ubuntu 22+ VPS with root access.

### What are the minimum requirements?

- **CPU:** 2 vCPU
- **RAM:** 2 GB (4 GB recommended for heavy use)
- **Disk:** 20 GB (more if you store many files)
- **OS:** Debian 12+ or Ubuntu 22+ (Linux), or macOS 13+ (Mac/PC path)
- **Network:** public IPv4 (for VPS path), or Tailscale-connected device

---

## Installation

### How do I install Sygen on a VPS?

**Recommended:** use the iOS app's "Add server" → VPS Deploy Wizard. Pick a provider, rent a VPS (you'll get root credentials by email), enter them in the wizard. Sygen will be installed automatically — you get a working HTTPS admin URL within ~5-7 minutes.

**Manual install (advanced):**
```bash
ssh root@your-vps-ip
curl -fsSL https://install.sygen.pro/install.sh | bash
```
This runs the auto-mode flow: a free `<random>.sygen.pro` subdomain is allocated, TLS certificate is issued, Sygen starts up. The final output prints your admin password.

### How do I install Sygen on my Mac/PC (via Tailscale)?

Prerequisites:
1. Install Tailscale on your Mac/PC and on your iPhone (App Store).
2. Sign both into the same Tailscale account.
3. Make sure MagicDNS + HTTPS Certificates are enabled at https://login.tailscale.com/admin/dns

Then in the iOS app, "Add server" → "Set up on my own Mac/PC" → "Tailscale". The wizard SSH's into your Mac and installs Sygen. Your access URL will be like `https://<host-name>.<tailnet>.ts.net`.

**Tailscale-mode also works on Linux** (home server, NAT'd VPS, anything with a tailnet) — same flow. The installer detects Linux automatically; pass `SELF_HOSTED_MODE=tailscale` (or `--self-hosted=tailscale`) to enable it:
```bash
ssh root@your-linux-box
curl -fsSL https://install.sygen.pro/install.sh | SELF_HOSTED_MODE=tailscale bash
```
No public IP, no port forwarding, no Cloudflare needed. `tailscale serve` terminates TLS using the cert Tailscale auto-issues + auto-renews.

### Can I use my own domain instead of `<random>.sygen.pro`?

Yes — that's "custom mode". You'll need:
1. Your own domain hosted on Cloudflare
2. A Cloudflare API token with `Zone.DNS:Edit` permission

Then run the install script with environment variables:
```bash
curl -fsSL https://install.sygen.pro/install.sh | \
  SYGEN_SUBDOMAIN=alice \
  CF_API_TOKEN=cfat_xxx \
  CF_ZONE_ID=your-zone-id \
  bash
```
Custom mode doesn't use our Worker — your URL stays yours forever, regardless of how long the VPS is offline.

### How long does install take?

Typically 3-7 minutes for a VPS install:
- ~1 min: apt-get install (Docker, nginx, certbot)
- ~30 sec: subdomain provisioning + DNS propagation
- ~30 sec: TLS certificate issuance via Let's Encrypt
- ~2-4 min: pulling Docker images and starting Sygen

Slower on smaller VPS plans or in regions with slow apt mirrors.

---

## TLS / certificates / `<random>.sygen.pro`

### How does HTTPS work?

Each Sygen install gets its own dedicated certificate, issued automatically during install and renewed every 60 days. Wildcard certificates are intentionally *not* used — compromising one VPS doesn't affect any other Sygen install.

The installer tries three independent free CAs in order: **Let's Encrypt** (primary), **ZeroSSL** (fallback), **Google Trust Services** (last resort). If the primary is rate-limited, the installer transparently falls back to the next one — your install just works without you noticing. Renewals continue with whichever CA issued the original cert.

### What is `install.sygen.pro` and do I need a Cloudflare account?

`install.sygen.pro` is our backend service (a Cloudflare Worker) that:
1. Allocates a free `<random>.sygen.pro` subdomain to your VPS
2. Helps issue TLS certificates via DNS-01 challenge
3. Tracks when your install was last seen (weekly heartbeat)

You **don't** need a Cloudflare account. The Worker is operated by us — you just benefit from free subdomains and automatic TLS.

### Can someone else use the URL my VPS got?

No. Subdomains are bound to your install_token. Even if someone learns your URL, they need an admin login to do anything — and the URL itself doesn't expose your data.

If you stop using your install (VPS offline >30 days, no heartbeat), your subdomain returns to the free pool and may be assigned to a new install. The previous install's TLS certificate becomes invalid the moment its DNS records are removed.

---

## Updates & maintenance

### How do I update Sygen?

Updates run automatically via Watchtower (a service installed alongside Sygen). It checks GitHub Container Registry hourly and pulls new images as they're released. No action needed on your part.

To force-update manually:
```bash
ssh root@your-server
cd /srv/sygen
docker compose pull
docker compose up -d
```

### How do I back up my data?

Linux installs run a nightly backup automatically: `/var/backups/sygen/sygen-YYYY-MM-DD.tar.gz` (7-day retention).

Manual backup:
```bash
ssh root@your-server
tar czf sygen-backup-$(date +%F).tar.gz -C /srv/sygen data .env docker-compose.yml
scp root@your-server:sygen-backup-*.tar.gz ~/Desktop/
```

To restore on a fresh install: stop Sygen, untar into `/srv/sygen/`, restart.

### How do I uninstall Sygen?

```bash
ssh root@your-server
curl -fsSL https://install.sygen.pro/uninstall.sh | bash
```
This stops containers, removes Docker, releases your subdomain back to the pool, deletes data. Irreversible — back up first if you have anything you want to keep.

### My VPS was offline for over a month. Is my Sygen still accessible?

Probably not at the same URL. The Worker reclaims subdomains after 30 days without a heartbeat — so your `<old>.sygen.pro` is gone and may have been reassigned.

**Your data is safe.** It lives on your VPS, not on our infrastructure. Re-run the install wizard with the same VPS:
```bash
curl -fsSL https://install.sygen.pro/install.sh | bash
```
The script detects the orphaned reservation, requests a new subdomain, reconfigures TLS — and your existing data, sessions, and conversations are preserved. You'll get a new URL; update it in the iOS/Android app by removing the old server entry and adding the new one.

If you want a permanent URL that never expires, use [custom mode](#can-i-use-my-own-domain-instead-of-randomsygenpro) with your own domain.

---

## Privacy & security

### Where does my data live?

Entirely on your hardware. Sygen runs in Docker on your VPS or Mac. Your conversations, files, and memory are stored in `/srv/sygen/data/` (or `~/.sygen-local/data/` on Mac). We have zero access to it.

The only data that touches our infrastructure is:
- Your subdomain reservation (an opaque token + 30-day expiration)
- Outbound DNS challenge requests (during cert issuance/renewal)

We don't see your prompts, responses, files, or any user content.

### What does the AI provider see?

Whatever you send it. If you use Claude, your prompts go to Anthropic's API. If you use Codex, to OpenAI. Standard provider TOS apply. Sygen itself doesn't proxy or log them.

### Is Sygen open source?

Source-available. The installer + Worker are public at https://github.com/alexeymorozua/sygen-install. The core is licensed under [BSL 1.1](https://mariadb.com/bsl11/) — you can read, run, and modify the code freely; commercial redistribution at scale requires a license. After 4 years each release converts to a permissive open-source license automatically.

### Has it been security-reviewed?

Yes. The install scripts, Worker, core, and admin panel have been reviewed by the security-review skill (Anthropic's automated code review). All findings have been addressed.

---

## Troubleshooting

### iPhone can't reach my Sygen install — "couldn't connect" error

Check in this order:
1. Open the URL in Safari first — does the admin login page load? If no, your VPS is down or DNS hasn't propagated yet (wait ~5 min after install).
2. Tailscale users: are both iPhone and Mac on the same tailnet? Run `tailscale status` on Mac.
3. publicdomain users: are router ports 80/443 forwarded to the Mac?
4. Custom domain users: does `dig <yourdomain>` show your VPS IP?

### Install fails immediately, "CommandFailed exitCode 1" with no real error

Most common cause: your VPS provider gives the server with an **expired root password** (security policy), and the installer can't run commands until you change it. Symptoms:
- iOS app's "Test Connection" succeeds
- "Install" immediately fails with generic error (no logs)
- SSH from terminal shows `Your password has expired. Password change required but no TTY available.`

**Fix (one minute):** SSH from any Mac/PC terminal once:
```bash
ssh root@<your-vps-ip>
# Provider-given password
# System will prompt for new password — enter twice
exit
```

Then return to the iOS wizard and re-enter the **new** password. Install will proceed normally.

Providers known to ship with expired passwords: Hostiko, sometimes Hostinger, some Hetzner Cloud setups. Cloud providers like DigitalOcean, Vultr, Linode normally don't (root password is preset, not expired).

### Install script fails on "waiting for DNS propagation"

Cloudflare's DNS update usually takes 30-60 seconds. If it times out (>2 min):
- Check that the Worker is reachable: `curl -i https://install.sygen.pro/api/provision -d '{}'` should return 200.
- Try again — DNS occasionally flaps.
- If repeating fails, open an issue.

### iPhone shows "profile expired" or "cannot launch app"

This is an iOS-level issue with the **provisioning profile** of the app, not Sygen. Apple-distributed (TestFlight or App Store) builds expire on different schedules:
- TestFlight: invitation valid for 90 days, builds expire in 90 days
- AltStore / Sideloadly with free Apple ID: 7 days
- AltStore / paid Apple Developer: 1 year

Solution depends on your install method — refresh the app in AltStore, or wait for a new TestFlight build.

---

## Costs

### How much does Sygen cost?

Sygen itself is **free** — open-source, MIT-licensed (will be at v1.0).

You only pay for:
1. Your VPS rental (~$4-10/mo from Hetzner/DigitalOcean/Vultr) — or $0 if you self-host on Mac/PC
2. AI API usage (Claude, OpenAI, etc.) — pay-per-token directly to the provider

We don't charge anything for the subdomain service, Worker hosting, or installer. As long as the project exists.

---

## Support & feedback

- **Bugs / feature requests:** https://github.com/alexeymorozua/sygen-install/issues
- **Questions:** open a discussion in the same repo
- **Security issues:** email security@sygen.pro

---

*Last updated: 2026-04-26*
