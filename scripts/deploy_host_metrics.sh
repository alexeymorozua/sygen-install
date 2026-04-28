#!/usr/bin/env bash
# Hot-deploy the host_metrics_daemon onto an existing Sygen install
# without re-running install.sh.
#
# Detects macOS (Colima) vs Linux, installs the daemon + plist/systemd
# unit, edits docker-compose.yml in place to add the bind mount (if not
# already present), then `docker compose up -d core` so the new mount
# takes effect.
#
# Idempotent: safe to re-run after partial failures.
#
# Usage:
#   curl -fsSL https://install.sygen.pro/scripts/deploy_host_metrics.sh | bash
# Or:
#   bash deploy_host_metrics.sh
set -euo pipefail

BASE_URL="${SYGEN_INSTALL_BASE_URL:-https://raw.githubusercontent.com/alexeymorozua/sygen-install/main}"

OS="$(uname -s)"
case "$OS" in
    Darwin)
        SYGEN_ROOT="${SYGEN_ROOT:-$HOME/.sygen-local}"
        IS_MACOS=1
        ;;
    Linux)
        SYGEN_ROOT="${SYGEN_ROOT:-/srv/sygen}"
        IS_MACOS=0
        ;;
    *)
        echo "Unsupported OS: $OS" >&2
        exit 1
        ;;
esac

log() { printf '[deploy-host-metrics] %s\n' "$*"; }
die() { printf '[deploy-host-metrics] ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$SYGEN_ROOT" ] || die "$SYGEN_ROOT not found — is Sygen installed?"
[ -f "$SYGEN_ROOT/docker-compose.yml" ] || die "$SYGEN_ROOT/docker-compose.yml not found"

PYTHON_BIN="$(command -v python3 || true)"
[ -z "$PYTHON_BIN" ] && die "python3 not found"

# ---------- 1. Daemon script ----------
mkdir -p "$SYGEN_ROOT/bin" "$SYGEN_ROOT/logs"
log "Fetching host_metrics_daemon.py"
curl -fsSL -o "$SYGEN_ROOT/bin/host_metrics_daemon.py" \
    "$BASE_URL/scripts/host_metrics_daemon.py" \
    || die "could not fetch host_metrics_daemon.py"
chmod 0755 "$SYGEN_ROOT/bin/host_metrics_daemon.py"

# Touch metrics file so the bind mount has a real file (Docker turns a
# missing bind source into a directory, which breaks the mount).
touch "$SYGEN_ROOT/host_metrics.json"
chmod 0644 "$SYGEN_ROOT/host_metrics.json"

# ---------- 2. Service unit ----------
if [ $IS_MACOS -eq 1 ]; then
    PLIST_DST="$HOME/Library/LaunchAgents/com.sygen.host-metrics.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    log "Installing launchd plist → $PLIST_DST"
    curl -fsSL -o /tmp/sygen.host-metrics.plist.tmpl \
        "$BASE_URL/scripts/com.sygen.host-metrics.plist" \
        || die "could not fetch plist template"
    sed \
        -e "s|__PYTHON__|$PYTHON_BIN|g" \
        -e "s|__SCRIPT__|$SYGEN_ROOT/bin/host_metrics_daemon.py|g" \
        -e "s|__SYGEN_ROOT__|$SYGEN_ROOT|g" \
        /tmp/sygen.host-metrics.plist.tmpl > "$PLIST_DST"
    rm -f /tmp/sygen.host-metrics.plist.tmpl
    launchctl unload "$PLIST_DST" >/dev/null 2>&1 || true
    launchctl load -w "$PLIST_DST" \
        || die "launchctl load failed"
    log "launchd agent loaded"
else
    UNIT_DST="/etc/systemd/system/sygen-host-metrics.service"
    log "Installing systemd unit → $UNIT_DST (sudo required)"
    SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        SUDO="sudo"
    fi
    curl -fsSL -o /tmp/sygen-host-metrics.service.tmpl \
        "$BASE_URL/scripts/sygen-host-metrics.service" \
        || die "could not fetch systemd unit template"
    sed \
        -e "s|__PYTHON__|$PYTHON_BIN|g" \
        -e "s|__SCRIPT__|$SYGEN_ROOT/bin/host_metrics_daemon.py|g" \
        -e "s|__SYGEN_ROOT__|$SYGEN_ROOT|g" \
        /tmp/sygen-host-metrics.service.tmpl > /tmp/sygen-host-metrics.service.rendered
    $SUDO mv /tmp/sygen-host-metrics.service.rendered "$UNIT_DST"
    rm -f /tmp/sygen-host-metrics.service.tmpl
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now sygen-host-metrics.service
    log "systemd unit started"
fi

# ---------- 3. docker-compose.yml — add bind mount if missing ----------
COMPOSE="$SYGEN_ROOT/docker-compose.yml"
if grep -q '/data/host_metrics.json' "$COMPOSE"; then
    log "docker-compose.yml: bind mount already present"
else
    log "docker-compose.yml: inserting host_metrics.json bind mount"
    # Insert after the claude-auth volume line in the core service. Match
    # both /srv/sygen (Linux/auto) and the SYGEN_ROOT-rewritten local form.
    python3 - "$COMPOSE" "$SYGEN_ROOT" <<'PY'
import sys
import pathlib

compose_path = pathlib.Path(sys.argv[1])
sygen_root = sys.argv[2]
text = compose_path.read_text()

needle = "/home/sygen/.claude"
if needle not in text:
    print("FATAL: could not find claude-auth mount in docker-compose.yml", file=sys.stderr)
    sys.exit(1)

# Find the line containing the claude-auth volume and insert after it.
lines = text.splitlines(keepends=True)
out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and needle in line:
        indent = line[: len(line) - len(line.lstrip())]
        out.append(f"{indent}- {sygen_root}/host_metrics.json:/data/host_metrics.json:ro\n")
        inserted = True

compose_path.write_text("".join(out))
PY
fi

# ---------- 4. Recreate core so the new mount takes effect ----------
log "Recreating sygen-core (docker compose up -d core)"
docker compose -f "$COMPOSE" --env-file "$SYGEN_ROOT/.env" up -d core

log "Done. Wait ~10 s for the daemon to populate $SYGEN_ROOT/host_metrics.json,"
log "then check the dashboard — CPU/RAM/disk USED should now reflect the host."
