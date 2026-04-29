#!/bin/sh
# Host-level self-uninstall runner for Sygen (v1.6.45+).
#
# Sibling of host_update_runner.sh — same trigger-file architecture.
# Polls $SYGEN_ROOT/host_updates/uninstall_requested every 5 s; when
# admin POSTs to /api/system/uninstall the core container writes that
# file with a small JSON body for forensics (requested_at / requested_by).
#
# When the trigger appears:
#   1. Atomically rename to uninstall_running so a parallel runner /
#      duplicate POST cannot double-execute.
#   2. Disown into a detached subshell and exec `uninstall.sh --force`.
#      The runner script itself is about to be deleted along with
#      $SYGEN_ROOT/bin, so we cannot keep waiting on the child —
#      fire-and-forget is the correct shape here.
#   3. The detached child runs uninstall.sh, which now reads the
#      install manifest at $SYGEN_ROOT/.install_manifest.json (if
#      present) to drive what gets removed (brew packages, Colima VM,
#      launchd agents). Pre-1.6.46 installs without a manifest fall
#      back to a minimum-safe cleanup.
#
# v1.6.46+ note: the legacy delete_vm / keep_brew JSON fields are
# IGNORED here — the manifest is the single source of truth. The body
# is still read+logged for audit/forensics but nothing in it is acted on.
#
# Designed for KeepAlive=true under launchd. We do NOT write
# result.json — by the time the uninstall completes the bind-mounted
# state directory no longer exists, so any write would land in a
# detached folder no client can read. The frontend already knows the
# server is going down (admin/iOS clients show "uninstall queued").
#
# Usage:
#   host_uninstall_runner.sh                 # run forever
#   host_uninstall_runner.sh --once          # process one cycle (tests)
#   host_uninstall_runner.sh --interval 5    # poll cadence in seconds
#
# Env:
#   SYGEN_ROOT   override default state dir ($HOME/.sygen-local)

set -eu

LOG_PREFIX="[host-uninstall-runner]"
log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }

# ---------- Args ----------
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

# ---------- Paths ----------
if [ -z "${SYGEN_ROOT:-}" ]; then
    if [ -d "$HOME/.sygen-local" ]; then
        SYGEN_ROOT="$HOME/.sygen-local"
    elif [ -d /srv/sygen ]; then
        SYGEN_ROOT=/srv/sygen
    else
        SYGEN_ROOT="$HOME/.sygen-local"
    fi
fi

STATE_DIR="$SYGEN_ROOT/host_updates"
mkdir -p "$STATE_DIR"

TRIGGER="$STATE_DIR/uninstall_requested"
RUNNING="$STATE_DIR/uninstall_running"
UNINSTALL_SCRIPT="$SYGEN_ROOT/uninstall.sh"
LAUNCHD_LABEL="com.sygen.host-uninstall-runner"
PLIST_PATH="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

# ---------- Single-cycle apply ----------
process_trigger() {
    BODY="$(cat "$TRIGGER" 2>/dev/null || true)"

    # Atomic claim — rename to running so a duplicate runner instance
    # (or duplicate POST) can't double-execute.
    if ! mv "$TRIGGER" "$RUNNING" 2>/dev/null; then
        return 0
    fi

    log "Uninstall trigger received (body=${BODY:-empty})"

    if [ ! -x "$UNINSTALL_SCRIPT" ] && [ ! -f "$UNINSTALL_SCRIPT" ]; then
        log "FATAL: $UNINSTALL_SCRIPT not found — clearing marker"
        rm -f "$RUNNING" 2>/dev/null || true
        return 0
    fi

    # v1.6.46+: --force is the only flag we pass. uninstall.sh reads
    # $SYGEN_ROOT/.install_manifest.json to decide what to remove.
    UNINSTALL_FLAGS="--force"

    log "Spawning detached uninstall: bash $UNINSTALL_SCRIPT $UNINSTALL_FLAGS"

    # Detach uninstall into its own session so it survives this
    # runner's death (uninstall.sh wipes $SYGEN_ROOT, which contains
    # this very script). Output goes to a sibling log.
    LOG_FILE="$SYGEN_ROOT/logs/uninstall.log"
    mkdir -p "$SYGEN_ROOT/logs" 2>/dev/null || true
    # shellcheck disable=SC2086 -- intentional word-splitting on $UNINSTALL_FLAGS
    nohup sh -c "
        bash '$UNINSTALL_SCRIPT' $UNINSTALL_FLAGS >>'$LOG_FILE' 2>&1
        # After uninstall.sh, our own launchd agent + plist must go too.
        launchctl unload '$PLIST_PATH' >/dev/null 2>&1 || true
        rm -f '$PLIST_PATH' 2>/dev/null || true
        # And the host_update_runner agent (it lives in the same
        # directory hierarchy that uninstall.sh wiped, so its launchd
        # entry is now pointing at a missing script).
        launchctl unload '$HOME/Library/LaunchAgents/com.sygen.host-update-runner.plist' >/dev/null 2>&1 || true
        rm -f '$HOME/Library/LaunchAgents/com.sygen.host-update-runner.plist' 2>/dev/null || true
        launchctl unload '$HOME/Library/LaunchAgents/com.sygen.host-updates-check.plist' >/dev/null 2>&1 || true
        rm -f '$HOME/Library/LaunchAgents/com.sygen.host-updates-check.plist' 2>/dev/null || true
    " </dev/null >/dev/null 2>&1 &

    # We do NOT clean up the running marker — uninstall.sh removes the
    # whole state dir as part of its own run. Returning here lets the
    # outer loop exit naturally; the detached child takes over.
    log "Uninstall handed off (PID=$!) — exiting runner loop"
    return 0
}

# ---------- Loop ----------
log "Starting (interval=${INTERVAL}s, trigger=$TRIGGER)"

# Recover from a crash mid-uninstall: if a stale uninstall_running
# marker is on disk with no trigger, just clear it. We can't tell
# whether the previous attempt completed; the next admin click will
# resync (or, more likely, the host is already gone and this runner
# only loaded again because launchd restarted us during a flapping
# state — in which case clearing the marker is safe).
if [ -f "$RUNNING" ] && [ ! -f "$TRIGGER" ]; then
    log "Stale uninstall_running marker on startup — clearing"
    rm -f "$RUNNING" 2>/dev/null || true
fi

while :; do
    if [ -f "$TRIGGER" ]; then
        process_trigger
        # Once we hand off to uninstall.sh the host is going away;
        # there's nothing useful left to poll for, so break the loop
        # so launchd's KeepAlive doesn't spin idle CPU. The plist
        # itself will get unloaded by the detached child.
        break
    fi
    if [ "$RUN_ONCE" -eq 1 ]; then
        break
    fi
    sleep "$INTERVAL"
done
