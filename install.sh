#!/usr/bin/env bash
# Sygen install script v2 — Docker + nginx + Let's Encrypt (DNS-01 via Cloudflare).
#
# Single-node deploy for Debian 12+/Ubuntu 22+ hosts. Pulls the Sygen
# stack from GHCR instead of cloning source.
#
# Required env:
#   SYGEN_SUBDOMAIN   e.g. "alice" → alice.sygen.pro
#   CF_API_TOKEN      Cloudflare token with DNS:Edit on the zone
#   CF_ZONE_ID        Cloudflare zone id for SYGEN_DOMAIN
#
# Optional env:
#   SYGEN_DOMAIN              default: sygen.pro
#   ANTHROPIC_API_KEY         injected into core container as env var
# The admin panel bootstraps its own "admin" user on first boot and writes
# the one-time password to /srv/sygen/data/_secrets/.initial_admin_password.
# The installer prints it at the end.
#   SYGEN_INSTALL_BASE_URL    default: https://install.sygen.pro
#                             (source of docker-compose.yml + nginx.conf.tmpl)
#   SYGEN_CORE_IMAGE          pin a specific core image tag
#   SYGEN_ADMIN_IMAGE         pin a specific admin image tag
#   SYGEN_CORE_TAG            default: latest (used when *_IMAGE unset)
#   SYGEN_ADMIN_TAG           default: latest
#
# Usage:
#   curl -fsSL https://install.sygen.pro/install.sh | \
#     SYGEN_SUBDOMAIN=alice \
#     CF_API_TOKEN=cfat_xxx \
#     CF_ZONE_ID=6ae59801f8ac7b5dc33b6e32d844b0a6 \
#     bash
set -euo pipefail

# ---------- Required env ----------
SUB="${SYGEN_SUBDOMAIN:?SYGEN_SUBDOMAIN required}"
DOMAIN="${SYGEN_DOMAIN:-sygen.pro}"
FQDN="${SUB}.${DOMAIN}"
CF_API_TOKEN="${CF_API_TOKEN:?CF_API_TOKEN required}"
CF_ZONE_ID="${CF_ZONE_ID:?CF_ZONE_ID required}"

BASE_URL="${SYGEN_INSTALL_BASE_URL:-https://install.sygen.pro}"
CORE_TAG="${SYGEN_CORE_TAG:-latest}"
ADMIN_TAG="${SYGEN_ADMIN_TAG:-latest}"
CORE_IMAGE="${SYGEN_CORE_IMAGE:-ghcr.io/alexeymorozua/sygen-core:${CORE_TAG}}"
ADMIN_IMAGE="${SYGEN_ADMIN_IMAGE:-ghcr.io/alexeymorozua/sygen-admin:${ADMIN_TAG}}"

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then
    die "Run as root (sudo bash or ssh root@...)"
fi

. /etc/os-release 2>/dev/null || true
log "Host: ${PRETTY_NAME:-unknown} — deploying $FQDN"

# ---------- 1. System packages ----------
log "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    ca-certificates curl jq gnupg nginx \
    certbot python3-certbot-dns-cloudflare

# Docker (official convenience script, idempotent).
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker via get.docker.com"
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# docker compose v2 plugin is bundled with docker-ce on Debian/Ubuntu; verify.
if ! docker compose version >/dev/null 2>&1; then
    die "docker compose plugin missing — install manually and re-run"
fi

# ---------- 2. Public IP + Cloudflare DNS ----------
log "Detecting public IP"
PUBLIC_IP=$(curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me)
[ -n "$PUBLIC_IP" ] || die "Could not determine public IP"
log "  public_ip=$PUBLIC_IP"

log "Upserting Cloudflare A record $FQDN -> $PUBLIC_IP"
CF_AUTH="Authorization: Bearer $CF_API_TOKEN"
EXISTING=$(curl -fsS "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$FQDN&type=A" \
    -H "$CF_AUTH" | jq -r '.result[0].id // empty')
DNS_PAYLOAD=$(jq -nc --arg n "$FQDN" --arg c "$PUBLIC_IP" \
    '{type:"A",name:$n,content:$c,ttl:120,proxied:false}')
if [ -n "$EXISTING" ]; then
    curl -fsS -X PUT \
        "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$EXISTING" \
        -H "$CF_AUTH" -H "Content-Type: application/json" --data "$DNS_PAYLOAD" \
        >/dev/null
    log "  updated existing record"
else
    curl -fsS -X POST \
        "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
        -H "$CF_AUTH" -H "Content-Type: application/json" --data "$DNS_PAYLOAD" \
        >/dev/null
    log "  created new record"
fi

log "Waiting for DNS propagation..."
for i in $(seq 1 30); do
    got=$(dig +short A "$FQDN" @1.1.1.1 2>/dev/null || true)
    if [ "$got" = "$PUBLIC_IP" ]; then
        log "  DNS resolved: $got"
        break
    fi
    sleep 4
done

# ---------- 3. TLS cert ----------
log "Obtaining Let's Encrypt cert via Cloudflare DNS-01"
mkdir -p /etc/letsencrypt/sygen
umask 077
cat > /etc/letsencrypt/sygen/cloudflare.ini <<CF_INI
dns_cloudflare_api_token = $CF_API_TOKEN
CF_INI
umask 022

