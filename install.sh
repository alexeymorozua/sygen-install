#!/usr/bin/env bash
# Sygen install script — Docker + (Linux: nginx + Let's Encrypt / macOS: Colima + localhost).
#
# Linux  (Debian 12+/Ubuntu 22+ VPS): apt, systemd, public DNS via Cloudflare,
#        nginx vhost + cert via certbot DNS-01.
# macOS  (Darwin): Homebrew-installed Colima as a headless Docker runtime.
#        Binds to http://localhost:8080 — no DNS/TLS/nginx.
#
# Required env (Linux only):
#   SYGEN_SUBDOMAIN   e.g. "alice" → alice.sygen.pro
#   CF_API_TOKEN      Cloudflare token with DNS:Edit on the zone
#   CF_ZONE_ID        Cloudflare zone id for SYGEN_DOMAIN
#
# Optional env:
#   SYGEN_DOMAIN              default: sygen.pro
#   ANTHROPIC_API_KEY         injected into core container as env var
#   SYGEN_INSTALL_BASE_URL    default: https://install.sygen.pro
#                             (source of docker-compose.yml + nginx.conf.tmpl)
#   SYGEN_CORE_IMAGE          pin a specific core image tag
#   SYGEN_ADMIN_IMAGE         pin a specific admin image tag
#   SYGEN_CORE_TAG            default: latest (used when *_IMAGE unset)
#   SYGEN_ADMIN_TAG           default: latest
#   SYGEN_ADMIN_PORT          (macOS) host port for admin, default 8080
#
# The admin panel bootstraps its own "admin" user on first boot and writes the
# one-time password to $SYGEN_ROOT/data/_secrets/.initial_admin_password. The
# installer prints it at the end. $SYGEN_ROOT is /srv/sygen on Linux and
# $HOME/.sygen-local on macOS.
#
# Usage:
#   # Linux (VPS, run as root):
#   curl -fsSL https://install.sygen.pro/install.sh | \
#     SYGEN_SUBDOMAIN=alice \
#     CF_API_TOKEN=cfat_xxx \
#     CF_ZONE_ID=6ae59801f8ac7b5dc33b6e32d844b0a6 \
#     bash
#
#   # macOS (local dev, regular user):
#   curl -fsSL https://install.sygen.pro/install.sh | bash
set -euo pipefail

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- Platform detection ----------
OS="$(uname -s)"
LOCAL_MODE=0
case "$OS" in
    Darwin)
        LOCAL_MODE=1
        ;;
    Linux)
        ;;
    *)
        die "Unsupported OS: $OS. Supported: Linux (Debian/Ubuntu), macOS."
        ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64|aarch64|arm64) ;;
    *) die "Unsupported architecture: $ARCH. Supported: x86_64/amd64, aarch64/arm64." ;;
esac

# ---------- Env parsing (conditional) ----------
DOMAIN="${SYGEN_DOMAIN:-sygen.pro}"
# Default to raw.githubusercontent.com so re-running install.sh always
# fetches the current docker-compose.yml + nginx.conf.tmpl. The GitHub
# Pages CDN at install.sygen.pro caches for ~10 min, which causes
# operators to silently install yesterday's compose file. Override
# SYGEN_INSTALL_BASE_URL when testing a fork.
BASE_URL="${SYGEN_INSTALL_BASE_URL:-https://raw.githubusercontent.com/alexeymorozua/sygen-install/main}"
CORE_TAG="${SYGEN_CORE_TAG:-latest}"
ADMIN_TAG="${SYGEN_ADMIN_TAG:-latest}"
CORE_IMAGE="${SYGEN_CORE_IMAGE:-ghcr.io/alexeymorozua/sygen-core:${CORE_TAG}}"
ADMIN_IMAGE="${SYGEN_ADMIN_IMAGE:-ghcr.io/alexeymorozua/sygen-admin:${ADMIN_TAG}}"

