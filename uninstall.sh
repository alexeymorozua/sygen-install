#!/usr/bin/env bash
# Sygen uninstall script — clean removal of Sygen from a host.
#
# Linux  (Debian/Ubuntu VPS): stops containers, removes systemd backup
#        timer, nginx vhost, cert renewal hook, and /srv/sygen.
# macOS  (Darwin): stops containers, stops Colima (does not delete the VM
#        — it may be shared with other projects), removes ~/.sygen-local.
#
# Kept (for fast re-install):
#   - Let's Encrypt cert in /etc/letsencrypt/ (Linux)
#   - System packages (docker, nginx, certbot, colima, etc.)
#
# Optional Cloudflare DNS cleanup:
#   Set CF_API_TOKEN + CF_ZONE_ID + SYGEN_SUBDOMAIN (and optionally
#   SYGEN_DOMAIN, default sygen.pro) to also delete the A record.
#   Without these, the DNS record stays and must be removed manually.
#
# Usage:
#   # Interactive (prompts for confirmation):
#   curl -fsSL https://install.sygen.pro/uninstall.sh | sudo bash      # Linux
#   curl -fsSL https://install.sygen.pro/uninstall.sh | bash           # macOS
#
#   # Non-interactive (CI / automation):
#   curl -fsSL https://install.sygen.pro/uninstall.sh | \
#       SYGEN_UNINSTALL_CONFIRM=1 sudo bash
set -euo pipefail

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- Platform detection ----------
OS="$(uname -s)"
LOCAL_MODE=0
case "$OS" in
    Darwin) LOCAL_MODE=1 ;;
    Linux)  ;;
    *) die "Unsupported OS: $OS. Supported: Linux (Debian/Ubuntu), macOS." ;;
esac

if [ $LOCAL_MODE -eq 1 ]; then
    SYGEN_ROOT="$HOME/.sygen-local"
else
    SYGEN_ROOT="/srv/sygen"
    if [ "$EUID" -ne 0 ]; then
        die "Run as root on Linux (sudo bash or ssh root@...)"
    fi
fi

# Hard guard: only ever remove one of the two known SYGEN_ROOT paths.
# Defends against an upstream change that lets SYGEN_ROOT become empty
# or "/" — a stray rm -rf on the wrong value would wipe the host.
case "$SYGEN_ROOT" in
    /srv/sygen|"$HOME/.sygen-local") ;;
    *) die "Refusing to remove unexpected SYGEN_ROOT='$SYGEN_ROOT' (safety check)" ;;
esac

# ---------- Confirmation gate ----------
log "This will REMOVE Sygen from this host:"
log "  - Stop and remove all Sygen containers"
if [ $LOCAL_MODE -eq 1 ]; then
    log "  - Delete $SYGEN_ROOT including data, .env, secrets, claude-auth"
    log "  - Stop Colima (will NOT delete the VM — it may be shared)"
else
    log "  - Delete $SYGEN_ROOT including data, .env, secrets, claude-auth"
    log "  - Delete /var/backups/sygen"
    log "  - Remove systemd units: sygen-backup.timer/.service"
    log "  - Remove cert renewal hook (/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh)"
    log "  - Remove nginx vhost (sygen)"
fi
log "  - Release the install.sygen.pro subdomain slot (if .env has SYGEN_INSTALL_TOKEN)"
log "  - Optionally release Cloudflare DNS A record (if CF_* env vars set)"
log ""
log "It will NOT touch:"
if [ $LOCAL_MODE -eq 0 ]; then
    log "  - The Let's Encrypt cert in /etc/letsencrypt/ (kept for re-install)"
fi
log "  - System packages (docker, nginx, certbot, colima, etc.)"
log "  - Other services on the host"
log ""

if [ "${SYGEN_UNINSTALL_CONFIRM:-}" = "1" ]; then
    log "SYGEN_UNINSTALL_CONFIRM=1 — proceeding without prompt"
else
    answer=""
    if [ -t 0 ]; then
        printf "Type 'YES' to continue: "
        read -r answer
    elif [ -e /dev/tty ]; then
        printf "Type 'YES' to continue: " > /dev/tty
        read -r answer < /dev/tty
    else
        die "Cannot read confirmation (no TTY). Re-run with SYGEN_UNINSTALL_CONFIRM=1 to skip the prompt."
    fi
    if [ "$answer" != "YES" ]; then
        die "Aborted (expected 'YES', got '${answer:-<empty>}')"
    fi
fi

# ---------- 0. Capture CF vars from .env BEFORE anything is deleted ----------
# install.sh doesn't currently persist CF_API_TOKEN/CF_ZONE_ID/SYGEN_SUBDOMAIN
# into .env, but we read it anyway for forward compatibility.
read_env_var() {
    local key="$1"
    if [ -f "$SYGEN_ROOT/.env" ]; then
        grep -E "^${key}=" "$SYGEN_ROOT/.env" 2>/dev/null \
            | head -n1 | cut -d= -f2- || true
    fi
}

