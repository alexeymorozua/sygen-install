#!/usr/bin/env bash
# Sygen uninstall script — clean removal of Sygen from a host.
#
# Linux  (Debian/Ubuntu VPS): stops containers, removes systemd backup
#        timer, nginx vhost, cert renewal hook, and /srv/sygen.
# macOS  (Darwin): stops containers, then either:
#          - manifest mode (v1.6.46+): reads $SYGEN_ROOT/.install_manifest.json
#            and removes ONLY the brew packages, Colima profile, and
#            launchd agents that install.sh actually put on the host.
#          - legacy mode (no manifest): does the minimum-safe cleanup
#            inherited from v1.6.45 — colima stop (no VM delete),
#            remove $SYGEN_ROOT, unload known launchd labels, never
#            touch brew. The user can wipe brew packages and the Colima
#            VM manually after a fresh install brings the manifest back.
#
# Kept on Linux (for fast re-install):
#   - Let's Encrypt cert in /etc/letsencrypt/
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
MANIFEST_INSTALLED_PKGS=()
MANIFEST_PLISTS=()
MANIFEST_DOWNLOADED_PATHS=()
MANIFEST_DOWNLOADED_TOTAL_BYTES=0
MANIFEST_COLIMA_CREATED=0
MANIFEST_COLIMA_PROFILE="default"
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
for p in m.get('installed_pkgs') or []:
    if isinstance(p, str): print('I\t' + p)
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
PY
)"; then
        USE_MANIFEST=1
        # First line is "OK"; consume it and parse the rest.
        while IFS=$'\t' read -r kind val; do
            case "$kind" in
                I) MANIFEST_INSTALLED_PKGS+=("$val") ;;
                L) MANIFEST_PLISTS+=("$val") ;;
                C) MANIFEST_COLIMA_CREATED="$val" ;;
                N) MANIFEST_COLIMA_PROFILE="$val" ;;
                D) MANIFEST_DOWNLOADED_PATHS+=("$val") ;;
                T) MANIFEST_DOWNLOADED_TOTAL_BYTES="$val" ;;
            esac
        done <<< "$(printf '%s\n' "$manifest_dump" | tail -n +2)"
    else
        warn "manifest at $MANIFEST is unreadable or malformed — falling back to legacy mode"
    fi
fi

# ---------- Confirmation gate ----------
log "This will REMOVE Sygen from this host:"
log "  - Stop and remove all Sygen containers"
log "  - Delete $SYGEN_ROOT including data, .env, secrets, claude-auth"
if [ $LOCAL_MODE -eq 0 ]; then
    log "  - Delete /var/backups/sygen"
    log "  - Remove systemd units: sygen-backup.timer/.service"
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
        if [ "$MANIFEST_COLIMA_CREATED" = "1" ]; then
            log "  - Stop Colima AND delete profile '$MANIFEST_COLIMA_PROFILE' (~27 GB VM image — sygen created it)"
        else
            log "  - Stop Colima profile '$MANIFEST_COLIMA_PROFILE' (will NOT delete the VM — it pre-existed)"
        fi
        if [ ${#MANIFEST_DOWNLOADED_PATHS[@]} -gt 0 ]; then
            log "  - Remove ${#MANIFEST_DOWNLOADED_PATHS[@]} file(s) downloaded by install.sh (~$((MANIFEST_DOWNLOADED_TOTAL_BYTES / 1024 / 1024)) MB):"
            for dp in "${MANIFEST_DOWNLOADED_PATHS[@]}"; do
                log "      $dp"
            done
        fi
    else
        log "  - Stop Colima (will NOT delete the VM — legacy install, no manifest)"
        log "  - Will NOT remove brew packages — legacy install, no manifest"
        log "  - Remove known launchd agents (host-updates-check / host-update-runner / host-uninstall-runner / host-metrics / cert-renew)"
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

        # Colima — stop first, then optionally delete the VM. Profile name
        # comes from the manifest so we don't accidentally target a
        # different user's "default" if install.sh was run with a custom
        # COLIMA_PROFILE_NAME.
        if command -v colima >/dev/null 2>&1; then
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
        # Legacy mode: don't touch brew, don't delete the VM, but still
        # unload the launchd agents we hard-coded in pre-1.6.46 installs
        # so they don't keep flapping after $SYGEN_ROOT goes away.
        log "Legacy mode (no manifest at $MANIFEST) — minimal-safe cleanup"
        if command -v colima >/dev/null 2>&1; then
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
            com.sygen.cert-renew; do
            unload_plist "$label"
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
elif [ $USE_MANIFEST -eq 1 ]; then
    if [ ${#MANIFEST_PLISTS[@]} -gt 0 ]; then
        echo "    - launchd agents: ${MANIFEST_PLISTS[*]}"
    fi
    if [ ${#MANIFEST_INSTALLED_PKGS[@]} -gt 0 ]; then
        echo "    - Brew packages installed by sygen: ${MANIFEST_INSTALLED_PKGS[*]}"
    fi
    if [ "$MANIFEST_COLIMA_CREATED" = "1" ]; then
        echo "    - Colima default profile + VM image (sygen created it)"
    fi
    if [ ${#MANIFEST_DOWNLOADED_PATHS[@]} -gt 0 ]; then
        echo "    - Files downloaded by install.sh (${#MANIFEST_DOWNLOADED_PATHS[@]}, ~$((MANIFEST_DOWNLOADED_TOTAL_BYTES / 1024 / 1024)) MB)"
    fi
fi
echo ""
echo "  Kept (for fast re-install):"
if [ $LOCAL_MODE -eq 0 ]; then
    echo "    - Let's Encrypt cert in /etc/letsencrypt/"
    echo "    - System packages (docker, nginx, certbot, etc.)"
elif [ $USE_MANIFEST -eq 1 ]; then
    if [ "$MANIFEST_COLIMA_CREATED" != "1" ]; then
        echo "    - Colima default profile (you had it before sygen)"
    fi
    echo "    - Brew packages that pre-existed the install"
else
    echo "    - All brew packages (legacy install — no manifest to drive removal)"
    echo "    - Colima default profile (legacy install — VM kept)"
fi
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
    if [ $USE_MANIFEST -eq 0 ]; then
        echo ""
        echo "  Legacy install — to manually finish cleanup:"
        echo "    colima delete                          # remove the VM (~27 GB)"
        echo "    brew uninstall colima docker docker-compose jq    # if not used elsewhere"
    fi
fi
echo "====================================================================="
