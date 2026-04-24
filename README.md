# sygen-install

One-shot installer for a single-node Sygen deployment.

Pulls the Sygen stack (core + admin web) from GHCR, provisions DNS + TLS via
Cloudflare, and wires up an nginx reverse proxy.

## Usage

```bash
curl -fsSL https://install.sygen.pro/install.sh | \
    SYGEN_SUBDOMAIN=alice \
    CF_API_TOKEN=cfat_xxx \
    CF_ZONE_ID=6ae59801f8ac7b5dc33b6e32d844b0a6 \
    bash
```

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

- **Container images** — a `watchtower` service in `docker-compose.yml`
  polls GHCR hourly and recreates the `core` + `admin` containers when a
  newer `:latest` digest is published. Only containers carrying the
  `com.centurylinklabs.watchtower.enable=true` label are touched.
- **OS security patches** — `unattended-upgrades` is installed and
  enabled (`/etc/apt/apt.conf.d/20auto-upgrades`). The distro default
  `50unattended-upgrades` policy is security-only.
- **TLS certs** — `certbot.timer` (shipped by the `certbot` package)
  runs twice daily. A deploy hook at
  `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` reloads nginx
  after each successful renewal.

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
