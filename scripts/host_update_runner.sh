#!/bin/sh
# Host-level update runner for Sygen.
#
# Polls a trigger file at $SYGEN_ROOT/host_updates/requested every 5 s.
# When admin POSTs to /api/system/host-updates/apply the core container
# writes that file with a JSON body listing packages to upgrade. This
# script claims the trigger atomically (rename to running), runs
# `brew upgrade <pkgs>`, refreshes the check file, and writes the
# outcome to $SYGEN_ROOT/host_updates/result.json.
#
# Designed to be run from a launchd plist with KeepAlive=true so it
# always sits idle waiting for the trigger.
#
# Allowlist enforcement is double-fenced (core validates, runner
# re-validates) so an attacker who got write access to the trigger file
# without going through core can still only run the same 7 brew
# upgrades that the documented apply flow accepts.
#
# Usage:
#   host_update_runner.sh                 # run forever
#   host_update_runner.sh --once          # process one cycle (for tests)
#   host_update_runner.sh --interval 5    # poll cadence in seconds
#
# Env:
#   SYGEN_ROOT         override default state dir ($HOME/.sygen-local)
#   SYGEN_HOST_PKGS    space-separated allowlist override (debug only)

set -eu

LOG_PREFIX="[host-update-runner]"
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

TRIGGER="$STATE_DIR/requested"
RUNNING="$STATE_DIR/running"
RESULT="$STATE_DIR/result.json"
CHECK_SCRIPT="$SYGEN_ROOT/bin/host_updates_check.sh"

ALLOWLIST="${SYGEN_HOST_PKGS:-colima nginx certbot docker jq openssl tailscale whisper-cpp}"

now_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

write_atomic() {
    # $1 = path, $2 = body
    tmp="$1.tmp.$$"
    printf '%s' "$2" > "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    mv "$tmp" "$1"
}