if [ $LOCAL_MODE -eq 1 ]; then
    SUB="${SYGEN_SUBDOMAIN:-local}"
    FQDN="localhost"
    SYGEN_ROOT="$HOME/.sygen-local"
    SYGEN_ADMIN_PORT="${SYGEN_ADMIN_PORT:-8080}"
    ADMIN_URL="http://localhost:${SYGEN_ADMIN_PORT}"
    CORS_ORIGIN="http://localhost:${SYGEN_ADMIN_PORT}"
    log "macOS detected — local install mode (Colima + localhost, no TLS)"
else
    SUB="${SYGEN_SUBDOMAIN:?SYGEN_SUBDOMAIN required}"
    FQDN="${SUB}.${DOMAIN}"
    CF_API_TOKEN="${CF_API_TOKEN:?CF_API_TOKEN required}"
    CF_ZONE_ID="${CF_ZONE_ID:?CF_ZONE_ID required}"
    SYGEN_ROOT="/srv/sygen"
    ADMIN_URL="https://$FQDN"
    CORS_ORIGIN="https://$FQDN"
    log "Linux detected — VPS install mode (systemd + nginx + Let's Encrypt)"
    if [ "$EUID" -ne 0 ]; then
        die "Run as root on Linux (sudo bash or ssh root@...)"
    fi
fi

if [ $LOCAL_MODE -eq 0 ]; then
    . /etc/os-release 2>/dev/null || true
    log "Host: ${PRETTY_NAME:-unknown} — deploying $FQDN"
else
    log "Host: macOS $(sw_vers -productVersion 2>/dev/null || echo unknown) — deploying $ADMIN_URL"
fi

# ---------- 1. System packages ----------
if [ $LOCAL_MODE -eq 0 ]; then
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
else
    # ---------- 1-macos. Brew deps + Colima ----------
    log "macOS: checking Homebrew"
    if ! command -v brew >/dev/null 2>&1; then
        die "Homebrew required on macOS. Install from https://brew.sh then re-run."
    fi

    log "macOS: installing Colima + docker CLI (if missing)"
    for pkg in colima docker docker-compose; do
        if ! brew list "$pkg" >/dev/null 2>&1; then
            brew install "$pkg"
        fi
    done

    if ! colima status >/dev/null 2>&1; then
        log "macOS: starting Colima (4 CPU / 8 GB RAM / 50 GB disk)"
        colima start --cpu 4 --memory 8 --disk 50
    else
        log "macOS: Colima already running"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        die "docker compose plugin missing after brew install — check your Homebrew setup"
    fi
fi

# ---------- 1b. Unattended-upgrades (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
    log "Enabling unattended-upgrades"
    apt-get install -y -qq unattended-upgrades

    # Idempotently enable daily check + unattended install. We deliberately
    # don't touch /etc/apt/apt.conf.d/50unattended-upgrades — the distro
    # default ships security-only, which is what we want.
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT
    if systemctl list-unit-files unattended-upgrades.service >/dev/null 2>&1; then
        systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
    fi
fi

# ---------- 2. Public IP + Cloudflare DNS (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
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
fi

# ---------- 3. TLS cert (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
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
fi

# ---------- 4. Data dirs + bootstrap config ----------
log "Preparing $SYGEN_ROOT"
mkdir -p "$SYGEN_ROOT"/{data,claude-auth}
mkdir -p "$SYGEN_ROOT/data/config"
mkdir -p "$SYGEN_ROOT/data/_secrets"

if [ ! -f "$SYGEN_ROOT/data/config/config.json" ]; then
    log "Bootstrapping config.json (api on, host 0.0.0.0, port 8081)"
    # `openssl rand -hex 32` outputs 64 hex chars on one line — no SIGPIPE
    # issues the way `tr -dc ... </dev/urandom | head -c N` has under pipefail.
    API_TOKEN=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 32)
    cat > "$SYGEN_ROOT/data/config/config.json" <<JSON
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
    "cors_origins": ["$CORS_ORIGIN"]
  }
}
JSON
fi

