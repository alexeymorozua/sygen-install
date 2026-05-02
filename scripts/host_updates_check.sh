#!/bin/sh
# Host-level update checker for Sygen.
#
# Runs `brew outdated --json=v2`, filters the result to the allowlist of
# packages that install.sh actually installs, and writes a structured
# JSON state file at $SYGEN_ROOT/host_updates/state.json. The core
# container bind-mounts $SYGEN_ROOT/host_updates as /data/host_updates:rw
# so the file becomes available at /data/host_updates/state.json and the
# runner can pick up the trigger file at /data/host_updates/requested
# that core writes from inside the container.
#
# Designed to be:
#   - POSIX /bin/sh (no bashisms; runs from a launchd plist that does
#     not source the user's shell rc)
#   - No-op on hosts without Homebrew (writes supported:false once)
#   - Idempotent (atomic temp + rename, 0644 perms)
#
# Usage:
#   host_updates_check.sh           # one-shot check, exit 0 on success
#   host_updates_check.sh --output /custom/path/state.json
#
# Env:
#   SYGEN_ROOT          override default state dir ($HOME/.sygen-local)
#   SYGEN_HOST_PKGS     space-separated allowlist override (debug only)
#
# Exit codes:
#   0  success (file written)
#   1  unrecoverable error (invalid output path)

set -eu

LOG_PREFIX="[host-updates-check]"
log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }

# ---------- Resolve paths ----------
if [ -z "${SYGEN_ROOT:-}" ]; then
    if [ -d "$HOME/.sygen-local" ]; then
        SYGEN_ROOT="$HOME/.sygen-local"
    elif [ -d /srv/sygen ]; then
        SYGEN_ROOT=/srv/sygen
    else
        SYGEN_ROOT="$HOME/.sygen-local"
    fi
fi

OUTPUT="$SYGEN_ROOT/host_updates/state.json"
while [ $# -gt 0 ]; do
    case "$1" in
        --output)
            shift
            OUTPUT="${1:-}"
            ;;
        --once)
            # Accepted for parity with the metrics daemon. We're
            # always one-shot.
            ;;
        *)
            ;;
    esac
    shift || true
done

if [ -z "$OUTPUT" ]; then
    log "ERROR: --output requires a path"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

# Allowlist of packages install.sh actually installs (or knows how to
# upgrade safely). Keep in sync with the same list in
# sygen_bot/api/rest_routes.py — a wider set on either side leaks scope.
ALLOWLIST="${SYGEN_HOST_PKGS:-python@3.14 node@22 nginx certbot jq openssl tailscale whisper-cpp pipx}"

now_utc() {
    # POSIX-portable ISO 8601 UTC timestamp (no fractional seconds).
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

write_atomic() {
    # $1 = body
    tmp="$OUTPUT.tmp.$$"
    printf '%s' "$1" > "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    mv "$tmp" "$OUTPUT"
}

# ---------- No Homebrew → write a stub and exit 0 ----------
BREW_BIN="$(command -v brew 2>/dev/null || true)"
if [ -z "$BREW_BIN" ]; then
    log "Homebrew not installed — writing supported:false stub"
    write_atomic "$(printf '{"supported":false,"checked_at":"%s","reason":"brew not installed"}\n' "$(now_utc)")"
    exit 0
fi

JQ_BIN="$(command -v jq 2>/dev/null || true)"
if [ -z "$JQ_BIN" ]; then
    # We need jq to parse brew's JSON. install.sh installs it as part of
    # the allowlist anyway; on a host where it's missing, surface that
    # clearly without crashing — the file is still useful as a stub.
    log "jq not found — writing supported:false stub (install jq first)"
    write_atomic "$(printf '{"supported":false,"checked_at":"%s","reason":"jq not installed"}\n' "$(now_utc)")"
    exit 0
fi

# ---------- Run brew outdated ----------
# `brew outdated --json=v2` returns a stable JSON shape with a `formulae`
# array. Each entry has:
#   { "name": "colima",
#     "installed_versions": ["0.6.0"],
#     "current_version": "0.6.1",
#     "pinned": false,
#     "pinned_version": null }
# We tolerate brew failing (network down) by writing a stub with
# available:false and leaving the consumer to retry next interval.
BREW_OUT="$(/usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 "$BREW_BIN" outdated --json=v2 2>/dev/null || true)"
if [ -z "$BREW_OUT" ]; then
    log "brew outdated returned empty / failed — writing available:false stub"
    write_atomic "$(printf '{"supported":true,"available":false,"count":0,"packages":[],"checked_at":"%s","reason":"brew outdated failed"}\n' "$(now_utc)")"
    exit 0
fi

# Build a jq filter that:
#   1. Pulls the formulae array
#   2. Keeps only entries whose name is in the allowlist
#   3. Reshapes to { name, current, latest }
ALLOWLIST_JSON="$(printf '%s' "$ALLOWLIST" | tr ' ' '\n' | "$JQ_BIN" -R . | "$JQ_BIN" -s .)"

PACKAGES_JSON="$(printf '%s' "$BREW_OUT" \
    | "$JQ_BIN" --argjson allow "$ALLOWLIST_JSON" '
        (.formulae // [])
        | map(select(.name as $n | $allow | index($n)))
        | map({
            name: .name,
            current: ((.installed_versions // []) | join(",")),
            latest: (.current_version // "")
          })
    ' 2>/dev/null || echo '[]')"

if [ -z "$PACKAGES_JSON" ] || [ "$PACKAGES_JSON" = "null" ]; then
    PACKAGES_JSON='[]'
fi

COUNT="$(printf '%s' "$PACKAGES_JSON" | "$JQ_BIN" 'length' 2>/dev/null || echo 0)"
AVAILABLE=false
if [ "${COUNT:-0}" -gt 0 ]; then
    AVAILABLE=true
fi

CHECKED_AT="$(now_utc)"
BODY="$(printf '%s' "$PACKAGES_JSON" | "$JQ_BIN" \
    --arg checked_at "$CHECKED_AT" \
    --argjson available "$AVAILABLE" \
    --argjson count "$COUNT" \
    '{supported:true, available:$available, count:$count, packages:., checked_at:$checked_at}' 2>/dev/null || true)"

if [ -z "$BODY" ]; then
    log "ERROR: jq failed to render output"
    exit 1
fi

write_atomic "$BODY"
log "Wrote $OUTPUT (count=$COUNT, available=$AVAILABLE)"
