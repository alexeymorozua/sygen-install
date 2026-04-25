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
#   SYGEN_JSON_OUTPUT=1       emit a single JSON line on stdout instead of the
#                             human banner (progress logs still go to stderr).
#                             Equivalent to passing `--json-output` as a flag.
#                             Useful for SSH-driven deploy wizards.
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

# ---------- Output mode (human banner vs. machine-parseable JSON) ----------
# --json-output (or SYGEN_JSON_OUTPUT=1) makes the installer emit a single
# JSON line on stdout at the end (success or failure) and route progress
# logs to stderr so SSH-driven deploy wizards can parse the result without
# scraping a human banner that may change formatting.
JSON_OUTPUT="${SYGEN_JSON_OUTPUT:-0}"
for arg in "$@"; do
    case "$arg" in
        --json-output) JSON_OUTPUT=1 ;;
    esac
done
JSON_DONE=0
STAGE="init"

log()  {
    if [ "$JSON_OUTPUT" = "1" ]; then
        printf '\033[0;36m==>\033[0m %s\n' "$*" >&2
    else
        printf '\033[0;36m==>\033[0m %s\n' "$*"
    fi
}
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }
die()  {
    printf '\033[0;31mXX\033[0m %s\n' "$*" >&2
    if [ "$JSON_OUTPUT" = "1" ] && [ "$JSON_DONE" = "0" ]; then
        emit_json_error "$*"
    fi
    exit 1
}