CF_TOKEN_VAL="${CF_API_TOKEN:-}"
[ -z "$CF_TOKEN_VAL" ] && CF_TOKEN_VAL="$(read_env_var CF_API_TOKEN)"
CF_ZONE_VAL="${CF_ZONE_ID:-}"
[ -z "$CF_ZONE_VAL" ] && CF_ZONE_VAL="$(read_env_var CF_ZONE_ID)"
CF_SUB_VAL="${SYGEN_SUBDOMAIN:-}"
[ -z "$CF_SUB_VAL" ] && CF_SUB_VAL="$(read_env_var SYGEN_SUBDOMAIN)"
CF_DOMAIN_VAL="${SYGEN_DOMAIN:-}"
[ -z "$CF_DOMAIN_VAL" ] && CF_DOMAIN_VAL="$(read_env_var SYGEN_DOMAIN)"
[ -z "$CF_DOMAIN_VAL" ] && CF_DOMAIN_VAL="sygen.pro"

INSTALL_TOKEN_VAL="$(read_env_var SYGEN_INSTALL_TOKEN)"
# Strip surrounding double quotes if .env writer added them.
INSTALL_TOKEN_VAL="${INSTALL_TOKEN_VAL%\"}"
INSTALL_TOKEN_VAL="${INSTALL_TOKEN_VAL#\"}"

# ---------- 1. Release subdomain reservation ----------
# Tells the install.sygen.pro Worker to delete the DNS record + KV entries
# so the subdomain slot is freed for the next user. The endpoint is
# idempotent — unknown/expired tokens still return 200. Any failure here
# must NEVER block the rest of the uninstall: KV is also reaped by the
# nightly sweep, so the worst case is a delayed slot reclaim.
if [ -n "$INSTALL_TOKEN_VAL" ]; then
    log "Releasing subdomain reservation via install.sygen.pro/api/release"
    if ! command -v curl >/dev/null 2>&1; then
        warn "  curl not installed — slot will be reclaimed by sweep eventually"
    elif release_response="$(curl -fsS -X DELETE \
            -H 'Content-Type: application/json' \
            -d "{\"install_token\":\"$INSTALL_TOKEN_VAL\"}" \
            'https://install.sygen.pro/api/release' 2>&1)"; then
        log "  release response: $release_response"
    else
        warn "  release request failed (continuing): $release_response"
    fi
else
    log "No SYGEN_INSTALL_TOKEN in .env (custom domain or pre-Phase 3 install) — skipping subdomain release"
fi

# ---------- 2. Stop containers ----------
if [ -f "$SYGEN_ROOT/docker-compose.yml" ] && command -v docker >/dev/null 2>&1; then
    log "Stopping Sygen containers"
    # Compose auto-sources $SYGEN_ROOT/.env from the project dir, so no --env-file.
    # `down -v` also removes any named volumes (today there are only bind mounts,
    # but this is forward-safe).
    docker compose -f "$SYGEN_ROOT/docker-compose.yml" down -v --remove-orphans 2>/dev/null \
        || warn "  docker compose down failed — containers may already be gone"
else
    log "No docker-compose.yml at $SYGEN_ROOT — skipping container stop"
fi

# Belt-and-suspenders: kill any leftover Sygen containers by name in case the
# compose file went missing before this script ran.
if command -v docker >/dev/null 2>&1; then
    for name in sygen-core sygen-admin sygen-watchtower sygen-updater; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
            docker rm -f "$name" >/dev/null 2>&1 || true
        fi
    done
fi

# ---------- 3. Linux-only system cleanup ----------
if [ $LOCAL_MODE -eq 0 ]; then
    log "Removing systemd backup timer + service"
    if systemctl list-unit-files sygen-backup.timer >/dev/null 2>&1; then
        systemctl disable --now sygen-backup.timer >/dev/null 2>&1 || true
    fi
    if systemctl list-unit-files sygen-backup.service >/dev/null 2>&1; then
        systemctl disable --now sygen-backup.service >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/sygen-backup.timer
    rm -f /etc/systemd/system/sygen-backup.service
    rm -f /usr/local/sbin/sygen-backup.sh
    systemctl daemon-reload 2>/dev/null || true

    log "Removing /var/backups/sygen"
    rm -rf /var/backups/sygen

    log "Removing cert renewal hook"
    rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

    log "Removing nginx vhost"
    rm -f /etc/nginx/sites-enabled/sygen
    rm -f /etc/nginx/sites-available/sygen
    if command -v nginx >/dev/null 2>&1; then
        # Reload only if config still validates (it should — we only removed
        # one vhost). Best-effort: a broken nginx unrelated to us shouldn't
        # block the rest of the uninstall.
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx 2>/dev/null || true
        else
            warn "  nginx -t failed after vhost removal — leaving nginx untouched"
        fi
    fi
