#!/usr/bin/env bash
# Sygen uninstall script — clean removal of Sygen from a host.
#
# Routes on $MANIFEST.install_mode:
#   - "native"  (v1.7+): stops launchd/systemd services, removes the venv
#               + admin dir, plists/units, $SYGEN_ROOT.
#   - "docker"  (or absent — pre-v1.7 manifests): runs the legacy Docker
#               cleanup path: docker compose down, colima stop/delete,
#               brew uninstall (manifest-driven), $SYGEN_ROOT wipe.
#
# Linux  (Debian/Ubuntu VPS): stops services (native) or containers
#        (legacy), removes systemd backup timer, nginx vhost, cert
#        renewal hook, and /srv/sygen.
# macOS  (Darwin): stops services (native) or containers (legacy), then
#        runs the appropriate platform cleanup driven by the manifest.
#
# Kept on Linux (for fast re-install):
#   - Let's Encrypt cert in /etc/letsencrypt/
#   - System packages (python3, node, nginx, certbot, etc.)
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
#
# CLI flags:
#   --force            Skip confirmation prompt (same effect as
#                      SYGEN_UNINSTALL_CONFIRM=1).
#   --delete-vm        DEPRECATED in v1.6.46+ — manifest now controls VM
#                      deletion. Accepted for backward compat with old
#                      host_uninstall_runner.sh; ignored with a warning.
#   --keep-brew        DEPRECATED in v1.6.46+ — manifest now controls
#                      brew package removal. Accepted for backward compat;
#                      ignored with a warning.
set -euo pipefail

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- CLI flags ----------
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force)        FORCE=1 ;;
        --delete-vm)    warn "--delete-vm is ignored in v1.6.46+ — manifest now controls VM deletion" ;;
        --keep-brew)    warn "--keep-brew is ignored in v1.6.46+ — manifest now controls brew removal" ;;
        --no-keep-brew) warn "--no-keep-brew is ignored in v1.6.46+ — manifest now controls brew removal" ;;
        --help|-h)
            sed -n '1,42p' "$0"
            exit 0
            ;;
        *) warn "ignoring unknown flag: $1" ;;
    esac
    shift
done

if [ $FORCE -eq 1 ]; then
    SYGEN_UNINSTALL_CONFIRM=1
    export SYGEN_UNINSTALL_CONFIRM
fi

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

# ---------- Manifest detection ----------
# v1.6.46+: install.sh writes $SYGEN_ROOT/.install_manifest.json. When it
# exists we drive the macOS-side cleanup from it. When it doesn't (older
# install or manually-deleted manifest) we fall back to the v1.6.45
# behaviour: never touch brew, never delete the Colima VM, only handle
# the launchd agents we hard-coded last release.
#
# colima_profile_name was hardcoded to "default" in 1.6.46; v1.6.47+
# records the actual profile install.sh used so a future non-default
# profile won't accidentally cause `colima delete` to target someone
# else's "default" VM. Falls back to "default" for manifests that
# pre-date the change.
MANIFEST="$SYGEN_ROOT/.install_manifest.json"
USE_MANIFEST=0
INSTALL_MODE=""           # "native" (v1.7+) or "docker" (legacy/v1/v2)
MANIFEST_INSTALLED_PKGS=()
MANIFEST_INSTALLED_NPM=()
MANIFEST_INSTALLED_BINARIES=()
MANIFEST_PLISTS=()
MANIFEST_DOWNLOADED_PATHS=()
MANIFEST_DOWNLOADED_TOTAL_BYTES=0
MANIFEST_COLIMA_CREATED=0
MANIFEST_COLIMA_PROFILE="default"
MANIFEST_AUTOSTART_PLISTS=()
MANIFEST_AUTOSTART_LINUX_UNITS=()
MANIFEST_CORE_VENV=""
MANIFEST_ADMIN_DIR=""
if [ -f "$MANIFEST" ] && command -v python3 >/dev/null 2>&1; then
    if manifest_dump="$(python3 - "$MANIFEST" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        m = json.load(f)
except Exception:
    sys.exit(2)
if not isinstance(m, dict):
    sys.exit(2)
print('OK')
mode = m.get('install_mode')
if isinstance(mode, str) and mode:
    print('M\t' + mode)
else:
    # Manifests written before v1.7 lacked install_mode (Docker-mode).
    print('M\tdocker')