# Preserve user-set values across re-runs of install.sh. Each call to
# get_env reads from the existing .env (if any) and falls back to the
# given default when missing. Avoids stomping on operator edits like
# ANTHROPIC_API_KEY, pinned image tags, or the updater bearer token.
get_env() {
    local key="$1"
    local default="${2:-}"
    if [ -f "$SYGEN_ROOT/.env" ]; then
        local existing
        existing=$(grep -E "^${key}=" "$SYGEN_ROOT/.env" 2>/dev/null \
            | head -n1 | cut -d= -f2- || true)
        if [ -n "$existing" ]; then
            printf '%s' "$existing"
            return
        fi
    fi
    printf '%s' "$default"
}

# Image refs: env var > existing .env > computed default. Lets an operator
# pin a tag in .env (or via SYGEN_*_IMAGE) and have it survive re-runs.
EFFECTIVE_CORE_IMAGE=$(get_env SYGEN_CORE_IMAGE "$CORE_IMAGE")
EFFECTIVE_ADMIN_IMAGE=$(get_env SYGEN_ADMIN_IMAGE "$ADMIN_IMAGE")
# Secrets: existing wins; otherwise generate or pull from process env.
EFFECTIVE_UPDATER_TOKEN=$(get_env SYGEN_UPDATER_TOKEN "$(openssl rand -hex 32)")
EFFECTIVE_ANTHROPIC_KEY=$(get_env ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY:-}")
EFFECTIVE_OAUTH_TOKEN=$(get_env CLAUDE_CODE_OAUTH_TOKEN "${CLAUDE_CODE_OAUTH_TOKEN:-}")
EFFECTIVE_LOG_LEVEL=$(get_env LOG_LEVEL "INFO")
# NEXT_PUBLIC_SYGEN_API_URL: macOS forces localhost; on Linux preserve.
if [ $LOCAL_MODE -eq 1 ]; then
    EFFECTIVE_PUBLIC_API_URL="http://localhost:8081"
else
    EFFECTIVE_PUBLIC_API_URL=$(get_env NEXT_PUBLIC_SYGEN_API_URL "")
fi

# docker-compose .env is auto-sourced by `docker compose`.
umask 077
{
    echo "SYGEN_CORE_IMAGE=$EFFECTIVE_CORE_IMAGE"
    echo "SYGEN_ADMIN_IMAGE=$EFFECTIVE_ADMIN_IMAGE"
    echo "ANTHROPIC_API_KEY=$EFFECTIVE_ANTHROPIC_KEY"
    echo "CLAUDE_CODE_OAUTH_TOKEN=$EFFECTIVE_OAUTH_TOKEN"
    echo "LOG_LEVEL=$EFFECTIVE_LOG_LEVEL"
    # Shared secret for core ↔ updater-sidecar apply calls. Core authenticates
    # its POST to http://sygen-updater:8082/apply with this bearer token.
    echo "SYGEN_UPDATER_TOKEN=$EFFECTIVE_UPDATER_TOKEN"
    if [ -n "$EFFECTIVE_PUBLIC_API_URL" ]; then
        echo "NEXT_PUBLIC_SYGEN_API_URL=$EFFECTIVE_PUBLIC_API_URL"
    fi
} > "$SYGEN_ROOT/.env"
umask 022
chmod 600 "$SYGEN_ROOT/.env"

# ---------- 5. docker-compose.yml ----------
log "Fetching docker-compose.yml from $BASE_URL"
curl -fsSL -o "$SYGEN_ROOT/docker-compose.yml" "$BASE_URL/docker-compose.yml" \
    || die "could not fetch docker-compose.yml"