# Minimal JSON string escape: backslash, double-quote, and the common
# control chars. Sufficient for the values we emit (paths, image refs,
# fqdns, the alphanumeric admin password). No NUL handling — shell vars
# can't carry NUL anyway.
json_escape() {
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

emit_json_error() {
    if [ "$JSON_OUTPUT" != "1" ] || [ "$JSON_DONE" = "1" ]; then return 0; fi
    JSON_DONE=1
    local err="${1:-install failed}"
    local details="${2:-}"
    printf '{"ok":false,"error":%s,"stage":%s,"details":%s}\n' \
        "$(json_escape "$err")" \
        "$(json_escape "$STAGE")" \
        "$(json_escape "$details")"
}

# Catch unexpected non-zero exits (set -e failures from commands that
# don't go through die()) so JSON consumers always get one final line.
on_exit() {
    local code=$?
    if [ "$JSON_OUTPUT" = "1" ] && [ "$JSON_DONE" = "0" ] && [ "$code" -ne 0 ]; then
        emit_json_error "install script exited with code $code" "stage=$STAGE"
    fi
}
trap on_exit EXIT

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

# AUTO_MODE=1 means "ask install.sygen.pro for a free <id>.sygen.pro and a
# scoped DNS-01 token". AUTO_MODE=0 means the operator supplied their own
# subdomain + Cloudflare token (legacy / admin-managed installs).
# AUTO_MODE_REUSE=1 means we're re-running install.sh on a host that already
# went through provision once; we must NOT call /api/provision again (would
# orphan the live record + waste a slot) — we re-read the saved token + fqdn
# from the existing .env / config.json instead.
AUTO_MODE=0
AUTO_MODE_REUSE=0
SYGEN_INSTALL_TOKEN=""
SYGEN_INSTALL_HEARTBEAT_URL=""
CF_RECORD_ID=""
PROVISION_URL="${SYGEN_PROVISION_URL:-https://install.${DOMAIN}/api/provision}"

if [ $LOCAL_MODE -eq 1 ]; then
    SUB="${SYGEN_SUBDOMAIN:-local}"
    FQDN="localhost"
    SYGEN_ROOT="$HOME/.sygen-local"
    SYGEN_ADMIN_PORT="${SYGEN_ADMIN_PORT:-8080}"
    ADMIN_URL="http://localhost:${SYGEN_ADMIN_PORT}"
    CORS_ORIGIN="http://localhost:${SYGEN_ADMIN_PORT}"
    log "macOS detected — local install mode (Colima + localhost, no TLS)"
elif [ -z "${SYGEN_SUBDOMAIN:-}" ] && [ -z "${CF_API_TOKEN:-}" ]; then
    # Auto-mode — provision a free <id>.sygen.pro from install.sygen.pro.
    # FQDN/SUB/CF_API_TOKEN/CF_ZONE_ID/CF_RECORD_ID are filled in by the
    # provision step below, after deps (jq) are installed.
    AUTO_MODE=1
    SYGEN_ROOT="/srv/sygen"
    log "Linux detected — auto-mode (will provision <id>.${DOMAIN} from $PROVISION_URL)"
    if [ "$EUID" -ne 0 ]; then
        die "Run as root on Linux (sudo bash or ssh root@...)"
    fi
else
    SUB="${SYGEN_SUBDOMAIN:?SYGEN_SUBDOMAIN required (or unset both SYGEN_SUBDOMAIN and CF_API_TOKEN for auto-mode)}"
    FQDN="${SUB}.${DOMAIN}"
    CF_API_TOKEN="${CF_API_TOKEN:?CF_API_TOKEN required for custom-mode install}"
    CF_ZONE_ID="${CF_ZONE_ID:?CF_ZONE_ID required for custom-mode install}"
    SYGEN_ROOT="/srv/sygen"
    ADMIN_URL="https://$FQDN"
    CORS_ORIGIN="https://$FQDN"
    log "Linux detected — custom mode (subdomain $FQDN supplied by operator)"
    if [ "$EUID" -ne 0 ]; then
        die "Run as root on Linux (sudo bash or ssh root@...)"
    fi
fi

if [ $LOCAL_MODE -eq 0 ] && [ "$AUTO_MODE" -eq 0 ]; then
    . /etc/os-release 2>/dev/null || true
    log "Host: ${PRETTY_NAME:-unknown} — deploying $FQDN"
elif [ $LOCAL_MODE -eq 0 ]; then
    . /etc/os-release 2>/dev/null || true
    log "Host: ${PRETTY_NAME:-unknown} — fqdn will be assigned by provisioning service"
else
    log "Host: macOS $(sw_vers -productVersion 2>/dev/null || echo unknown) — deploying $ADMIN_URL"
fi

# ---------- 1. System packages ----------
STAGE="deps"
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

# ---------- 1c. Auto-provision subdomain (Linux + auto-mode only) ----------
# Runs after deps install so jq + curl are guaranteed. The Worker has already
# created an A record pointing at our CF-Connecting-IP — we still re-detect
# the public IP below and PUT to the known cf_record_id, in case the source
# IP visible to Cloudflare differs from what the host advertises.
if [ $LOCAL_MODE -eq 0 ] && [ "$AUTO_MODE" -eq 1 ]; then
    STAGE="provision"

    # Re-run detection: a previous successful auto-mode install left
    # SYGEN_INSTALL_TOKEN in /srv/sygen/.env. Calling /api/provision again
    # would burn a fresh slot AND drop the existing live DNS/TLS into limbo,
    # so we reuse what's already on disk instead.
    if [ -f "$SYGEN_ROOT/.env" ] && grep -q '^SYGEN_INSTALL_TOKEN=' "$SYGEN_ROOT/.env"; then
        AUTO_MODE_REUSE=1
        log "Auto-mode re-run: SYGEN_INSTALL_TOKEN already in $SYGEN_ROOT/.env — skipping provision"
        SYGEN_INSTALL_TOKEN=$(grep '^SYGEN_INSTALL_TOKEN=' "$SYGEN_ROOT/.env" | head -n1 | cut -d= -f2-)
        SYGEN_INSTALL_HEARTBEAT_URL=$(grep '^SYGEN_INSTALL_HEARTBEAT_URL=' "$SYGEN_ROOT/.env" 2>/dev/null | head -n1 | cut -d= -f2- || true)
        if [ -f "$SYGEN_ROOT/data/config/config.json" ]; then
            SUB=$(jq -r '.instance_name // empty' "$SYGEN_ROOT/data/config/config.json" 2>/dev/null || true)
        fi
        [ -n "${SUB:-}" ] || die "auto-mode re-run: cannot recover subdomain — config.json missing or has no instance_name. Wipe $SYGEN_ROOT and rerun for a fresh provision."
        FQDN="${SUB}.${DOMAIN}"
        ADMIN_URL="https://$FQDN"
        CORS_ORIGIN="https://$FQDN"
        # Sentinel values — never used because the DNS section is gated on
        # AUTO_MODE_REUSE below. Kept defined so `set -u` doesn't trip if
        # downstream code reads them defensively.
        CF_API_TOKEN="reused"
        CF_ZONE_ID="reused"
        CF_RECORD_ID="reused"
        log "Auto-mode re-run: continuing with existing $FQDN"
    else
        log "Auto-mode: requesting subdomain from $PROVISION_URL"
        PROVISION_RESPONSE=$(curl -fsS -X POST -H "Content-Type: application/json" \
            -d '{}' "$PROVISION_URL") \
            || die "provision request failed (network or 5xx) — set SYGEN_SUBDOMAIN/CF_API_TOKEN/CF_ZONE_ID to use a custom subdomain"

        FQDN=$(printf '%s' "$PROVISION_RESPONSE" | jq -r '.fqdn // empty')
        SYGEN_INSTALL_TOKEN=$(printf '%s' "$PROVISION_RESPONSE" | jq -r '.install_token // empty')
        CF_API_TOKEN=$(printf '%s' "$PROVISION_RESPONSE" | jq -r '.tls_dns_token // empty')
        CF_ZONE_ID=$(printf '%s' "$PROVISION_RESPONSE" | jq -r '.cf_zone_id // empty')
        CF_RECORD_ID=$(printf '%s' "$PROVISION_RESPONSE" | jq -r '.cf_record_id // empty')
        SYGEN_INSTALL_HEARTBEAT_URL=$(printf '%s' "$PROVISION_RESPONSE" | jq -r '.heartbeat_url // empty')

        if [ -z "$FQDN" ] || [ -z "$SYGEN_INSTALL_TOKEN" ] || [ -z "$CF_API_TOKEN" ] \
            || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_RECORD_ID" ]; then
            die "provision response missing required fields (got: $PROVISION_RESPONSE)"
        fi

        SUB="${FQDN%%.*}"
        ADMIN_URL="https://$FQDN"
        CORS_ORIGIN="https://$FQDN"
        log "Auto-mode: assigned $FQDN (install_token will be saved for weekly heartbeats)"
    fi
fi

# ---------- 2. Public IP + Cloudflare DNS (Linux only) ----------
# Skipped on auto-mode re-runs: the original install already created the
# record and the scoped tls_dns_token has long since expired (1h TTL).
if [ $LOCAL_MODE -eq 0 ] && [ "$AUTO_MODE_REUSE" -eq 1 ]; then
    log "Auto-mode re-run: skipping DNS upsert — record was set by original install"
fi
if [ $LOCAL_MODE -eq 0 ] && [ "$AUTO_MODE_REUSE" -eq 0 ]; then
    STAGE="dns"
    log "Detecting public IP"
    PUBLIC_IP=$(curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me)
    [ -n "$PUBLIC_IP" ] || die "Could not determine public IP"
    log "  public_ip=$PUBLIC_IP"

    CF_AUTH="Authorization: Bearer $CF_API_TOKEN"
    DNS_PAYLOAD=$(jq -nc --arg n "$FQDN" --arg c "$PUBLIC_IP" \
        '{type:"A",name:$n,content:$c,ttl:120,proxied:false}')

    if [ "$AUTO_MODE" -eq 1 ]; then
        # Scoped tls_dns_token has DNS:Edit on $CF_RECORD_ID only — it cannot
        # list zone records. Always PUT to the known id; harmless if Worker's
        # detected IP already matches our public IP.
        log "Updating Cloudflare A record $FQDN -> $PUBLIC_IP (record $CF_RECORD_ID)"
        curl -fsS -X PUT \
            "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
            -H "$CF_AUTH" -H "Content-Type: application/json" --data "$DNS_PAYLOAD" \
            >/dev/null || die "Cloudflare DNS PUT failed for record $CF_RECORD_ID"
    else
        log "Upserting Cloudflare A record $FQDN -> $PUBLIC_IP"
        EXISTING=$(curl -fsS "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$FQDN&type=A" \
            -H "$CF_AUTH" | jq -r '.result[0].id // empty')
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
    STAGE="cert"
    if [ "$AUTO_MODE_REUSE" -eq 1 ]; then
        log "Auto-mode re-run: cert already present, skipping certbot"
    elif [ -f "/etc/letsencrypt/live/$FQDN/fullchain.pem" ]; then
        log "  cert already present, skipping"
    else
        log "Obtaining Let's Encrypt cert via Cloudflare DNS-01"
        mkdir -p /etc/letsencrypt/sygen
        umask 077
        cat > /etc/letsencrypt/sygen/cloudflare.ini <<CF_INI
dns_cloudflare_api_token = $CF_API_TOKEN
CF_INI
        umask 022
        certbot certonly --non-interactive --agree-tos \
            --email "admin@$DOMAIN" \
            --dns-cloudflare \
            --dns-cloudflare-credentials /etc/letsencrypt/sygen/cloudflare.ini \
            --dns-cloudflare-propagation-seconds 20 \
            -d "$FQDN" || die "certbot failed"
    fi
fi

# ---------- 4. Data dirs + bootstrap config ----------
STAGE="data"
log "Preparing $SYGEN_ROOT"
mkdir -p "$SYGEN_ROOT"/{data,claude-auth}
mkdir -p "$SYGEN_ROOT/data/config"
mkdir -p "$SYGEN_ROOT/data/_secrets"
# Secrets dir holds .initial_admin_password + future per-install secrets.
# 0700 so only root/sygen-uid can read; 0755 default leaks directory listing
# to any local user on the VPS even though file contents need their own read perm.
chmod 0700 "$SYGEN_ROOT/data/_secrets"

# Container runs as uid 1000 (sygen) — see core Dockerfile. Bind-mounted
# host directories don't inherit the chown done inside the image, so without
# this the container can't create /data/logs etc and crashes on first start
# with PermissionError. Linux only — macOS Colima maps host user uid into
# the VM transparently.
if [ $LOCAL_MODE -eq 0 ]; then
    chown -R 1000:1000 "$SYGEN_ROOT/data" "$SYGEN_ROOT/claude-auth"
fi

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
# Phase 3: subdomain provisioning. Preserve token + heartbeat URL across
# re-runs of install.sh — losing them would orphan the reservation and the
# slot would get reclaimed after the 30-day TTL.
EFFECTIVE_INSTALL_TOKEN=$(get_env SYGEN_INSTALL_TOKEN "${SYGEN_INSTALL_TOKEN:-}")
EFFECTIVE_HEARTBEAT_URL=$(get_env SYGEN_INSTALL_HEARTBEAT_URL "${SYGEN_INSTALL_HEARTBEAT_URL:-}")
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
    # Phase 3: only present on auto-provisioned installs. Core reads these
    # at boot and runs a weekly POST to heartbeat_url to keep the slot alive.
    if [ -n "$EFFECTIVE_INSTALL_TOKEN" ]; then
        echo "SYGEN_INSTALL_TOKEN=$EFFECTIVE_INSTALL_TOKEN"
    fi
    if [ -n "$EFFECTIVE_HEARTBEAT_URL" ]; then
        echo "SYGEN_INSTALL_HEARTBEAT_URL=$EFFECTIVE_HEARTBEAT_URL"
    fi
} > "$SYGEN_ROOT/.env"
umask 022
chmod 600 "$SYGEN_ROOT/.env"

