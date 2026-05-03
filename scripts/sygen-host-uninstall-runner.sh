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

    # Detach from our systemd cgroup. setsid+nohup+disown was not
    # enough on production VPS: when sygen-host-uninstall-runner.service
    # exited (or got cleaned up by the uninstall.sh's `systemctl disable
    # --now`), systemd cgroup cleanup killed the descendant uninstall.sh
    # too, leaving uninstall.log empty (0 bytes) and the host half-clean.
    #
    # Preferred: systemd-run --scope --no-block puts the child in its
    # own transient unit / cgroup so it survives our death entirely.
    # Fallback: setsid double-fork — re-fork from a detached subshell so
    # the grandchild has init (PID 1) as its parent. Standard daemonise
    # trick; works without systemd-run.
    local unit_name="sygen-uninstall-$$-${RANDOM}"
    if command -v systemd-run >/dev/null 2>&1; then
        log "Using systemd-run --scope (unit: ${unit_name}) — output in journal + $log_file"
        # --collect = drop the unit immediately when uninstall.sh exits.
        # --property=KillMode=process so we don't kill children that
        #   uninstall.sh itself spawns (apt, systemctl, etc.) when the
        #   unit eventually closes.
        # Tee output to log_file so existing log-tailing tooling (admin
        # uninstall progress UI) keeps working in parallel with journal.
        systemd-run \
            --unit="$unit_name" \
            --scope \
            --no-block \
            --collect \
            --property=KillMode=process \
            bash -c "exec bash '$UNINSTALL_SCRIPT' --force >>'$log_file' 2>&1 </dev/null" \
            >/dev/null 2>&1 \
            || {
                warn "systemd-run dispatch failed — falling back to setsid double-fork"
                _spawn_setsid_double_fork "$log_file"
            }
    else
        log "systemd-run unavailable — using setsid double-fork"
        _spawn_setsid_double_fork "$log_file"
    fi

    log "Uninstall dispatched — runner exiting (will be torn down by uninstall.sh)"
    exit 0
}

# Double-fork detach. Outer subshell forks the inner setsid bash and
# exits, so the grandchild gets reparented to init (PID 1) and is no
# longer in our systemd cgroup. Used as a fallback when systemd-run is
# not available.
_spawn_setsid_double_fork() {
    local log_file="$1"
    (
        setsid bash -c "
            exec </dev/null
            exec >>'$log_file' 2>&1
            bash '$UNINSTALL_SCRIPT' --force
        " &
        disown || true
    )
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