if [ $LOCAL_MODE -eq 1 ]; then
    # Rewrite hardcoded /srv/sygen paths to $SYGEN_ROOT (user-writable, no sudo)
    # and remap the admin container's host port from 3000 to $SYGEN_ADMIN_PORT
    # so it doesn't collide with typical local dev servers.
    # `sed -i.bak` is the portable form that works on BSD (macOS) and GNU sed.
    sed -i.bak \
        -e "s|/srv/sygen|$SYGEN_ROOT|g" \
        -e "s|127.0.0.1:3000:3000|127.0.0.1:${SYGEN_ADMIN_PORT}:3000|g" \
        "$SYGEN_ROOT/docker-compose.yml"
    rm -f "$SYGEN_ROOT/docker-compose.yml.bak"
fi

# ---------- 6. Start stack ----------
log "Pulling images"
docker compose -f "$SYGEN_ROOT/docker-compose.yml" --env-file "$SYGEN_ROOT/.env" pull

log "Starting Sygen stack"
docker compose -f "$SYGEN_ROOT/docker-compose.yml" --env-file "$SYGEN_ROOT/.env" up -d

# ---------- 6b. macOS smoke-test (Linux uses nginx + Let's Encrypt to verify) ----------
if [ $LOCAL_MODE -eq 1 ]; then
    log "macOS: smoke-testing endpoints (admin :${SYGEN_ADMIN_PORT}, core :8081)"
    smoke_ok=0
    for i in $(seq 1 30); do
        admin_ok=0
        core_ok=0
        # Admin Next server returns 200 on /, but during boot it may 404
        # /_next assets — accept any non-5xx as "alive".
        admin_code=$(curl -fsS -o /dev/null -w '%{http_code}' \
            "http://localhost:${SYGEN_ADMIN_PORT}" 2>/dev/null || echo "000")
        case "$admin_code" in 200|301|302|404) admin_ok=1 ;; esac
        # Core /api/system/status is unauthenticated-discoverable: returns
        # 200 if you have a token, 401 otherwise. Both prove the server
        # is up and routing — only a connect failure is a smoke-test fail.
        core_code=$(curl -fsS -o /dev/null -w '%{http_code}' \
            "http://localhost:8081/api/system/status" 2>/dev/null || echo "000")
        case "$core_code" in 200|401|403) core_ok=1 ;; esac
        if [ "$admin_ok" -eq 1 ] && [ "$core_ok" -eq 1 ]; then
            log "  endpoints responding (admin=$admin_code core=$core_code)"
            smoke_ok=1
            break
        fi
        sleep 2
    done
    if [ "$smoke_ok" -ne 1 ]; then
        warn "Smoke test failed after 60s: admin=$admin_code core=$core_code."
        warn "Check: 'colima status' and 'docker compose -f $SYGEN_ROOT/docker-compose.yml logs'"
    fi
fi

# ---------- 7. nginx vhost (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
    log "Configuring nginx vhost for $FQDN"
    curl -fsSL -o /tmp/sygen.nginx.tmpl "$BASE_URL/nginx.conf.tmpl" \
        || die "could not fetch nginx.conf.tmpl"
    sed "s/__FQDN__/$FQDN/g" /tmp/sygen.nginx.tmpl > "/etc/nginx/sites-available/sygen"
    ln -sf "/etc/nginx/sites-available/sygen" /etc/nginx/sites-enabled/sygen
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl reload nginx
fi

# ---------- 8. Wait for admin bootstrap ----------
log "Waiting for core to generate initial admin password..."
PW_FILE="$SYGEN_ROOT/data/_secrets/.initial_admin_password"
ADMIN_PASS=""
for i in $(seq 1 60); do
    if [ -f "$PW_FILE" ]; then
        ADMIN_PASS=$(head -n1 "$PW_FILE")
        break
    fi
    sleep 2
done