is_in_allowlist() {
    needle="$1"
    for p in $ALLOWLIST; do
        if [ "$p" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

filter_to_allowlist() {
    out=""
    for p in $1; do
        if is_in_allowlist "$p"; then
            out="$out $p"
        fi
    done
    printf '%s' "${out# }"
}

# ---------- Single-cycle apply ----------
process_trigger() {
    BREW_BIN="$(command -v brew 2>/dev/null || true)"
    if [ -z "$BREW_BIN" ]; then
        log "brew not installed — refusing apply, removing trigger"
        rm -f "$TRIGGER" 2>/dev/null || true
        return 0
    fi

    JQ_BIN="$(command -v jq 2>/dev/null || true)"

    BODY="$(cat "$TRIGGER" 2>/dev/null || true)"

    # Atomic claim — rename to running so a parallel runner instance
    # (and a duplicate POST in flight) can't double-execute.
    if ! mv "$TRIGGER" "$RUNNING" 2>/dev/null; then
        return 0
    fi

    STARTED_AT="$(now_utc)"
    log "Apply started at $STARTED_AT (body=${BODY:-empty})"

    PACKAGES=""
    if [ -n "$BODY" ] && [ -n "$JQ_BIN" ]; then
        PACKAGES="$(printf '%s' "$BODY" | "$JQ_BIN" -r '
            if type == "object" and (.packages | type) == "array" then
                .packages | map(strings) | join(" ")
            else "" end
        ' 2>/dev/null || true)"
    fi
    PACKAGES="$(filter_to_allowlist "$PACKAGES")"

    if [ -z "$PACKAGES" ]; then
        # Empty list = upgrade every allowlist member that's currently
        # outdated. Compute that list now.
        if [ -n "$JQ_BIN" ]; then
            ALLOW_JSON="$(printf '%s' "$ALLOWLIST" | tr ' ' '\n' | "$JQ_BIN" -R . | "$JQ_BIN" -s .)"
            OUTDATED="$(/usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 "$BREW_BIN" outdated --json=v2 2>/dev/null \
                | "$JQ_BIN" --argjson allow "$ALLOW_JSON" -r '
                    (.formulae // [])
                    | map(select(.name as $n | $allow | index($n)))
                    | map(.name) | join(" ")
                ' 2>/dev/null || true)"
            PACKAGES="$OUTDATED"
        fi
    fi

    LOG_TEXT=""
    OK="false"
    TOP_ERROR=""
    FAILED_JSON="[]"
    if [ -z "$PACKAGES" ]; then
        log "No packages in scope — nothing to upgrade"
        LOG_TEXT="no allowlisted packages outdated"
        OK="true"
    else
        log "Running: brew upgrade $PACKAGES"
        TMP_LOG="$(mktemp -t sygen_brew_log.XXXXXX 2>/dev/null || mktemp 2>/dev/null || echo "/tmp/sygen_brew_log.$$")"
        # Build positional args from the (allowlist-validated) package
        # list so brew never sees a single string argument that could be
        # split on shell metacharacters. Defence-in-depth even if the
        # allowlist stays clean.
        set --
        for p in $PACKAGES; do
            set -- "$@" "$p"
        done
        if /usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 "$BREW_BIN" upgrade "$@" \
                > "$TMP_LOG" 2>&1; then
            OK="true"
        else
            OK="false"
        fi
        LOG_TEXT="$(tail -c 32768 "$TMP_LOG" 2>/dev/null || true)"

        # Parse per-package failures from the log so the modal can show
        # which entries broke. Patterns we look for (brew is consistent
        # but verbose):
        #   "Error: <pkg>: ..."
        #   "Error: Failure while executing; `... <pkg> ...` exited"
        #   "<pkg> failed to install"
        if [ "$OK" = "false" ] && [ -n "$JQ_BIN" ] && [ -f "$TMP_LOG" ]; then
            FAILED_JSON_TMP="["
            FIRST=1
            for p in $PACKAGES; do
                # Defensive: package names that contain regex metacharacters
                # would break the grep below (or worse, match unrelated lines).
                # Allowlist alphanumerics + dash/underscore/dot — that covers
                # every brew formula and apt package we ship today.
                case "$p" in
                    *[!a-zA-Z0-9_.-]*) continue ;;
                esac
                ERR_LINE="$(grep -E "Error: ($p:|.*$p.* failed to install|Failure.*$p)" "$TMP_LOG" 2>/dev/null | head -n 1 || true)"
                if [ -n "$ERR_LINE" ]; then
                    if [ $FIRST -eq 0 ]; then
                        FAILED_JSON_TMP="$FAILED_JSON_TMP,"
                    fi
                    FIRST=0
                    ENTRY="$("$JQ_BIN" -n --arg name "$p" --arg error "$ERR_LINE" '{name:$name, error:$error}' 2>/dev/null || echo '')"
                    if [ -n "$ENTRY" ]; then
                        FAILED_JSON_TMP="$FAILED_JSON_TMP$ENTRY"
                    fi
                fi
            done
            FAILED_JSON_TMP="$FAILED_JSON_TMP]"
            # Validate the assembled JSON via jq; fall back to [] on parse error.
            FAILED_JSON="$(printf '%s' "$FAILED_JSON_TMP" | "$JQ_BIN" -c . 2>/dev/null || echo '[]')"

            FAILED_COUNT="$(printf '%s' "$FAILED_JSON" | "$JQ_BIN" 'length' 2>/dev/null || echo 0)"
            if [ "${FAILED_COUNT:-0}" -eq 0 ]; then
                # Overall failure with no per-package detail → surface a
                # top-level reason from the tail of the log.
                TOP_ERROR="$(printf '%s' "$LOG_TEXT" | grep -E '^Error:' | tail -n 1 || true)"
                if [ -z "$TOP_ERROR" ]; then
                    TOP_ERROR="brew upgrade failed (see log)"
                fi
            fi
        fi

        rm -f "$TMP_LOG" 2>/dev/null || true

        # Special-case: if Colima was upgraded, restart it cleanly so
        # the new binary actually takes effect. Reuses the persisted
        # Colima profile (no re-derivation of original `colima start`
        # flags here — that's stored in ~/.colima/_lima/...).
        case " $PACKAGES " in
            *" colima "*)
                if command -v colima >/dev/null 2>&1; then
                    log "Restarting Colima to pick up new binary"
                    colima stop >/dev/null 2>&1 || true
                    colima start >/dev/null 2>&1 || \
                        log "WARNING: colima start failed — restart it manually"
                fi
                ;;
        esac
    fi

    # Always refresh state.json so the banner doesn't stick if the
    # standalone check daemon is missing. Write a minimal
    # "nothing-outdated" stub first; if the proper check script is
    # available it will overwrite with the real list.
    STATE_FILE="$STATE_DIR/state.json"
    NOW_TS="$(now_utc)"
    DEFAULT_STATE="{\"supported\":true,\"available\":false,\"count\":0,\"packages\":[],\"checked_at\":\"$NOW_TS\"}"
    write_atomic "$STATE_FILE" "$DEFAULT_STATE"
    if [ -x "$CHECK_SCRIPT" ]; then
        "$CHECK_SCRIPT" >/dev/null 2>&1 || true
    fi

    REMAINING="[]"
    if [ -n "$JQ_BIN" ] && [ -f "$STATE_FILE" ]; then
        REMAINING="$("$JQ_BIN" -c '.packages // []' "$STATE_FILE" 2>/dev/null || echo '[]')"
    fi

    FINISHED_AT="$(now_utc)"

    RESULT_BODY=""
    if [ -n "$JQ_BIN" ]; then
        RESULT_BODY="$("$JQ_BIN" -n \
            --arg started_at "$STARTED_AT" \
            --arg finished_at "$FINISHED_AT" \
            --argjson ok "$OK" \
            --arg packages "$PACKAGES" \
            --arg log "$LOG_TEXT" \
            --arg top_error "$TOP_ERROR" \
            --argjson failed "$FAILED_JSON" \
            --argjson remaining "$REMAINING" \
            '{started_at:$started_at,
              finished_at:$finished_at,
              ok:$ok,
              packages:($packages | split(" ") | map(select(. != ""))),
              failed:$failed,
              error:(if $top_error == "" then null else $top_error end),
              log:$log,
              remaining_packages:$remaining}' 2>/dev/null || true)"
    fi
    if [ -z "$RESULT_BODY" ]; then
        RESULT_BODY="{\"started_at\":\"$STARTED_AT\",\"finished_at\":\"$FINISHED_AT\",\"ok\":$OK,\"failed\":[],\"error\":null,\"log\":\"\",\"remaining_packages\":[]}"
    fi
    write_atomic "$RESULT" "$RESULT_BODY"

    rm -f "$RUNNING" 2>/dev/null || true
    log "Apply finished at $FINISHED_AT (ok=$OK)"
}

# ---------- Loop ----------
log "Starting (interval=${INTERVAL}s, trigger=$TRIGGER)"

# Recover from a crash mid-apply: if a stale running marker exists at
# startup with no trigger, just clear it. We can't tell whether the
# upgrade completed; the next admin click will resync.
if [ -f "$RUNNING" ] && [ ! -f "$TRIGGER" ]; then
    log "Stale running marker on startup — clearing"
    rm -f "$RUNNING" 2>/dev/null || true
fi

while :; do
    if [ -f "$TRIGGER" ]; then
        process_trigger
    fi
    if [ "$RUN_ONCE" -eq 1 ]; then
        break
    fi
    sleep "$INTERVAL"
done
