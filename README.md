# sygen-install

One-shot installer for a single-node Sygen deployment.

Supported: Linux (Debian 12+/Ubuntu 22+ VPS), macOS (local dev). Windows/WSL2
is planned but not yet supported.

Pulls the Sygen stack (core + admin web) from GHCR. On Linux it provisions
DNS + TLS via Cloudflare and wires up an nginx reverse proxy; on macOS it
runs everything inside Colima bound to `localhost` — no DNS/TLS/nginx.

## Usage — Linux (VPS)

### Auto-mode (default)

No env vars needed. The installer requests a free `<id>.sygen.pro` subdomain
from `install.sygen.pro/api/provision` (which creates the Cloudflare DNS
record and mints a one-hour DNS-01 token for Let's Encrypt). The final fqdn
is shown at the end of the run and emitted in `--json-output`.

```bash
curl -fsSL https://install.sygen.pro/install.sh | sudo bash
```

The reservation is kept alive by a weekly heartbeat from core to
`install.sygen.pro/api/heartbeat`, using the `SYGEN_INSTALL_TOKEN` saved
in `/srv/sygen/.env`. If heartbeats stop for 30+ days the subdomain is
reclaimed and the DNS record deleted; the next install on the same host
gets a fresh `<id>.sygen.pro`. `uninstall.sh` releases the slot
explicitly via `DELETE /api/release` (see [Uninstall](#uninstall) below).

If the provision endpoint is unreachable, the installer fails fast — set
the custom-mode env vars below to fall back to a self-managed subdomain.

### Custom mode (bring your own subdomain)

For admin-managed installs on a Cloudflare zone you control. Set all three
env vars; the auto-provision call is skipped, DNS is upserted with the
operator-supplied token, and no `SYGEN_INSTALL_TOKEN` is written (no
heartbeat or auto-reclaim).

```bash
curl -fsSL https://install.sygen.pro/install.sh | \
    SYGEN_SUBDOMAIN=alice \
    CF_API_TOKEN=cfat_xxx \
    CF_ZONE_ID=6ae59801f8ac7b5dc33b6e32d844b0a6 \
    sudo bash
```

## Usage — macOS (self-hosted on your own Mac)

The macOS branch has three sub-modes, selected via `SELF_HOSTED_MODE`. All
share the same Colima + docker stack — the difference is only how the
admin UI is exposed (and whether your iPhone can reach it).

| Mode           | iPhone access     | TLS                  | Setup work             |
|----------------|-------------------|----------------------|------------------------|
| `localhost`    | no                | none (plain HTTP)    | none                   |
| `tailscale`    | yes (on tailnet)  | Tailscale-issued     | install Tailscale      |
| `publicdomain` | yes (public DNS)  | Let's Encrypt        | router NAT port forward |

If `SELF_HOSTED_MODE` is unset and you run interactively, the installer
prompts for a choice (defaulting to `tailscale` if it detects a logged-in
tailnet, else `localhost`).

### Sub-mode: `localhost` (Mac-only access)

```bash
curl -fsSL https://install.sygen.pro/install.sh | bash
```

Requires [Homebrew](https://brew.sh). The installer will `brew install`
Colima + docker CLI, start a 4-CPU / 8 GB / 50 GB Colima VM, and run Sygen at
`http://localhost:8080`. No root, no DNS, no TLS — and **no iPhone
connectivity** (App Transport Security on iOS blocks plain HTTP).

### Sub-mode: `tailscale` (recommended)

Install [Tailscale](https://tailscale.com/kb/1017/install) on the Mac (`brew
install --cask tailscale` or App Store), run `tailscale up`, and confirm
`tailscale status` works in the terminal. Make sure HTTPS Certificates is
enabled in your tailnet admin (https://login.tailscale.com/admin/dns →
HTTPS Certificates). Also install Tailscale on your iPhone and join the
same tailnet.

```bash
curl -fsSL https://install.sygen.pro/install.sh | \
    SELF_HOSTED_MODE=tailscale bash
```

The installer reads the Mac's MagicDNS name (e.g.
`mac-mini.tail-abc123.ts.net`), then runs `tailscale serve` to terminate
TLS at port 443 and proxy `/`, `/api/`, `/ws/`, `/upload` to the right
container. The cert is issued and renewed by Tailscale; nothing is
exposed to the public internet.

```bash
sudo tailscale serve status   # show current routes
sudo tailscale serve reset    # drop all routes (then re-run install.sh)
```

### Sub-mode: `publicdomain` (advanced — public *.sygen.pro)

Same Worker DNS-01 + Let's Encrypt flow as the Linux auto-mode, but
running on macOS. The installer will `brew install nginx certbot` and
configure nginx as the TLS terminator on ports 80/443. **It uses `sudo`
for cert acquisition and to bind 80/443.**

You must set up NAT port forwarding on your router *before or shortly
after* running the installer:

- external port 80  → this Mac's port 80  (cert renewal via HTTP-01 fallback)
- external port 443 → this Mac's port 443 (iPhone HTTPS access)

```bash
curl -fsSL https://install.sygen.pro/install.sh | \
    SELF_HOSTED_MODE=publicdomain bash
```

Limitations vs. the Linux auto-mode:

- **No auto-renewal.** Certbot's launchd timer is not configured; renew
  manually every ~80 days:

  ```bash
  sudo $(brew --prefix)/bin/certbot renew \
      --manual-auth-hook /usr/local/sbin/sygen-acme-auth-hook.sh \
      --manual-cleanup-hook /usr/local/sbin/sygen-acme-cleanup-hook.sh && \
  sudo nginx -s reload
  ```

- **No nginx auto-start.** nginx is started with plain `sudo nginx`;
  after a reboot, run it again or wire up your own launchd plist. (The
  Colima VM and the Sygen compose stack themselves do auto-start — see
  [Auto-start on reboot](#auto-start-on-reboot) below.)

For most self-hosted Mac users, **prefer `tailscale` mode** — it sidesteps
the port-forwarding, cert-renewal, and reboot-recovery work above.

### Lifecycle (all macOS sub-modes)

```
Stop:       colima stop
Start:      colima start && cd ~/.sygen-local && docker compose up -d
Upgrade:    cd ~/.sygen-local && docker compose pull && docker compose up -d
Uninstall:  curl -fsSL https://install.sygen.pro/uninstall.sh | bash
```

Auto-start on login/boot is configured automatically (see [Auto-start
on reboot](#auto-start-on-reboot)). Backups are not yet configured on
macOS — back up `~/.sygen-local` manually if needed.

See the header of [`install.sh`](./install.sh) for the full env var list.

## Output formats

By default `install.sh` prints a human-readable banner at the end with the
admin URL, generated password, image refs, and follow-up commands.

For SSH-driven deploy wizards (e.g. the iOS deploy flow), pass
`--json-output` or set `SYGEN_JSON_OUTPUT=1` to get a single
machine-parseable JSON line on stdout instead. Progress logs still go to
stderr so the operator can watch the install in real time.

```bash
# success: one JSON line on stdout, ok=true (auto-mode shown — no env vars)
curl -fsSL https://install.sygen.pro/install.sh | \
    SYGEN_JSON_OUTPUT=1 sudo bash
# {"ok":true,"fqdn":"s3xk7f2p.sygen.pro","admin_user":"admin","admin_password":"...","admin_url":"https://s3xk7f2p.sygen.pro","core_image":"...","admin_image":"...","data_dir":"/srv/sygen/data","compose_file":"/srv/sygen/docker-compose.yml","install_token":"sit_..."}
```

`install_token` is `null` in custom mode and a `sit_...` string in auto-mode;
deploy wizards (e.g. iOS) can persist it alongside provider creds for later
reference. Day-to-day heartbeat traffic is handled by core itself — wizards
do not need to call `/api/heartbeat` themselves.

On failure the script still emits a single JSON line and exits non-zero:

```json
{"ok":false,"error":"<reason>","stage":"deps|dns|cert|data|compose|smoke|nginx|bootstrap","details":"<short>"}
```

The default (no flag, no env var) banner output is unchanged.

## Files

- [`install.sh`](./install.sh) — installer entry point
- [`docker-compose.yml`](./docker-compose.yml) — the stack
- [`nginx.conf.tmpl`](./nginx.conf.tmpl) — nginx vhost template (`__FQDN__`
  is substituted by the installer)
- [`providers.json`](./providers.json) — VPS provider catalogue consumed by
  the iOS app onboarding flow
- [`providers/logos/`](./providers/logos) — 64×64 SVG logos referenced by
  `providers.json#logo_url` (one per provider id, plus `_default.svg`).
  Major brands use [Simple Icons](https://simpleicons.org/) on a brand-tinted
  circle; regional providers fall back to a single-letter monogram. To add
  a new provider, drop `<id>.svg` here and reference it from `providers.json`.
- `CNAME` — custom-domain marker for GitHub Pages

## Hosting

This repo is served on `install.sygen.pro` via GitHub Pages + a Cloudflare
CNAME. Edits to `main` publish within a minute.

## Upgrade on a deployed host

```bash
cd /srv/sygen
docker compose pull && docker compose up -d
```

## Auto-updates

A fresh install keeps itself current without manual intervention:

- **Container images** — Watchtower polls GHCR every 30 minutes for new
  digests on labeled containers and writes a state file that the admin
  UI reads via `/api/system/updates`. Watchtower itself runs in
  `--monitor-only` mode — it **detects** updates but never applies them.
  The actual `docker compose pull && up -d` is driven by the
  `sygen-updater` sidecar from an admin click, so an in-flight Claude
  session is never killed mid-work.
- **OS security patches** — `unattended-upgrades` is installed and
  enabled (`/etc/apt/apt.conf.d/20auto-upgrades`). The distro default
  `50unattended-upgrades` policy is security-only.
- **TLS certs** — `certbot.timer` (shipped by the `certbot` package)
  runs twice daily. A deploy hook at
  `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` reloads nginx
  after each successful renewal.

### Updating the updater sidecar itself

The `sygen-updater` service is intentionally **not** labeled for
Watchtower (and the apply path excludes it from its own service list)
because a container cannot safely tear itself down mid-request. To
upgrade the sidecar, run:

```bash
cd /srv/sygen
docker compose pull updater
docker compose up -d updater
```

This is a once-per-release operator action. The core + admin containers
keep getting one-click updates from the admin UI as normal.

Opting out:

```bash
# Stop container image updates
cd /srv/sygen && docker compose rm -sf watchtower

# Stop OS security updates
systemctl disable --now unattended-upgrades

# Stop the nginx reload on cert renewal (certs still renew)
rm /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

## Auto-start on reboot

A fresh install brings the Sygen stack back up automatically after every
host reboot, so power blips and scheduled reboots don't require any
manual recovery.

- **macOS** — two LaunchAgents in `~/Library/LaunchAgents/`:
  - `pro.sygen.colima.plist` starts the Colima profile at user login.
  - `pro.sygen.compose.plist` runs `~/.sygen-local/bin/sygen-startup.sh`,
    which polls `docker info` until the daemon answers (Colima cold-boot
    is ~5–15 s on Apple VF) and then runs `docker compose up -d` from
    `~/.sygen-local`. Logs land in `~/.sygen-local/logs/colima-launchd.{log,err}`
    and `~/.sygen-local/logs/sygen-startup.{out,err}`.
- **Linux** — a single systemd unit at
  `/etc/systemd/system/sygen-compose.service` ordered `After=docker.service`.
  `Type=oneshot` + `RemainAfterExit=yes` runs `docker compose up -d` once
  per boot.

Disabling:

```bash
# macOS
launchctl unload ~/Library/LaunchAgents/pro.sygen.compose.plist
launchctl unload ~/Library/LaunchAgents/pro.sygen.colima.plist

# Linux
systemctl disable --now sygen-compose.service
```

`uninstall.sh` removes both surfaces automatically.

Out of scope: the macOS `publicdomain` sub-mode runs nginx outside the
compose stack — Sygen will be back up on reboot, but `nginx` won't be
serving 80/443 until you start it manually (or wire your own plist).

## Backups

A `sygen-backup.timer` systemd unit runs daily and writes a compressed
archive of `/srv/sygen/{data,.env,docker-compose.yml,claude-auth}` to
`/var/backups/sygen/sygen-YYYY-MM-DD.tar.gz`. Archives older than 7 days
are pruned automatically. Each archive is `chmod 600` because it contains
the API token, JWT secret, and Claude OAuth credentials.

The first snapshot is taken at the end of the install run, so a fresh
host has a usable backup right away.

### Restore on a new host

After running `install.sh` on the replacement VPS (so DNS, certs, and the
stack are wired up), drop a backup tarball into place:

```bash
cd /srv/sygen && docker compose down
tar -xzf /var/backups/sygen/sygen-YYYY-MM-DD.tar.gz -C /srv/sygen/
docker compose up -d
```

### Off-site copy

The installer doesn't ship any off-site sync — pull or push the archives
yourself. Example with rsync:

```bash
rsync -az /var/backups/sygen/ user@backup-host:/backups/sygen-$(hostname)/
```

### Disabling

```bash
systemctl disable --now sygen-backup.timer
```

## Uninstall

Clean removal of the entire stack — containers, data, secrets, systemd
backup timer, nginx vhost, and cert renewal hook. Keeps the Let's Encrypt
cert and system packages so re-installing is fast.

If the install used a free `*.sygen.pro` subdomain, the script also calls
`DELETE https://install.sygen.pro/api/release` (using the
`SYGEN_INSTALL_TOKEN` saved in `.env` at install time) so the subdomain
slot is freed for the next user. The release call is best-effort — a
network/API failure won't block the local cleanup, and the slot will
eventually be reaped by the nightly sweep.

```bash
# Linux (VPS, run as root):
curl -fsSL https://install.sygen.pro/uninstall.sh | sudo bash

# macOS (local dev):
curl -fsSL https://install.sygen.pro/uninstall.sh | bash
```

The script prompts for confirmation. Set `SYGEN_UNINSTALL_CONFIRM=1` to
skip the prompt (CI / automation).

To also release the Cloudflare DNS A record, pass the same env vars used
at install time:

```bash
curl -fsSL https://install.sygen.pro/uninstall.sh | \
    SYGEN_SUBDOMAIN=alice \
    CF_API_TOKEN=cfat_xxx \
    CF_ZONE_ID=6ae59801f8ac7b5dc33b6e32d844b0a6 \
    sudo bash
```

On macOS the script stops Colima but does not delete the VM — Colima may
be shared with other Docker projects. Run `colima delete` manually if
nothing else is using it. The Let's Encrypt cert in `/etc/letsencrypt/`
is left in place; remove it with `certbot delete --cert-name <fqdn>` if
you don't plan to re-install.

## Image sources

- Core:  `ghcr.io/alexeymorozua/sygen-core:latest`
  ([`alexeymorozua/sygen`](https://github.com/alexeymorozua/sygen))
- Admin: `ghcr.io/alexeymorozua/sygen-admin:latest`
  ([`alexeymorozua/sygen-admin`](https://github.com/alexeymorozua/sygen-admin))