# ---------- 9. Auto-updates & cert renewal (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
    # Container image auto-updates run inside the stack via the Watchtower
    # service defined in docker-compose.yml — it polls GHCR hourly and
    # recreates any container labeled com.centurylinklabs.watchtower.enable.
    #
    # certbot's Debian/Ubuntu package installs certbot.timer (runs twice
    # daily), so cert renewals happen on their own. We just need nginx to
    # reload and pick up the new chain after a successful renew.
    log "Installing cert-renewal nginx reload hook"
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
fi

# ---------- 10. Nightly backups (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
    log "Installing nightly backup timer (/var/backups/sygen, 7-day retention)"

    cat > /usr/local/sbin/sygen-backup.sh <<'BACKUP'
#!/usr/bin/env bash
# Sygen nightly backup — managed by install.sh (Phase 2.8).
# Snapshots /srv/sygen/{data,.env,docker-compose.yml,claude-auth} into
# /var/backups/sygen/sygen-YYYY-MM-DD.tar.gz and prunes archives >7d old.
set -euo pipefail

SRC=/srv/sygen
DEST=/var/backups/sygen

if [ ! -d "$SRC/data" ]; then
    echo "sygen-backup: $SRC/data missing — refusing to back up" >&2
    exit 1
fi

mkdir -p "$DEST"
STAMP=$(date -u +%Y-%m-%d)
OUT="$DEST/sygen-${STAMP}.tar.gz"

# .env / docker-compose.yml / claude-auth are optional on a partially
# bootstrapped host — don't fail the run if any are missing.
tar -czf "$OUT" -C "$SRC" data .env docker-compose.yml claude-auth 2>/dev/null || true

# Archive contains api token, jwt secret, and Claude OAuth creds.
chmod 600 "$OUT"

find "$DEST" -maxdepth 1 -name 'sygen-*.tar.gz' -type f -mtime +7 -delete
BACKUP
    chmod 0755 /usr/local/sbin/sygen-backup.sh

    cat > /etc/systemd/system/sygen-backup.service <<'UNIT'
[Unit]
Description=Sygen nightly backup

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sygen-backup.sh
UNIT

    cat > /etc/systemd/system/sygen-backup.timer <<'UNIT'
[Unit]
Description=Run sygen-backup daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable --now sygen-backup.timer
    # Take the first snapshot now so a fresh install ships with one backup.
    systemctl start --no-block sygen-backup.service
fi

# ---------- 11. Done ----------
cat <<DONE

=====================================================================
 Sygen is up at: $ADMIN_URL
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
  Data dir:    $SYGEN_ROOT/data
  Compose:     $SYGEN_ROOT/docker-compose.yml  (--env-file $SYGEN_ROOT/.env)
DONE

if [ $LOCAL_MODE -eq 0 ]; then
    cat <<DONE
  Backups:     /var/backups/sygen/sygen-*.tar.gz  (daily, 7-day retention)

  Upgrade:     cd $SYGEN_ROOT && docker compose pull && docker compose up -d
  Logs:        docker compose -f $SYGEN_ROOT/docker-compose.yml logs -f core
DONE
else
    cat <<DONE
  Backups:     not configured on macOS (manual tar of $SYGEN_ROOT)

  Stop:        colima stop
  Start:       colima start && cd $SYGEN_ROOT && docker compose up -d
  Upgrade:     cd $SYGEN_ROOT && docker compose pull && docker compose up -d
  Logs:        docker compose -f $SYGEN_ROOT/docker-compose.yml logs -f core
  Uninstall:   colima delete && rm -rf $SYGEN_ROOT
DONE
fi

cat <<DONE

Claude Code CLI auth
---------------------------------------------------------------------
  Option 1 — API key:   add ANTHROPIC_API_KEY to $SYGEN_ROOT/.env and
                        \`docker compose up -d\`.
  Option 2 — OAuth:     \`docker compose -f $SYGEN_ROOT/docker-compose.yml \\
                          exec core claude auth login\`
                        (creds persist in $SYGEN_ROOT/claude-auth).
=====================================================================
DONE