fi

# ---------- 4. macOS-only ----------
if [ $LOCAL_MODE -eq 1 ]; then
    if command -v colima >/dev/null 2>&1; then
        if colima status >/dev/null 2>&1; then
            log "Stopping Colima"
            colima stop 2>/dev/null || warn "  colima stop failed (ignored)"
        else
            log "Colima not running — skipping stop"
        fi
    fi
fi

# ---------- 5. Optional Cloudflare DNS cleanup ----------
# Only relevant for installs that reserved DNS directly with CF_* env vars
# (custom domain or pre-Phase 3). For subdomain-service installs, /api/release
# above already removed the record.
if [ -n "$CF_TOKEN_VAL" ] && [ -n "$CF_ZONE_VAL" ] && [ -n "$CF_SUB_VAL" ]; then
    cf_fqdn="${CF_SUB_VAL}.${CF_DOMAIN_VAL}"
    log "Releasing Cloudflare DNS A record for $cf_fqdn"
    if ! command -v curl >/dev/null 2>&1; then
        warn "  curl not installed — skipping (remove DNS manually)"
    elif ! command -v jq >/dev/null 2>&1; then
        warn "  jq not installed — skipping (remove DNS manually in Cloudflare dashboard)"
    else
        cf_record_id=$(curl -fsS \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_VAL}/dns_records?name=${cf_fqdn}&type=A" \
            -H "Authorization: Bearer ${CF_TOKEN_VAL}" 2>/dev/null \
            | jq -r '.result[0].id // empty' 2>/dev/null || true)
        if [ -n "$cf_record_id" ]; then
            if curl -fsS -X DELETE \
                "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_VAL}/dns_records/${cf_record_id}" \
                -H "Authorization: Bearer ${CF_TOKEN_VAL}" >/dev/null 2>&1; then
                log "  deleted record id $cf_record_id"
            else
                warn "  could not delete record id $cf_record_id (try the CF dashboard)"
            fi
        else
            log "  no A record for $cf_fqdn (already gone)"
        fi
    fi
else
    log "Cloudflare env vars not set — skipping DNS cleanup"
fi

# ---------- 6. Wipe SYGEN_ROOT ----------
# Re-assert the safety guard right before rm -rf. Defends against any later
# code accidentally clearing $SYGEN_ROOT between the top-of-script check
# and this line.
case "$SYGEN_ROOT" in
    /srv/sygen|"$HOME/.sygen-local") ;;
    *) die "Refusing to rm -rf unexpected SYGEN_ROOT='$SYGEN_ROOT' (safety check)" ;;
esac

if [ -d "$SYGEN_ROOT" ]; then
    log "Removing $SYGEN_ROOT"
    rm -rf "$SYGEN_ROOT"
else
    log "$SYGEN_ROOT already absent"
fi

# ---------- 7. Final summary ----------
echo ""
echo "====================================================================="
echo " Sygen has been removed from this host."
echo "---------------------------------------------------------------------"
echo "  What was removed:"
echo "    - Containers (core, admin, updater, watchtower)"
echo "    - $SYGEN_ROOT (data, .env, secrets, claude-auth)"
if [ $LOCAL_MODE -eq 0 ]; then
    echo "    - /var/backups/sygen (nightly backups)"
    echo "    - systemd units (sygen-backup.timer + .service)"
    echo "    - Nginx vhost (sygen)"
    echo "    - Cert renewal hook"
fi
echo ""
echo "  Kept (for fast re-install):"
if [ $LOCAL_MODE -eq 0 ]; then
    echo "    - Let's Encrypt cert in /etc/letsencrypt/"
fi
echo "    - System packages (docker, nginx, certbot, colima, etc.)"
echo "    - Cached Docker images (docker image prune -a to reclaim space)"
echo ""
echo "  To re-install:"
if [ $LOCAL_MODE -eq 0 ]; then
    echo "    curl -fsSL https://install.sygen.pro/install.sh | \\"
    echo "        SYGEN_SUBDOMAIN=... CF_API_TOKEN=... CF_ZONE_ID=... bash"
    echo ""
    echo "  To remove the kept cert too:"
    echo "    certbot delete --cert-name <fqdn>"
    echo ""
    echo "  To remove docker/nginx packages (rare):"
    echo "    apt-get remove docker-ce docker-ce-cli nginx"
else
    echo "    curl -fsSL https://install.sygen.pro/install.sh | bash"
    echo ""
    echo "  If Colima is no longer needed by other projects:"
    echo "    colima delete"
    echo ""
    echo "  To remove brew packages (rare):"
    echo "    brew uninstall colima docker docker-compose"
fi
echo "====================================================================="
