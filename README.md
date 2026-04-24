# sygen-install

One-shot installer for a single-node Sygen deployment.

Supported: Linux (Debian 12+/Ubuntu 22+ VPS), macOS (local dev). Windows/WSL2
is planned but not yet supported.

Pulls the Sygen stack (core + admin web) from GHCR. On Linux it provisions
DNS + TLS via Cloudflare and wires up an nginx reverse proxy; on macOS it
runs everything inside Colima bound to `localhost` — no DNS/TLS/nginx.

## Usage — Linux (VPS)

```bash
curl -fsSL https://install.sygen.pro/install.sh | \
    SYGEN_SUBDOMAIN=alice \
    CF_API_TOKEN=cfat_xxx \
    CF_ZONE_ID=6ae59801f8ac7b5dc33b6e32d844b0a6 \
    bash
```

## Usage — macOS (local dev)

```bash
curl -fsSL https://install.sygen.pro/install.sh | bash
```

Requires [Homebrew](https://brew.sh). The installer will `brew install`
Colima + docker CLI, start a 4-CPU / 8 GB / 50 GB Colima VM, and run Sygen at
`http://localhost:8080`. No root, no DNS, no TLS.

```
Stop:       colima stop
Start:      colima start && cd ~/.sygen-local && docker compose up -d
Upgrade:    cd ~/.sygen-local && docker compose pull && docker compose up -d
Uninstall:  colima delete && rm -rf ~/.sygen-local
```

Backups and auto-start on login are not configured on macOS yet — back up
`~/.sygen-local` manually if needed.

See the header of [`install.sh`](./install.sh) for the full env var list.

## Files

- [`install.sh`](./install.sh) — installer entry point
- [`docker-compose.yml`](./docker-compose.yml) — the stack
- [`nginx.conf.tmpl`](./nginx.conf.tmpl) — nginx vhost template (`__FQDN__`
  is substituted by the installer)
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

## Image sources

- Core:  `ghcr.io/alexeymorozua/sygen-core:latest`
  ([`alexeymorozua/sygen`](https://github.com/alexeymorozua/sygen))
- Admin: `ghcr.io/alexeymorozua/sygen-admin:latest`
  ([`alexeymorozua/sygen-admin`](https://github.com/alexeymorozua/sygen-admin))