for p in m.get('installed_pkgs') or []:
    if isinstance(p, str): print('I\t' + p)
for p in m.get('installed_npm') or []:
    if isinstance(p, str): print('NI\t' + p)
for p in m.get('installed_binaries') or []:
    if isinstance(p, str): print('BI\t' + p)
for p in m.get('plists_installed') or []:
    if isinstance(p, str): print('L\t' + p)
v = m.get('colima_profile_created')
if isinstance(v, bool):
    print('C\t' + ('1' if v else '0'))
n = m.get('colima_profile_name')
if isinstance(n, str) and n:
    print('N\t' + n)
total = 0
for d in m.get('downloaded_files') or []:
    if not isinstance(d, dict): continue
    p = d.get('path')
    if not isinstance(p, str) or not p: continue
    sz = d.get('size_bytes')
    if isinstance(sz, int) and sz > 0: total += sz
    print('D\t' + p)
print('T\t' + str(total))
for p in m.get('autostart_macos_plists') or []:
    if isinstance(p, str) and p: print('A\t' + p)
units = m.get('autostart_linux_units')
if isinstance(units, list):
    for u in units:
        if isinstance(u, str) and u: print('U\t' + u)
else:
    u = m.get('autostart_linux_unit')
    if isinstance(u, str) and u: print('U\t' + u)
v = m.get('core_venv')
if isinstance(v, str) and v: print('V\t' + v)
a = m.get('admin_dir')
if isinstance(a, str) and a: print('B\t' + a)
PY
)"; then
        USE_MANIFEST=1
        while IFS=$'\t' read -r kind val; do
            case "$kind" in
                M) INSTALL_MODE="$val" ;;
                I) MANIFEST_INSTALLED_PKGS+=("$val") ;;
                NI) MANIFEST_INSTALLED_NPM+=("$val") ;;
                BI) MANIFEST_INSTALLED_BINARIES+=("$val") ;;
                L) MANIFEST_PLISTS+=("$val") ;;
                C) MANIFEST_COLIMA_CREATED="$val" ;;
                N) MANIFEST_COLIMA_PROFILE="$val" ;;
                D) MANIFEST_DOWNLOADED_PATHS+=("$val") ;;
                T) MANIFEST_DOWNLOADED_TOTAL_BYTES="$val" ;;
                A) MANIFEST_AUTOSTART_PLISTS+=("$val") ;;
                U) MANIFEST_AUTOSTART_LINUX_UNITS+=("$val") ;;
                V) MANIFEST_CORE_VENV="$val" ;;
                B) MANIFEST_ADMIN_DIR="$val" ;;
            esac
        done <<< "$(printf '%s\n' "$manifest_dump" | tail -n +2)"
    else
        warn "manifest at $MANIFEST is unreadable or malformed — falling back to legacy mode"
    fi
fi
# Legacy fallback: if there's no manifest but a docker-compose.yml
# exists, this is a pre-1.7 Docker install and uninstall.sh should run
# the Docker cleanup path. Otherwise default to native.
if [ -z "$INSTALL_MODE" ]; then
    if [ -f "$SYGEN_ROOT/docker-compose.yml" ]; then
        INSTALL_MODE="docker"
    else
        INSTALL_MODE="native"
    fi
fi

# ---------- Confirmation gate ----------
log "This will REMOVE Sygen from this host (install_mode=$INSTALL_MODE):"
if [ "$INSTALL_MODE" = "native" ]; then
    log "  - Stop and unload native services (sygen-core / sygen-admin / sygen-updater)"
else
    log "  - Stop and remove all Sygen containers"
