# sygen-install

One-shot installer for a single-node Sygen deployment.

**v1.7+ ships native processes — no Docker, no Colima.** Sygen runs as
a Python venv (core + updater) and a Next.js standalone Node process
(admin), managed by `launchctl` (macOS) or `systemd` (Linux). Sub-agents
get direct access to host tools (Xcode, swiftc, iOS simulators on a Mac
mini; native dev toolchains on Linux).

Supported: Linux (Debian 12+/Ubuntu 22+ VPS), macOS (local dev).
Windows/WSL2 is planned but not yet supported.

`install.sh` downloads the `sygen` Python wheel and `sygen-admin` Next.js
tarball directly from GitHub Releases, creates a venv, extracts the
admin tarball, writes service unit files, and starts everything. On
Linux it also provisions DNS + TLS via Cloudflare and wires up an nginx
reverse proxy.

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
run the same native services (`pro.sygen.{core,admin,updater}` LaunchAgents)
— the difference is only how the admin UI is exposed (and whether your
iPhone can reach it).

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
`python@3.14`, `node@22`, `jq`, and `whisper-cpp`, create a Python venv
at `~/.sygen-local/venv`, extract the admin tarball at
`~/.sygen-local/admin`, and run Sygen at `http://localhost:8080`. No
root, no DNS, no TLS — and **no iPhone connectivity** (App Transport
Security on iOS blocks plain HTTP).

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
TLS at port 443 and proxy `/`, `/api/`, `/ws/`, `/upload` to the
matching native service. The cert is issued and renewed by Tailscale;
nothing is exposed to the public internet.

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
  Sygen native services themselves do auto-start — see [Auto-start on
  reboot](#auto-start-on-reboot) below.)

For most self-hosted Mac users, **prefer `tailscale` mode** — it sidesteps
the port-forwarding, cert-renewal, and reboot-recovery work above.

### Lifecycle (all macOS sub-modes)

```
Status:     launchctl list | grep pro.sygen
Logs:       tail -F ~/.sygen-local/logs/{core,admin,updater}.log
Stop:       launchctl unload ~/Library/LaunchAgents/pro.sygen.{core,admin,updater}.plist
Start:      launchctl load -w ~/Library/LaunchAgents/pro.sygen.{core,admin,updater}.plist
Restart:    launchctl kickstart -k gui/$(id -u)/pro.sygen.core
Upgrade:    POST to the updater /apply endpoint via the admin UI
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
# {"ok":true,"mode":"auto","install_mode":"native","fqdn":"s3xk7f2p.sygen.pro","admin_user":"admin","admin_password":"...","admin_url":"https://s3xk7f2p.sygen.pro","core_version":"1.6.74","admin_version":"0.5.54","data_dir":"/srv/sygen/data","venv_dir":"/srv/sygen/venv","admin_dir":"/srv/sygen/admin","install_token":"sit_..."}
```

`install_token` is `null` in custom mode and a `sit_...` string in auto-mode;
deploy wizards (e.g. iOS) can persist it alongside provider creds for later
reference. Day-to-day heartbeat traffic is handled by core itself — wizards
do not need to call `/api/heartbeat` themselves.

On failure the script still emits a single JSON line and exits non-zero:

```json
{"ok":false,"error":"<reason>","stage":"deps|dns|cert|data|install|services|smoke|nginx|bootstrap","details":"<short>"}
```

The default (no flag, no env var) banner output is unchanged.

## Files

- [`install.sh`](./install.sh) — installer entry point
- [`uninstall.sh`](./uninstall.sh) — manifest-driven uninstaller
- [`scripts/pro.sygen.{core,admin,updater}.plist`](./scripts/) — macOS
  LaunchAgent templates
- [`scripts/sygen-{core,admin,updater}.service`](./scripts/) — Linux
  systemd unit templates
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

Trigger an upgrade via the admin UI's update banner — the `sygen-updater`
service downloads the new wheel + admin tarball from GitHub Releases,
performs an atomic mv-swap of the venv and admin dirs, and restarts
core + admin. Manual fallback:

```bash
# macOS
~/.sygen-local/venv/bin/pip install --upgrade sygen
launchctl kickstart -k gui/$(id -u)/pro.sygen.core

# Linux
/srv/sygen/venv/bin/pip install --upgrade sygen
systemctl restart sygen-core
```

## Auto-updates

A fresh install keeps itself current without manual intervention:

- **sygen-core + sygen-admin** — the `sygen-updater` service polls
  GitHub Releases every 30 minutes for new tags on `alexeymorozua/sygen`
  and `alexeymorozua/sygen-admin` and writes a state file that the admin
  UI reads via `/api/system/updates`. Updates are **detected**
  automatically; **applying** them is driven by an admin click so an
  in-flight Claude session is never killed mid-work.
- **OS security patches** — `unattended-upgrades` is installed and
  enabled (`/etc/apt/apt.conf.d/20auto-upgrades`). The distro default
  `50unattended-upgrades` policy is security-only.
- **TLS certs** — `certbot.timer` (shipped by the `certbot` package)
  runs twice daily. A deploy hook at
  `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` reloads nginx
  after each successful renewal.

### Updating the updater itself

The `sygen-updater` service can't safely tear itself down mid-request.
The apply path skips restarting the updater; a manual `pip install
--upgrade sygen-updater` (or a fresh `install.sh` run, which rebuilds
the venv from scratch) is the path to update the updater binary itself.

### When the pinned release is not yet published

The defaults in `install.sh` (`SYGEN_CORE_VERSION` /
`SYGEN_ADMIN_VERSION`) point at the version the next git tag will
produce. If you run `install.sh` *before* that tag is created, GitHub
returns 404 for the wheel/tarball download and the installer dies with
a clear message. Two ways to recover:

```bash
# 1) pin to the most recent published tag
SYGEN_CORE_VERSION=1.6.74 SYGEN_ADMIN_VERSION=0.5.54 \
    bash install.sh

# 2) build from a local checkout (transitional / dev)
SYGEN_RELEASE_SOURCE=source \
    SYGEN_CORE_SOURCE_DIR=$HOME/Agents/sygen \
    SYGEN_ADMIN_SOURCE_DIR=$HOME/sygen-admin \
    bash install.sh
```

Every wheel and tarball pulled from GitHub Releases is SHA256-verified
against an `.sha256` sidecar published alongside the asset. A missing
sidecar is treated as a broken release and the installer aborts (fail
closed — no opt-out).

Opting out:

```bash
# Stop sygen update polling
launchctl unload ~/Library/LaunchAgents/pro.sygen.updater.plist  # macOS
systemctl disable --now sygen-updater                             # Linux

# Stop OS security updates
systemctl disable --now unattended-upgrades

# Stop the nginx reload on cert renewal (certs still renew)
rm /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

## Auto-start on reboot

A fresh install brings Sygen back up automatically after every host
reboot, so power blips and scheduled reboots don't require any manual
recovery.

- **macOS** — three LaunchAgents in `~/Library/LaunchAgents/`:
  - `pro.sygen.core.plist` runs `~/.sygen-local/venv/bin/sygen`.
  - `pro.sygen.admin.plist` runs `node ~/.sygen-local/admin/server.js`.
  - `pro.sygen.updater.plist` runs `~/.sygen-local/venv/bin/sygen-updater`.
  All three have `RunAtLoad=true` and `KeepAlive=true`, so they restart
  on crash and start at user login. Logs land in
  `~/.sygen-local/logs/{core,admin,updater}.log`.
- **Linux** — three systemd units at `/etc/systemd/system/`:
  - `sygen-core.service`, `sygen-admin.service`, `sygen-updater.service`,
    all `WantedBy=multi-user.target`, all `Restart=always` (or
    `on-failure` for the updater).
  - `sygen-core` and `sygen-admin` run as a dedicated unprivileged
    `sygen` system user (no shell, no home), with
    `ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp=yes`,
    `NoNewPrivileges=yes`, and `ReadWritePaths=/srv/sygen`. Process-level
    RCE in either service is contained to `/srv/sygen` — it cannot escape
    to `/etc`, `/home`, or other system paths.
  - `sygen-updater` stays root because the apply path needs `systemctl
    restart` and `chown` across the venv/admin swap. It still has
    `NoNewPrivileges=yes` and only listens on loopback (`127.0.0.1:8082`,
    bearer-authed); binding on a non-loopback address requires the
    explicit `SYGEN_UPDATER_ALLOW_REMOTE=1` opt-in.
  - `uninstall.sh` removes the `sygen` user along with `/srv/sygen`.

Disabling:

```bash
# macOS
launchctl unload ~/Library/LaunchAgents/pro.sygen.core.plist
launchctl unload ~/Library/LaunchAgents/pro.sygen.admin.plist
launchctl unload ~/Library/LaunchAgents/pro.sygen.updater.plist

# Linux
systemctl disable --now sygen-core.service
systemctl disable --now sygen-admin.service
systemctl disable --now sygen-updater.service
```

`uninstall.sh` removes both surfaces automatically.

Out of scope: the macOS `publicdomain` sub-mode runs nginx outside the
compose stack — Sygen will be back up on reboot, but `nginx` won't be
serving 80/443 until you start it manually (or wire your own plist).

## Backups

A `sygen-backup.timer` systemd unit runs daily and writes a compressed
archive of `/srv/sygen/{data,.env,claude-auth}` to
`/var/backups/sygen/sygen-YYYY-MM-DD.tar.gz`. Archives older than 7 days
are pruned automatically. Each archive is `chmod 600` because it
contains the API token, JWT secret, and Claude OAuth credentials.

`venv/` and `admin/` are intentionally NOT backed up — they're
deterministically reproducible from `install.sh` given the version pins
in `.env`.

The first snapshot is taken at the end of the install run, so a fresh
host has a usable backup right away.

### Restore on a new host

After running `install.sh` on the replacement VPS (so DNS, certs, the
venv, and the admin tarball are wired up), drop a backup tarball over
the data dir:

```bash
systemctl stop sygen-core sygen-admin
tar -xzf /var/backups/sygen/sygen-YYYY-MM-DD.tar.gz -C /srv/sygen/
systemctl start sygen-core sygen-admin
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

The script auto-routes between native (v1.7+) and legacy Docker
manifests via `install_mode` in `.install_manifest.json`. On Linux, the
Let's Encrypt cert in `/etc/letsencrypt/` is left in place; remove it
with `certbot delete --cert-name <fqdn>` if you don't plan to re-install.

## Release sources

- Core:  Python wheels at
  [`alexeymorozua/sygen` releases](https://github.com/alexeymorozua/sygen/releases)
  (filename `sygen-<version>-py3-none-any.whl`)
- Admin: Next.js standalone tarballs at
  [`alexeymorozua/sygen-admin` releases](https://github.com/alexeymorozua/sygen-admin/releases)
  (filename `sygen-admin-<version>.tar.gz`)
- Updater: published alongside core wheels
  (filename `sygen_updater-<version>-py3-none-any.whl`)
