#!/bin/bash
# Host-level self-uninstall runner for Sygen (v1.6.45+).
#
# bash (not sh) — uses `printf '%q'` for shell-safe path quoting in the
# wrapper heredoc; that's a bash extension. The script is macOS-only
# anyway (launchctl, plist), so depending on bash is safe.
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
    #
    # Cleanup of our own launchd agent + the host_update_runner agent
    # only fires when uninstall.sh actually succeeded — otherwise we'd
    # tear down the very mechanism the user needs to retry, leaving
    # them with a half-uninstalled host and no admin endpoint to fix
    # it from. On failure we leave the runner alive so the next admin
    # POST can try again.
    LOG_FILE="$SYGEN_ROOT/logs/uninstall.log"
    mkdir -p "$SYGEN_ROOT/logs" 2>/dev/null || true

    # Spawn uninstall.sh as a separate one-shot LaunchAgent. Detaching via
    # `nohup ... &` doesn't survive launchd killing this runner's job tree
    # on exit (especially with KeepAlive=true). A standalone agent is
    # isolated from this job and runs to completion regardless of our state.
    TEMP_PLIST="$SYGEN_ROOT/uninstall-once.plist"
    TEMP_LABEL="com.sygen.uninstall-once"
    ONESHOT_WRAPPER="$SYGEN_ROOT/uninstall-once-wrapper.sh"

    # Pre-quote every path embedded in the wrapper heredoc so a path
    # containing spaces or single-quotes can't break out of the literal.
    # printf '%q' emits shell-safe quoting that we drop directly into the
    # heredoc without surrounding quotes (the %q output already includes
    # whatever quoting it needs).
    QUOTED_UNINSTALL=$(printf '%q' "$UNINSTALL_SCRIPT")
    QUOTED_LOG=$(printf '%q' "$LOG_FILE")
    QUOTED_PLIST=$(printf '%q' "$PLIST_PATH")
    QUOTED_RUNNING=$(printf '%q' "$RUNNING")
    QUOTED_TEMP_PLIST=$(printf '%q' "$TEMP_PLIST")
    QUOTED_TEMP_WRAPPER=$(printf '%q' "$ONESHOT_WRAPPER")
    QUOTED_HOST_UPDATE_PLIST=$(printf '%q' "$HOME/Library/LaunchAgents/com.sygen.host-update-runner.plist")
    QUOTED_HOST_CHECK_PLIST=$(printf '%q' "$HOME/Library/LaunchAgents/com.sygen.host-updates-check.plist")

    # Wrapper handles success/failure cleanup AFTER uninstall.sh.
    cat > "$ONESHOT_WRAPPER" <<WRAPPER_EOF
#!/bin/bash
# Generated by host_uninstall_runner.sh — do not edit, will be removed by uninstall.sh.
exec >>${QUOTED_LOG} 2>&1
echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] [oneshot] starting bash ${QUOTED_UNINSTALL} $UNINSTALL_FLAGS"
if bash ${QUOTED_UNINSTALL} $UNINSTALL_FLAGS; then
    echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] [oneshot] uninstall.sh succeeded; tearing down sibling LaunchAgents"
    for plist in \\
        ${QUOTED_PLIST} \\
        ${QUOTED_HOST_UPDATE_PLIST} \\
        ${QUOTED_HOST_CHECK_PLIST}
    do
        [ -f "\$plist" ] && launchctl unload "\$plist" 2>/dev/null
        [ -f "\$plist" ] && rm -f "\$plist" 2>/dev/null
    done
    # Self-bootout — launchd will reap the plist itself, but we're explicit.
    launchctl bootout "gui/\$(id -u)/$TEMP_LABEL" 2>/dev/null
    rm -f ${QUOTED_TEMP_PLIST} ${QUOTED_TEMP_WRAPPER} 2>/dev/null
else
    echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] [oneshot] uninstall.sh exited non-zero — leaving runner agents loaded for retry"
    rm -f ${QUOTED_RUNNING} 2>/dev/null || true
    launchctl bootout "gui/\$(id -u)/$TEMP_LABEL" 2>/dev/null
    rm -f ${QUOTED_TEMP_PLIST} ${QUOTED_TEMP_WRAPPER} 2>/dev/null
fi
WRAPPER_EOF
    chmod +x "$ONESHOT_WRAPPER"

    cat > "$TEMP_PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$TEMP_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ONESHOT_WRAPPER</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST_EOF

    # Idempotency: clear any stale agent with the same label before
    # bootstrap. A duplicate POST or runner-restart-mid-uninstall could
    # otherwise leave the previous one-shot loaded, causing bootstrap to
    # fail with "service already loaded" and the new uninstall to never
    # fire. bootout returns non-zero when nothing to remove — that's fine.
    launchctl bootout "gui/$(id -u)/$TEMP_LABEL" 2>/dev/null || true

    # Bootstrap as gui/<uid> so it inherits user session env. Fall back to
    # load if bootstrap fails on older macOS.
    if ! launchctl bootstrap "gui/$(id -u)" "$TEMP_PLIST" 2>>"$LOG_FILE"; then
        log "bootstrap failed, falling back to launchctl load"
        launchctl load "$TEMP_PLIST" 2>>"$LOG_FILE" || \
            log "WARN: launchctl load also failed — uninstall may not run"
    fi

    # We do NOT clean up the running marker — uninstall.sh removes the
    # whole state dir as part of its own run. Returning here lets the
    # outer loop exit naturally; the one-shot LaunchAgent takes over.
    log "Uninstall handed off (one-shot agent $TEMP_LABEL bootstrapped) — exiting runner loop"
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
