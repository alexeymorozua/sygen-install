#!/usr/bin/env bash
# Sygen post-Colima startup wrapper. Invoked from pro.sygen.compose.plist
# at user login: polls `docker info` until the daemon is reachable
# (Colima may still be booting) and then runs `docker compose up -d`
# from $SYGEN_ROOT.
#
# Logs to $SYGEN_ROOT/logs/sygen-startup.{out,err}.
#
# Idempotent: `docker compose up -d` is a no-op when running containers
# already match the desired state, so racing an in-flight `install.sh`
# or a manually-started stack is harmless.
set -euo pipefail

SYGEN_ROOT="__SYGEN_ROOT__"
DOCKER_BIN="__DOCKER_BIN__"
DOCKER_TIMEOUT_SECS=60

log() { printf '[sygen-startup %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

if [ ! -f "$SYGEN_ROOT/docker-compose.yml" ]; then
    log "no docker-compose.yml at $SYGEN_ROOT — sygen probably uninstalled, exiting clean"
    exit 0
fi

# launchd hands us a minimal PATH. Add brew + system bins so the docker
# CLI plugin discovery (~/.docker/cli-plugins, brew prefix) works.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

log "waiting up to ${DOCKER_TIMEOUT_SECS}s for docker daemon"
waited=0
until "$DOCKER_BIN" info >/dev/null 2>&1; do
    if [ "$waited" -ge "$DOCKER_TIMEOUT_SECS" ]; then
        log "ERROR: docker daemon not reachable after ${DOCKER_TIMEOUT_SECS}s — giving up"
        exit 1
    fi
    sleep 2
    waited=$((waited + 2))
done
log "docker daemon ready (after ${waited}s)"

cd "$SYGEN_ROOT"
log "running: docker compose up -d"
"$DOCKER_BIN" compose up -d
log "compose stack started"