# ---------- 5. docker-compose.yml ----------
STAGE="compose"
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
    STAGE="smoke"
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
    STAGE="nginx"
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
STAGE="bootstrap"
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
# 0700 on the backup dir: defence-in-depth against regressions where an archive
# later ends up 0644 — the dir itself should never be world-listable since it
# names tarballs that contain .env + claude-auth + _secrets/.
chmod 0700 "$DEST"
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
STAGE="done"

if [ "$JSON_OUTPUT" = "1" ]; then
    if [ -z "$ADMIN_PASS" ]; then
        emit_json_error \
            "core did not write initial admin password within 2 min" \
            "see: docker compose -f $SYGEN_ROOT/docker-compose.yml logs core"
        exit 1
    fi
    JSON_DONE=1
    # install_token is only populated in auto-mode; it's emitted as a JSON
    # null otherwise so the field is always present and parseable. Wizards
    # that need it for follow-up (e.g. iOS storing it alongside provider
    # creds) can rely on the field's presence; otherwise it's harmless.
    if [ -n "$SYGEN_INSTALL_TOKEN" ]; then
        IT_JSON="$(json_escape "$SYGEN_INSTALL_TOKEN")"
    else
        IT_JSON="null"
    fi
    printf '{"ok":true,"fqdn":%s,"admin_user":"admin","admin_password":%s,"admin_url":%s,"core_image":%s,"admin_image":%s,"data_dir":%s,"compose_file":%s,"install_token":%s}\n' \
        "$(json_escape "$FQDN")" \
        "$(json_escape "$ADMIN_PASS")" \
        "$(json_escape "$ADMIN_URL")" \
        "$(json_escape "$CORE_IMAGE")" \
        "$(json_escape "$ADMIN_IMAGE")" \
        "$(json_escape "$SYGEN_ROOT/data")" \
        "$(json_escape "$SYGEN_ROOT/docker-compose.yml")" \
        "$IT_JSON"
    exit 0
fi

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
