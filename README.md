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

## Image sources

- Core:  `ghcr.io/alexeymorozua/sygen-core:latest`
  ([`alexeymorozua/sygen`](https://github.com/alexeymorozua/sygen))
- Admin: `ghcr.io/alexeymorozua/sygen-admin:latest`
  ([`alexeymorozua/sygen-admin`](https://github.com/alexeymorozua/sygen-admin))