if [ ! -f "/etc/letsencrypt/live/$FQDN/fullchain.pem" ]; then
    certbot certonly --non-interactive --agree-tos \
        --email "admin@$DOMAIN" \
        --dns-cloudflare \
        --dns-cloudflare-credentials /etc/letsencrypt/sygen/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 20 \
        -d "$FQDN" || die "certbot failed"
else
    log "  cert already present, skipping"
fi

# ---------- 4. Data dirs + bootstrap config ----------
log "Preparing /srv/sygen"
mkdir -p /srv/sygen/{data,claude-auth}
mkdir -p /srv/sygen/data/config
mkdir -p /srv/sygen/data/_secrets

if [ ! -f /srv/sygen/data/config/config.json ]; then
    log "Bootstrapping config.json (api on, host 0.0.0.0, port 8081)"
    # `openssl rand -hex 32` outputs 64 hex chars on one line — no SIGPIPE
    # issues the way `tr -dc ... </dev/urandom | head -c N` has under pipefail.
    API_TOKEN=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 32)
    cat > /srv/sygen/data/config/config.json <<JSON
{
  "instance_name": "$SUB",
  "language": "en",
  "log_level": "INFO",
  "transport": "api",
  "transports": ["api"],
  "allowed_user_ids": [],
  "api": {
    "enabled": true,
    "host": "0.0.0.0",
    "port": 8081,
    "token": "$API_TOKEN",
    "jwt_secret": "$JWT_SECRET",
    "chat_id": 0,
    "allow_public": true,
    "cors_origins": ["https://$FQDN"]
  }
}
JSON
fi

# docker-compose .env is auto-sourced by `docker compose`.
umask 077
cat > /srv/sygen/.env <<ENV
SYGEN_CORE_IMAGE=$CORE_IMAGE
SYGEN_ADMIN_IMAGE=$ADMIN_IMAGE
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
LOG_LEVEL=INFO
ENV
umask 022
chmod 600 /srv/sygen/.env

# ---------- 5. docker-compose.yml ----------
log "Fetching docker-compose.yml from $BASE_URL"
curl -fsSL -o /srv/sygen/docker-compose.yml "$BASE_URL/docker-compose.yml" \
    || die "could not fetch docker-compose.yml"

# Amend compose to include admin env (SYGEN_ADMIN_USERNAME/PASSWORD) that
# core needs at startup. We do this via docker-compose's built-in .env
# loading — `/srv/sygen/.env` is auto-sourced by `docker compose`.

# ---------- 6. Start stack ----------
log "Pulling images"
docker compose -f /srv/sygen/docker-compose.yml --env-file /srv/sygen/.env pull

log "Starting Sygen stack"
docker compose -f /srv/sygen/docker-compose.yml --env-file /srv/sygen/.env up -d

# ---------- 7. nginx vhost ----------
log "Configuring nginx vhost for $FQDN"
curl -fsSL -o /tmp/sygen.nginx.tmpl "$BASE_URL/nginx.conf.tmpl" \
    || die "could not fetch nginx.conf.tmpl"
sed "s/__FQDN__/$FQDN/g" /tmp/sygen.nginx.tmpl > "/etc/nginx/sites-available/sygen"
ln -sf "/etc/nginx/sites-available/sygen" /etc/nginx/sites-enabled/sygen
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ---------- 8. Wait for admin bootstrap ----------
log "Waiting for core to generate initial admin password..."
PW_FILE=/srv/sygen/data/_secrets/.initial_admin_password
ADMIN_PASS=""
for i in $(seq 1 60); do
    if [ -f "$PW_FILE" ]; then
        ADMIN_PASS=$(head -n1 "$PW_FILE")
        break
    fi
    sleep 2
done

# ---------- 9. Done ----------
cat <<DONE

=====================================================================
 Sygen is up at: https://$FQDN
---------------------------------------------------------------------
  Admin user: admin
DONE

if [ -n "$ADMIN_PASS" ]; then
    echo "  Admin pass: $ADMIN_PASS   (one-time, from $PW_FILE)"
    echo "              delete that file after first login"
else
    warn "  Admin pass: core did not write $PW_FILE within 2 min."
    warn "              Check \`docker compose logs core\` and retry:"
    warn "              cat $PW_FILE"
fi

cat <<DONE

  Core image:  $CORE_IMAGE
  Admin image: $ADMIN_IMAGE
  Data dir:    /srv/sygen/data
  Compose:     /srv/sygen/docker-compose.yml  (--env-file /srv/sygen/.env)

  Upgrade:     cd /srv/sygen && docker compose pull && docker compose up -d
  Logs:        docker compose -f /srv/sygen/docker-compose.yml logs -f core

Claude Code CLI auth
---------------------------------------------------------------------
  Option 1 — API key:   add ANTHROPIC_API_KEY to /srv/sygen/.env and
                        \`docker compose up -d\`.
  Option 2 — OAuth:     \`docker compose -f /srv/sygen/docker-compose.yml \\
                          exec core claude auth login\`
                        (creds persist in /srv/sygen/claude-auth).
=====================================================================
DONE
