#!/usr/bin/env bash
# Hot-deploy the self-uninstall runner onto an existing macOS Sygen
# install without re-running install.sh.
#
# Installs:
#   - $SYGEN_ROOT/uninstall.sh                          (local copy)
#   - $SYGEN_ROOT/bin/host_uninstall_runner.sh
#   - ~/Library/LaunchAgents/com.sygen.host-uninstall-runner.plist
#
# Pairs with the /api/system/uninstall endpoint that v1.6.45+ core
# exposes; with both halves installed, "Delete Server" in the iOS app
# stops containers, removes ~/.sygen-local, and frees RAM.
#
# Linux installs are out of scope — server-class operators run
# uninstall.sh manually.
#
# Usage:
#   curl -fsSL https://install.sygen.pro/scripts/deploy_host_uninstall.sh | bash
# Or:
#   bash deploy_host_uninstall.sh
set -euo pipefail

BASE_URL="${SYGEN_INSTALL_BASE_URL:-https://raw.githubusercontent.com/alexeymorozua/sygen-install/main}"

OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
    echo "[deploy-host-uninstall] Linux/$OS uses manual uninstall.sh — nothing to deploy."
    exit 0
fi

SYGEN_ROOT="${SYGEN_ROOT:-$HOME/.sygen-local}"
if [ ! -d "$SYGEN_ROOT" ] && [ -d /srv/sygen ]; then
    SYGEN_ROOT=/srv/sygen
fi

log() { printf '[deploy-host-uninstall] %s\n' "$*"; }
die() { printf '[deploy-host-uninstall] ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$SYGEN_ROOT" ] || die "$SYGEN_ROOT not found — is Sygen installed?"

mkdir -p "$SYGEN_ROOT/bin" "$SYGEN_ROOT/logs" "$SYGEN_ROOT/host_updates"

# ---------- 1. Local uninstall.sh ----------
log "Fetching uninstall.sh"
curl -fsSL -o "$SYGEN_ROOT/uninstall.sh" \
    "$BASE_URL/uninstall.sh" \
    || die "could not fetch uninstall.sh"
chmod 0755 "$SYGEN_ROOT/uninstall.sh"

# ---------- 2. Runner script ----------
log "Fetching host_uninstall_runner.sh"
curl -fsSL -o "$SYGEN_ROOT/bin/host_uninstall_runner.sh" \
    "$BASE_URL/scripts/host_uninstall_runner.sh" \
    || die "could not fetch host_uninstall_runner.sh"
chmod 0755 "$SYGEN_ROOT/bin/host_uninstall_runner.sh"

# ---------- 3. Plist ----------
mkdir -p "$HOME/Library/LaunchAgents"

label="com.sygen.host-uninstall-runner"
plist_dst="$HOME/Library/LaunchAgents/$label.plist"
tmpl="/tmp/$label.plist.tmpl"

curl -fsSL -o "$tmpl" "$BASE_URL/scripts/$label.plist" \
    || die "could not fetch $label.plist"
sed \
    -e "s|__SCRIPT__|$SYGEN_ROOT/bin/host_uninstall_runner.sh|g" \
    -e "s|__SYGEN_ROOT__|$SYGEN_ROOT|g" \
    -e "s|__HOME__|$HOME|g" \
    "$tmpl" > "$plist_dst"
rm -f "$tmpl"
chmod 0644 "$plist_dst"

launchctl unload "$plist_dst" >/dev/null 2>&1 || true
launchctl load -w "$plist_dst" \
    || die "launchctl load failed for $label"
log "Loaded $label"

log "Done."
log "  Status:  launchctl list | grep host-uninstall-runner"
log "  Logs:    tail -f $SYGEN_ROOT/logs/host-uninstall-runner.log"
log "  Trigger: iOS 'Delete Server' or"
log "           POST /api/system/uninstall on the running core"
