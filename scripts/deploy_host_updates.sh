#!/usr/bin/env bash
# Hot-deploy the host_updates check + runner daemons onto an existing
# macOS Sygen install without re-running install.sh.
#
# Installs:
#   - $SYGEN_ROOT/bin/host_updates_check.sh
#   - $SYGEN_ROOT/bin/host_update_runner.sh
#   - $SYGEN_ROOT/host_updates/{state.json,result.json}  (touched empty)
#   - ~/Library/LaunchAgents/com.sygen.host-updates-check.plist
#   - ~/Library/LaunchAgents/com.sygen.host-update-runner.plist
#
# Edits docker-compose.yml to bind-mount $SYGEN_ROOT/host_updates as
# /data/host_updates:rw inside sygen-core (idempotent — checks for a
# marker before re-inserting).
#
# Usage:
#   curl -fsSL https://install.sygen.pro/scripts/deploy_host_updates.sh | bash
# Or:
#   bash deploy_host_updates.sh
set -euo pipefail

BASE_URL="${SYGEN_INSTALL_BASE_URL:-https://raw.githubusercontent.com/alexeymorozua/sygen-install/main}"

OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
    echo "[deploy-host-updates] Linux/$OS does not have Homebrew — nothing to do."
    exit 0
fi

SYGEN_ROOT="${SYGEN_ROOT:-$HOME/.sygen-local}"
if [ ! -d "$SYGEN_ROOT" ] && [ -d /srv/sygen ]; then
    SYGEN_ROOT=/srv/sygen
fi

log() { printf '[deploy-host-updates] %s\n' "$*"; }
die() { printf '[deploy-host-updates] ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$SYGEN_ROOT" ] || die "$SYGEN_ROOT not found — is Sygen installed?"

# ---------- 1. Daemon scripts ----------
mkdir -p "$SYGEN_ROOT/bin" "$SYGEN_ROOT/logs" "$SYGEN_ROOT/host_updates"

log "Fetching host_updates_check.sh"
curl -fsSL -o "$SYGEN_ROOT/bin/host_updates_check.sh" \
    "$BASE_URL/scripts/host_updates_check.sh" \
    || die "could not fetch host_updates_check.sh"
chmod 0755 "$SYGEN_ROOT/bin/host_updates_check.sh"

log "Fetching host_update_runner.sh"
curl -fsSL -o "$SYGEN_ROOT/bin/host_update_runner.sh" \
    "$BASE_URL/scripts/host_update_runner.sh" \
    || die "could not fetch host_update_runner.sh"
chmod 0755 "$SYGEN_ROOT/bin/host_update_runner.sh"

# Touch empty state files so the docker-compose bind-mount target
# directory is non-empty and the dashboard's first GET doesn't race the
# initial check.
[ -f "$SYGEN_ROOT/host_updates/state.json" ] || \
    printf '{"supported":false,"reason":"initial deploy"}\n' \
        > "$SYGEN_ROOT/host_updates/state.json"
chmod 0644 "$SYGEN_ROOT/host_updates/state.json"

# ---------- 2. One-shot check before launchd takes over ----------
log "Running one-shot host_updates check"
SYGEN_ROOT="$SYGEN_ROOT" "$SYGEN_ROOT/bin/host_updates_check.sh" \
    --output "$SYGEN_ROOT/host_updates/state.json" \
    || log "WARN: initial check failed — daemon will retry"

# ---------- 3. Plists ----------
mkdir -p "$HOME/Library/LaunchAgents"

deploy_plist() {
    local label="$1"
    local script="$2"
    local plist_dst="$HOME/Library/LaunchAgents/$label.plist"
    local tmpl="/tmp/$label.plist.tmpl"

    curl -fsSL -o "$tmpl" "$BASE_URL/scripts/$label.plist" \
        || die "could not fetch $label.plist"
    sed \
        -e "s|__SCRIPT__|$script|g" \
        -e "s|__SYGEN_ROOT__|$SYGEN_ROOT|g" \
        -e "s|__HOME__|$HOME|g" \
        "$tmpl" > "$plist_dst"
    rm -f "$tmpl"
    chmod 0644 "$plist_dst"

    launchctl unload "$plist_dst" >/dev/null 2>&1 || true
    launchctl load -w "$plist_dst" \
        || die "launchctl load failed for $label"
    log "Loaded $label"
}

deploy_plist "com.sygen.host-updates-check" "$SYGEN_ROOT/bin/host_updates_check.sh"
deploy_plist "com.sygen.host-update-runner" "$SYGEN_ROOT/bin/host_update_runner.sh"

# ---------- 4. docker-compose.yml — add bind mount if missing ----------
COMPOSE="$SYGEN_ROOT/docker-compose.yml"
if [ -f "$COMPOSE" ]; then
    if grep -q '/data/host_updates:rw' "$COMPOSE"; then
        log "docker-compose.yml: host_updates bind mount already present"
    else
        log "docker-compose.yml: inserting host_updates bind mount"
        python3 - "$COMPOSE" "$SYGEN_ROOT" <<'PY'
import sys, pathlib

compose_path = pathlib.Path(sys.argv[1])
sygen_root = sys.argv[2]
text = compose_path.read_text()

# Anchor on the host_metrics.json mount which install.sh always inserts;
# we sit right after it, in the same `core` service volumes block.
needle = "/data/host_metrics.json:ro"
if needle not in text:
    print("FATAL: could not find host_metrics.json mount in docker-compose.yml; "
          "run a recent install first", file=sys.stderr)
    sys.exit(1)

lines = text.splitlines(keepends=True)
out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and needle in line:
        indent = line[: len(line) - len(line.lstrip())]
        out.append(f"{indent}- {sygen_root}/host_updates:/data/host_updates:rw\n")
        inserted = True

compose_path.write_text("".join(out))
PY
        log "Recreating sygen-core (docker compose up -d core)"
        docker compose -f "$COMPOSE" --env-file "$SYGEN_ROOT/.env" up -d core \
            || log "WARN: docker compose up failed — restart core manually"
    fi
fi

log "Done."
log "  Status:  launchctl list | grep host-update"
log "  Check:   cat $SYGEN_ROOT/host_updates/state.json"
log "  Logs:    tail -f $SYGEN_ROOT/logs/host-updates-check.log"
log "           tail -f $SYGEN_ROOT/logs/host-update-runner.log"