fi
log "  - Delete $SYGEN_ROOT including data, .env, venv, admin, secrets, .claude"
if [ $LOCAL_MODE -eq 0 ]; then
    log "  - Delete /var/backups/sygen"
    if [ "$INSTALL_MODE" = "native" ]; then
        log "  - Disable + remove systemd units: sygen-backup.timer/.service,"
        log "    sygen-core.service, sygen-admin.service, sygen-updater.service"
    else
        log "  - Remove systemd units: sygen-backup.timer/.service, sygen-compose.service"
    fi
    if [ ${#MANIFEST_AUTOSTART_LINUX_UNITS[@]} -gt 0 ]; then
        log "    (manifest: ${MANIFEST_AUTOSTART_LINUX_UNITS[*]})"
    fi
    log "  - Remove cert renewal hook (/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh)"
    log "  - Remove nginx vhost (sygen)"
fi
if [ $LOCAL_MODE -eq 1 ]; then
    if [ $USE_MANIFEST -eq 1 ]; then
        if [ ${#MANIFEST_PLISTS[@]} -gt 0 ]; then
            log "  - Unload + remove launchd agents: ${MANIFEST_PLISTS[*]}"
        fi
        if [ ${#MANIFEST_INSTALLED_PKGS[@]} -gt 0 ]; then
            log "  - brew uninstall packages installed by sygen: ${MANIFEST_INSTALLED_PKGS[*]}"
        else
            log "  - No sygen-owned brew packages to remove (manifest is empty)"
        fi
        if [ ${#MANIFEST_INSTALLED_NPM[@]} -gt 0 ]; then
            log "  - npm uninstall -g packages installed by sygen: ${MANIFEST_INSTALLED_NPM[*]}"
        fi
        if [ "$INSTALL_MODE" = "docker" ]; then
            if [ "$MANIFEST_COLIMA_CREATED" = "1" ]; then
                log "  - Stop Colima AND delete profile '$MANIFEST_COLIMA_PROFILE' (~27 GB VM image — sygen created it)"
            else
                log "  - Stop Colima profile '$MANIFEST_COLIMA_PROFILE' (will NOT delete the VM — it pre-existed)"
            fi
        fi
        if [ ${#MANIFEST_DOWNLOADED_PATHS[@]} -gt 0 ]; then
            log "  - Remove ${#MANIFEST_DOWNLOADED_PATHS[@]} file(s) downloaded by install.sh (~$((MANIFEST_DOWNLOADED_TOTAL_BYTES / 1024 / 1024)) MB):"
            for dp in "${MANIFEST_DOWNLOADED_PATHS[@]}"; do
                log "      $dp"
            done
        fi
    else
        if [ "$INSTALL_MODE" = "docker" ]; then
            log "  - Stop Colima (will NOT delete the VM — legacy install, no manifest)"
            log "  - Will NOT remove brew packages — legacy install, no manifest"
        fi
        log "  - Remove known launchd agents (host-updates-check / host-update-runner / host-uninstall-runner / host-metrics / cert-renew / pro.sygen.{core,admin,updater})"
    fi
fi
if [ $LOCAL_MODE -eq 0 ] && [ $USE_MANIFEST -eq 1 ]; then
    if [ ${#MANIFEST_INSTALLED_NPM[@]} -gt 0 ]; then
        log "  - npm uninstall -g packages installed by sygen: ${MANIFEST_INSTALLED_NPM[*]}"
    fi
    if [ ${#MANIFEST_INSTALLED_BINARIES[@]} -gt 0 ]; then
        log "  - Remove binaries installed by sygen: ${MANIFEST_INSTALLED_BINARIES[*]}"
    fi
fi
log "  - Release the install.sygen.pro subdomain slot (if .env has SYGEN_INSTALL_TOKEN)"
log "  - Optionally release Cloudflare DNS A record (if CF_* env vars set)"
log ""
log "It will NOT touch:"
if [ $LOCAL_MODE -eq 0 ]; then
    log "  - The Let's Encrypt cert in /etc/letsencrypt/ (kept for re-install)"
    log "  - System packages (docker, nginx, certbot, etc.)"
elif [ $USE_MANIFEST -eq 1 ]; then
    log "  - Brew packages that pre-existed the install (left intact)"
fi
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

# ---------- 2. Stop running services / containers ----------
if [ "$INSTALL_MODE" = "native" ]; then
    log "Stopping native Sygen services"
    if [ $LOCAL_MODE -eq 1 ]; then
        # macOS — unload all three sygen LaunchAgents (idempotent).
        for label in pro.sygen.core pro.sygen.admin pro.sygen.updater; do
            launchctl unload "$HOME/Library/LaunchAgents/${label}.plist" >/dev/null 2>&1 || true
        done
    else
        # Linux — stop+disable systemd units (idempotent on missing units).
        for unit in sygen-core sygen-admin sygen-updater; do
            if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1; then
                systemctl disable --now "${unit}.service" >/dev/null 2>&1 || true
            fi
        done
    fi
else
    # ----- Legacy Docker uninstall path -----
    if [ -f "$SYGEN_ROOT/docker-compose.yml" ] && command -v docker >/dev/null 2>&1; then
        log "Stopping Sygen containers (legacy Docker install)"
        docker compose -f "$SYGEN_ROOT/docker-compose.yml" down -v --remove-orphans 2>/dev/null \
            || warn "  docker compose down failed — containers may already be gone"
    else
        log "No docker-compose.yml at $SYGEN_ROOT — skipping container stop"
    fi

    # Belt-and-suspenders: kill any leftover Sygen containers by name.
    if command -v docker >/dev/null 2>&1; then
        for name in sygen-core sygen-admin sygen-watchtower sygen-updater; do
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
                docker rm -f "$name" >/dev/null 2>&1 || true
            fi
        done
    fi
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

    # Auto-start units. Native installs ship three (core/admin/updater);
    # legacy Docker installs ship one (sygen-compose). Hardcoded by name
    # to cover the case where the manifest is missing.
    if [ "$INSTALL_MODE" = "native" ]; then
        log "Removing systemd native service units (sygen-core/admin/updater + host-metrics + uninstall-runner)"
        # sygen-host-uninstall-runner.service is THIS process's parent unit
        # — disabling it would kill us mid-uninstall. We rm the unit file
        # and rely on `systemctl daemon-reload` after the uninstall to
        # forget it. The current systemd job tree dies when the binary
        # under /srv/sygen disappears anyway.
        for unit in sygen-core sygen-admin sygen-updater sygen-host-metrics; do
            if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1; then
                systemctl disable --now "${unit}.service" >/dev/null 2>&1 || true
            fi
            rm -f "/etc/systemd/system/${unit}.service"
        done
        rm -f /etc/systemd/system/sygen-host-uninstall-runner.service
        # Sweep multi-user.target.wants symlinks pointing at our (now-deleted)
        # unit files. Without this `systemctl enable` leaves a broken symlink
        # behind, visible as a `systemctl list-unit-files` warning forever.
        for unit in sygen-core sygen-admin sygen-updater sygen-host-metrics \
                    sygen-host-uninstall-runner sygen-backup; do
            rm -f "/etc/systemd/system/multi-user.target.wants/${unit}.service" \
                  "/etc/systemd/system/timers.target.wants/${unit}.timer"
        done
        # ACME hooks (publicdomain mode only — auto-mode uses Worker-mediated
        # DNS-01 with the same hooks). install.sh writes them to
        # /usr/local/sbin/sygen-acme-{auth,cleanup}-hook.sh.
        rm -f /usr/local/sbin/sygen-acme-auth-hook.sh \
              /usr/local/sbin/sygen-acme-cleanup-hook.sh
        # install.sh staging artefacts left behind in /tmp (best-effort).
        rm -f /tmp/sygen.nginx.tmpl /tmp/sygen-install.log \
              /tmp/sygen.host-metrics.plist.tmpl \
              /tmp/sygen-host-metrics.service.tmpl \
              /tmp/sygen-host-uninstall-runner.service.tmpl \
              /tmp/sygen-host-metrics.env \
              /tmp/sygen-heartbeat-probe.json
        # Drop leftover dangling symlinks systemd may have for these names.
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        log "Removing systemd auto-start unit (sygen-compose.service)"
        if systemctl list-unit-files sygen-compose.service >/dev/null 2>&1; then
            systemctl disable --now sygen-compose.service >/dev/null 2>&1 || true
        fi
        rm -f /etc/systemd/system/sygen-compose.service
    fi

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
    # Helpers shared between manifest mode and legacy mode.
    unload_plist() {
        # $1 = launchd label (e.g. com.sygen.host-update-runner). The path
        # is always $HOME/Library/LaunchAgents/<label>.plist on macOS.
        local label="$1"
        local plist="$HOME/Library/LaunchAgents/${label}.plist"
        launchctl unload "$plist" >/dev/null 2>&1 || true
        rm -f "$plist" 2>/dev/null || true
    }

    if [ $USE_MANIFEST -eq 1 ]; then
        log "Manifest mode — using $MANIFEST to drive cleanup"

        # Plists FIRST so we don't fight a daemon that might re-create
        # state mid-uninstall (host_metrics is the only realistic one,
        # but cheap to do all at once).
        if [ ${#MANIFEST_PLISTS[@]} -gt 0 ]; then
            log "Unloading launchd agents from manifest"
            for label in "${MANIFEST_PLISTS[@]}"; do
                unload_plist "$label"
            done
        fi

        # Colima — only relevant for legacy Docker installs.
        if [ "$INSTALL_MODE" = "docker" ] && command -v colima >/dev/null 2>&1; then
            if colima status --profile "$MANIFEST_COLIMA_PROFILE" >/dev/null 2>&1; then
                log "Stopping Colima profile=$MANIFEST_COLIMA_PROFILE"
                colima stop --profile "$MANIFEST_COLIMA_PROFILE" 2>/dev/null \
                    || warn "  colima stop failed (ignored)"
            fi
            if [ "$MANIFEST_COLIMA_CREATED" = "1" ]; then
                log "Deleting Colima profile=$MANIFEST_COLIMA_PROFILE (manifest says we created it — frees ~27 GB)"
                colima delete --profile "$MANIFEST_COLIMA_PROFILE" --force 2>/dev/null \
                    || warn "  colima delete failed (ignored — re-run manually if needed)"
            else
                log "Leaving Colima profile=$MANIFEST_COLIMA_PROFILE intact (manifest says it pre-existed sygen)"
            fi
        fi

        # Brew packages — only the ones we installed. We do NOT pass
        # --ignore-dependencies: that flag would silently uninstall a
        # package even when other formulas depend on it, breaking
        # unrelated tools. If brew refuses because of dependents, we
        # log it and skip — the user can decide whether to force-prune
        # via `brew autoremove` or by removing the dependents first.
        if [ ${#MANIFEST_INSTALLED_PKGS[@]} -gt 0 ] && command -v brew >/dev/null 2>&1; then
            log "brew uninstall (sygen-owned packages from manifest)"
            for pkg in "${MANIFEST_INSTALLED_PKGS[@]}"; do
                if brew list "$pkg" >/dev/null 2>&1; then
                    if ! brew uninstall "$pkg" 2>&1; then
                        warn "  brew uninstall $pkg refused (likely has other dependents) — leaving installed"
                    fi
                fi
            done
        fi
    else
        log "Legacy mode (no manifest at $MANIFEST) — minimal-safe cleanup"
        if [ "$INSTALL_MODE" = "docker" ] && command -v colima >/dev/null 2>&1; then
            if colima status >/dev/null 2>&1; then
                log "Stopping Colima"
                colima stop 2>/dev/null || warn "  colima stop failed (ignored)"
            else
                log "Colima not running — skipping stop"
            fi
        fi
        for label in \
            com.sygen.host-uninstall-runner \
            com.sygen.host-update-runner \
            com.sygen.host-updates-check \
            com.sygen.host-metrics \
            com.sygen.cert-renew \
            pro.sygen.colima \
            pro.sygen.compose \
            pro.sygen.core \
            pro.sygen.admin \
            pro.sygen.updater; do
            unload_plist "$label"
        done
    fi

    # macOS: install.sh staging artefacts in /tmp (best-effort safety net
    # for interrupted-install orphans + parity with the Linux branch).
    rm -f /tmp/sygen.nginx.tmpl /tmp/sygen-install.log \
          /tmp/sygen.host-metrics.plist.tmpl \
          /tmp/sygen-host-metrics.service.tmpl \
          /tmp/sygen-host-uninstall-runner.service.tmpl \
          /tmp/sygen-host-metrics.env \
          /tmp/sygen-heartbeat-probe.json 2>/dev/null || true
fi

# ---------- 4b. npm globals + standalone binaries (manifest-driven) ----------
# Cross-platform: claude CLI is npm-installed on both macOS and Linux,
# whisper-cli is a source-built binary on Linux only. Both are tracked
# in their own manifest buckets so we never `npm uninstall` or `rm` a
# binary the user owned before sygen.
if [ $USE_MANIFEST -eq 1 ]; then
    if [ ${#MANIFEST_INSTALLED_NPM[@]} -gt 0 ]; then
        if command -v npm >/dev/null 2>&1; then
            log "npm uninstall -g (sygen-owned npm globals from manifest)"
            for pkg in "${MANIFEST_INSTALLED_NPM[@]}"; do
                # Best-effort. npm exits non-zero if the package is
                # already gone, which is fine — we just want it gone.
                if npm uninstall -g "$pkg" >/dev/null 2>&1; then
                    log "  removed npm global: $pkg"
                else
                    warn "  npm uninstall -g $pkg failed or already gone (ignored)"
                fi
            done
        else
            warn "npm not found — cannot uninstall manifest npm globals: ${MANIFEST_INSTALLED_NPM[*]}"
        fi
    fi

    if [ ${#MANIFEST_INSTALLED_BINARIES[@]} -gt 0 ]; then
        log "Removing binaries installed by sygen (manifest's installed_binaries)"
        for bpath in "${MANIFEST_INSTALLED_BINARIES[@]}"; do
            # Same defence-in-depth filters as downloaded_files: reject
            # root/empty/.. and require an absolute path under one of the
            # two directories install.sh actually drops binaries into.
            case "$bpath" in
                ''|/) warn "  refusing to remove root/empty binary path"; continue ;;
                *..*) warn "  refusing binary path with .. components: $bpath"; continue ;;
            esac
            case "$bpath" in
                /usr/local/bin/*|/usr/local/sbin/*) ;;
                *)
                    warn "  binary path is not under /usr/local/{bin,sbin}, skipping: $bpath"
                    continue
                    ;;
            esac
            if [ -e "$bpath" ] || [ -L "$bpath" ]; then
                log "  removing $bpath"
                rm -f "$bpath" 2>/dev/null \
                    || warn "    failed to remove $bpath (ignored)"
            else
                log "  $bpath already gone, skipping"
            fi
        done
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

# ---------- 5b. Remove host files install.sh downloaded ----------
# v1.6.49+: install.sh records files it pulled to host paths OUTSIDE
# $SYGEN_ROOT in manifest's downloaded_files (today: the ggml-small whisper
# model, ~466 MB). The wipe below only nukes $SYGEN_ROOT, so without this
# block those files would orphan on disk after a "clean" uninstall.
#
# Only acts on paths the manifest explicitly recorded. A pre-existing
# whisper model the user staged manually before sygen was never recorded
# (install.sh's download branch is gated on `if [ -f $MODEL_PATH ]`), so
# this loop will never touch it.
if [ ${#MANIFEST_DOWNLOADED_PATHS[@]} -gt 0 ]; then
    log "Removing files install.sh downloaded to host (manifest's downloaded_files)"
    for dpath in "${MANIFEST_DOWNLOADED_PATHS[@]}"; do
        # Defence in depth. The primary safety check is the allowlist
        # below (path must be under $HOME or $SYGEN_ROOT — the only two
        # locations install.sh actually writes outside the wipe tree).
        # An additional reject filter blocks two specific footguns a
        # tampered manifest could use:
        #   1. "/" or empty — `rm -f /` is fatal even with -f.
        #   2. "..": path-traversal smuggled into the allowlist string
        #      check (which is purely a glob prefix and doesn't resolve
        #      relative segments). Reject anything containing "..".
        case "$dpath" in
            ''|/) warn "  refusing to remove root/empty path from manifest"; continue ;;
            *..*) warn "  refusing path with .. components: $dpath"; continue ;;
        esac
        # Allowlist: only $HOME-rooted (whisper model today) or
        # $SYGEN_ROOT-rooted (forward-safe — though step 6 below also
        # wipes $SYGEN_ROOT, so this is mostly belt+suspenders).
        case "$dpath" in
            "$HOME"/*|"$SYGEN_ROOT"/*) ;;
            *)
                warn "  manifest path is not under \$HOME or \$SYGEN_ROOT, skipping: $dpath"
                continue
                ;;
        esac
        if [ -f "$dpath" ]; then
            log "  removing $dpath"
            rm -f "$dpath" 2>/dev/null \
                || warn "    failed to remove $dpath (ignored)"
        else
            log "  $dpath already gone, skipping"
        fi
    done

    # Best-effort: drop now-empty parent dirs so a clean uninstall
    # doesn't leave behind ~/.local/share/whisper-cpp/models/ as an
    # empty husk. rmdir refuses non-empty dirs so this is safe even
    # if the user has other models stashed alongside ours.
    rmdir "$HOME/.local/share/whisper-cpp/models" 2>/dev/null || true
    rmdir "$HOME/.local/share/whisper-cpp" 2>/dev/null || true
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

# ---------- 6b. Remove the dedicated 'sygen' system user (Linux native) ----------
# Native installs since v1.6.75 ship a `sygen` system account that runs the
# core/admin services. With $SYGEN_ROOT now gone the account has nothing
# left to own, so remove it on uninstall. Best-effort — userdel can fail if
# a stray process still holds the uid; we don't want to block the rest of
# the cleanup on that.
if [ $LOCAL_MODE -eq 0 ] && [ "$INSTALL_MODE" = "native" ]; then
    if id -u sygen >/dev/null 2>&1; then
        log "Removing system user 'sygen'"
        userdel sygen 2>/dev/null \
            || warn "userdel sygen failed — remove manually if needed (lingering process holding uid?)"
    fi
fi

# ---------- 7. Final summary ----------
echo ""
echo "====================================================================="
echo " Sygen has been removed from this host (install_mode=$INSTALL_MODE)."
echo "---------------------------------------------------------------------"
echo "  What was removed:"
if [ "$INSTALL_MODE" = "native" ]; then
    echo "    - Native services (sygen-core, sygen-admin, sygen-updater)"
else
    echo "    - Containers (core, admin, updater, watchtower)"
fi
echo "    - $SYGEN_ROOT (data, .env, venv, admin, secrets, .claude)"
if [ $LOCAL_MODE -eq 0 ]; then
    echo "    - /var/backups/sygen (nightly backups)"
    if [ "$INSTALL_MODE" = "native" ]; then
        echo "    - systemd units (sygen-backup, sygen-core, sygen-admin, sygen-updater)"
        echo "    - System user 'sygen'"
    else
        echo "    - systemd units (sygen-backup, sygen-compose)"
    fi
    echo "    - Nginx vhost (sygen)"
    echo "    - Cert renewal hook"
elif [ $USE_MANIFEST -eq 1 ]; then
    if [ ${#MANIFEST_PLISTS[@]} -gt 0 ]; then
        echo "    - launchd agents: ${MANIFEST_PLISTS[*]}"
    fi
    if [ ${#MANIFEST_INSTALLED_PKGS[@]} -gt 0 ]; then
        echo "    - Brew packages installed by sygen: ${MANIFEST_INSTALLED_PKGS[*]}"
    fi
    if [ "$INSTALL_MODE" = "docker" ] && [ "$MANIFEST_COLIMA_CREATED" = "1" ]; then
        echo "    - Colima default profile + VM image (sygen created it)"
    fi
    if [ ${#MANIFEST_DOWNLOADED_PATHS[@]} -gt 0 ]; then
        echo "    - Files downloaded by install.sh (${#MANIFEST_DOWNLOADED_PATHS[@]}, ~$((MANIFEST_DOWNLOADED_TOTAL_BYTES / 1024 / 1024)) MB)"
    fi
fi
if [ $USE_MANIFEST -eq 1 ]; then
    if [ ${#MANIFEST_INSTALLED_NPM[@]} -gt 0 ]; then
        echo "    - npm globals installed by sygen: ${MANIFEST_INSTALLED_NPM[*]}"
    fi
    if [ ${#MANIFEST_INSTALLED_BINARIES[@]} -gt 0 ]; then
        echo "    - Binaries installed by sygen: ${MANIFEST_INSTALLED_BINARIES[*]}"
    fi
fi
echo ""
echo "  Kept (for fast re-install):"
if [ $LOCAL_MODE -eq 0 ]; then
    echo "    - Let's Encrypt cert in /etc/letsencrypt/"
    if [ "$INSTALL_MODE" = "native" ]; then
        echo "    - System packages (python3, node, nginx, certbot, etc.)"
    else
        echo "    - System packages (docker, nginx, certbot, etc.)"
    fi
elif [ $USE_MANIFEST -eq 1 ]; then
    if [ "$INSTALL_MODE" = "docker" ] && [ "$MANIFEST_COLIMA_CREATED" != "1" ]; then
        echo "    - Colima default profile (you had it before sygen)"
    fi
    echo "    - Brew packages that pre-existed the install"
else
    echo "    - All brew packages (legacy install — no manifest to drive removal)"
fi
echo ""
echo "  To re-install:"
if [ $LOCAL_MODE -eq 0 ]; then
    echo "    curl -fsSL https://install.sygen.pro/install.sh | \\"
    echo "        SYGEN_SUBDOMAIN=... CF_API_TOKEN=... CF_ZONE_ID=... bash"
    echo ""
    echo "  To remove the kept cert too:"
    echo "    certbot delete --cert-name <fqdn>"
else
    echo "    curl -fsSL https://install.sygen.pro/install.sh | bash"
fi
echo "====================================================================="
