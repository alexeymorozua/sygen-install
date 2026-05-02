#!/bin/bash
# Linux self-uninstall runner — pairs with /api/system/uninstall on core.
#
# Polls $SYGEN_ROOT/host_updates/uninstall_requested every 5 s. When admin
# POSTs to /api/system/uninstall, sygen-core writes that file with a small
# JSON body for forensics. This runner picks it up, atomically renames it
# to uninstall_running so duplicate POSTs cannot double-execute, then
# detaches and exec's uninstall.sh --force in a fresh session.
#
# Runs under systemd as root so it can stop/disable sygen-* services and
# remove unit files. After dispatching uninstall.sh the runner exits — its
# own systemd unit will be removed by uninstall.sh as part of the teardown.
#
# Usage:
#   sygen-host-uninstall-runner.sh                 # poll forever (default)
#   sygen-host-uninstall-runner.sh --once          # process one cycle (tests)
#   sygen-host-uninstall-runner.sh --interval 5    # poll cadence in seconds
#
# Env:
#   SYGEN_ROOT   override default state dir (/srv/sygen)

set -eu

LOG_PREFIX="[sygen-host-uninstall-runner]"
log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }

INTERVAL=5
RUN_ONCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --interval)
            shift
            INTERVAL="${1:-5}"
            ;;
        --once)
            RUN_ONCE=1
            ;;
        *)
            ;;
    esac
    shift || true
done

SYGEN_ROOT="${SYGEN_ROOT:-/srv/sygen}"
STATE_DIR="$SYGEN_ROOT/host_updates"
TRIGGER="$STATE_DIR/uninstall_requested"
RUNNING="$STATE_DIR/uninstall_running"
UNINSTALL_SCRIPT="$SYGEN_ROOT/uninstall.sh"

mkdir -p "$STATE_DIR" "$SYGEN_ROOT/logs"

process_trigger() {
    local body
    body="$(cat "$TRIGGER" 2>/dev/null || true)"

    # Atomic claim — rename to running so a duplicate runner instance
    # (or duplicate POST) can't double-execute.
    if ! mv "$TRIGGER" "$RUNNING" 2>/dev/null; then
        return 0
    fi

    log "Uninstall trigger received (body=${body:-empty})"

    if [ ! -f "$UNINSTALL_SCRIPT" ]; then
        log "FATAL: $UNINSTALL_SCRIPT not found — clearing marker"
        rm -f "$RUNNING" 2>/dev/null || true
        return 0
    fi

    local log_file="$SYGEN_ROOT/logs/uninstall.log"
    log "Spawning detached uninstall: bash $UNINSTALL_SCRIPT --force (log: $log_file)"

    # setsid + nohup + & to fully detach. The uninstall script will
    # `systemctl disable --now sygen-host-uninstall-runner.service`
    # mid-run, which kills *us*, but the detached uninstall.sh keeps
    # running because it's in a new session group and not parented by
    # our systemd unit anymore.
    setsid nohup bash "$UNINSTALL_SCRIPT" --force \
        >> "$log_file" 2>&1 < /dev/null &
    disown || true

    log "Uninstall dispatched — runner exiting (will be torn down by uninstall.sh)"
    exit 0
}

log "Starting (SYGEN_ROOT=$SYGEN_ROOT, interval=${INTERVAL}s, once=$RUN_ONCE)"
while true; do
    if [ -f "$TRIGGER" ]; then
        process_trigger
    fi
    if [ "$RUN_ONCE" = "1" ]; then
        break
    fi
    sleep "$INTERVAL"
done
