#!/usr/bin/env bash
# Hot-deploy the Keychain → file sync daemon onto an existing macOS Sygen
# install without re-running install.sh.
#
# Newer Claude Code CLI builds on macOS migrated OAuth tokens out of
# ~/.claude/.credentials.json into the login Keychain. The on-disk file
# is left as a fake placeholder, which surfaces as "Not logged in"
# inside our Docker containers. This script installs a launchd daemon
# that syncs the keychain item back to the file every 15 min, plus runs
# a one-shot sync immediately so the fix is effective before the next
# container restart.
#
# Idempotent: safe to re-run (unloads any previous launchd agent first).
#
# Usage:
#   curl -fsSL https://install.sygen.pro/scripts/deploy_keychain_sync.sh | bash
# Or:
#   bash deploy_keychain_sync.sh
set -euo pipefail

BASE_URL="${SYGEN_INSTALL_BASE_URL:-https://raw.githubusercontent.com/alexeymorozua/sygen-install/main}"

OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
    echo "[deploy-keychain-sync] Linux/$OS does not use the macOS Keychain — nothing to do."
    exit 0
fi

SYGEN_ROOT="${SYGEN_ROOT:-$HOME/.sygen-local}"
if [ ! -d "$SYGEN_ROOT" ] && [ -d /srv/sygen ]; then
    SYGEN_ROOT=/srv/sygen
fi

log() { printf '[deploy-keychain-sync] %s\n' "$*"; }
die() { printf '[deploy-keychain-sync] ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$SYGEN_ROOT" ] || die "$SYGEN_ROOT not found — is Sygen installed?"

PYTHON_BIN="$(command -v python3 || true)"
[ -z "$PYTHON_BIN" ] && die "python3 not found"

if ! security find-generic-password -s "Claude Code-credentials" -w \
        >/dev/null 2>&1; then
    die "Keychain item 'Claude Code-credentials' not found. Log in once with \
'claude' on this host (so the CLI stores the OAuth token), then re-run."
fi

# ---------- 1. Daemon script ----------
mkdir -p "$SYGEN_ROOT/bin" "$SYGEN_ROOT/logs" "$HOME/.claude"
log "Fetching keychain_sync_daemon.py"
curl -fsSL -o "$SYGEN_ROOT/bin/keychain_sync_daemon.py" \
    "$BASE_URL/scripts/keychain_sync_daemon.py" \
    || die "could not fetch keychain_sync_daemon.py"
chmod 0755 "$SYGEN_ROOT/bin/keychain_sync_daemon.py"

KEYCHAIN_TARGET="$HOME/.claude/.credentials.json"

# ---------- 2. Plist ----------
PLIST_DST="$HOME/Library/LaunchAgents/com.sygen.keychain-sync.plist"
mkdir -p "$HOME/Library/LaunchAgents"
log "Installing launchd plist → $PLIST_DST"
curl -fsSL -o /tmp/sygen.keychain-sync.plist.tmpl \
    "$BASE_URL/scripts/com.sygen.keychain-sync.plist" \
    || die "could not fetch plist template"
sed \
    -e "s|__PYTHON__|$PYTHON_BIN|g" \
    -e "s|__SCRIPT__|$SYGEN_ROOT/bin/keychain_sync_daemon.py|g" \
    -e "s|__TARGET__|$KEYCHAIN_TARGET|g" \
    -e "s|__SYGEN_ROOT__|$SYGEN_ROOT|g" \
    /tmp/sygen.keychain-sync.plist.tmpl > "$PLIST_DST"
rm -f /tmp/sygen.keychain-sync.plist.tmpl

# ---------- 3. One-shot sync before launchd takes over ----------
log "Running one-shot keychain → file sync"
"$PYTHON_BIN" "$SYGEN_ROOT/bin/keychain_sync_daemon.py" \
    --target "$KEYCHAIN_TARGET" --once \
    || die "initial sync failed — see error above"

# ---------- 4. Reload launchd agent ----------
launchctl unload "$PLIST_DST" >/dev/null 2>&1 || true
launchctl load -w "$PLIST_DST" \
    || die "launchctl load failed"
log "launchd agent loaded"

log "Done."
log "  Status:  launchctl list | grep keychain-sync"
log "  Log:     tail -f $SYGEN_ROOT/logs/keychain-sync.log"
log "  Token:   python3 -c \"import json; d=json.load(open('$KEYCHAIN_TARGET')); \\"
log "             print(list(d.get('claudeAiOauth', {}).keys()))\""
