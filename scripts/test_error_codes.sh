#!/usr/bin/env bash
# scripts/test_error_codes.sh — verify install.sh structured error JSON.
#
# Unit-tests the emit_error / emit_json_error pair by extracting the
# relevant helper blocks from install.sh into a hermetic shim and
# asserting the JSON payload shape against the contract documented in
# README.md under "Error codes".
#
# Run from the repo root:    bash scripts/test_error_codes.sh
# Exit status: 0 = all pass, non-zero = failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
[ -f "$INSTALL_SH" ] || { echo "install.sh not found at $INSTALL_SH" >&2; exit 2; }

FAIL=0
PASS=0

# Build a hermetic shim containing only the JSON-error machinery we want
# to test. Sourcing the whole install.sh would trigger the platform
# detection block (OS-specific die() calls) before we ever reached the
# assertion. Extract:
#   - json_escape() — bash-only string escaper
#   - ERROR_CODE / FIX_COMMAND / FIX_DOCS_URL — emit_error / die / emit_json_error
#   - emit_json_error()
#   - _release_and_die() — its JSON branch is also tested here so the
#     err_code → human-`error`-field mapping doesn't regress.
SHIM_FILE="$(mktemp)"
trap 'rm -f "$SHIM_FILE"' EXIT

cat >"$SHIM_FILE" <<'SHIM_PREAMBLE'
# Minimum prologue: STAGE + log/warn/die contract identical to install.sh.
JSON_OUTPUT="${SYGEN_JSON_OUTPUT:-0}"
JSON_DONE=0
STAGE="init"
# _release_and_die touches DOMAIN/FQDN/SYGEN_INSTALL_TOKEN; stub them so
# the release/cleanup branches are skipped in unit tests.
SYGEN_INSTALL_TOKEN=""
FQDN=""
log()  { :; }
warn() { :; }
die()  {
    printf 'XX %s\n' "$*" >&2
    if [ "$JSON_OUTPUT" = "1" ] && [ "$JSON_DONE" = "0" ]; then
        emit_json_error "$*"
    fi
    exit 1
}
SHIM_PREAMBLE

# Append the helper blocks straight out of install.sh so the test
# tracks any future edits automatically.
awk '
    /^json_escape\(\) \{$/         { in_fn=1 }
    /^ERROR_CODE=""$/              { in_blk=1 }
    /^emit_error\(\) \{$/          { in_fn=1 }
    /^emit_json_error\(\) \{$/     { in_fn=1 }
    /^_release_and_die\(\) \{$/    { in_fn=1 }
    in_fn || in_blk { print }
    in_fn && /^}$/                 { in_fn=0 }
    in_blk && /^}$/                { in_blk=0 }
    in_blk && /^FIX_DOCS_URL=""$/  { in_blk=0 }
' "$INSTALL_SH" >>"$SHIM_FILE"

run_emit() {
    # $1 code, $2 stage, $3 msg, $4 fix_cmd, $5 fix_url
    SYGEN_JSON_OUTPUT=1 bash -c "
        set +e
        source '$SHIM_FILE'
        emit_error \"\$1\" \"\$2\" \"\$3\" \"\$4\" \"\$5\"
    " _ "$1" "$2" "$3" "$4" "$5" 2>/dev/null | grep -E '^\{' | tail -n1
}

assert_field() {
    # $1 json $2 key $3 expected value
    local got
    got="$(printf '%s' "$1" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception as e:
    print(f'<parse-error: {e}>')
    sys.exit(0)
v = d.get('$2', '')
print(v if not isinstance(v, bool) else str(v))
")"
    if [ "$got" = "$3" ]; then
        PASS=$((PASS + 1))
        return 0
    fi
    echo "  FAIL [$2] expected=$3 got=$got" >&2
    FAIL=$((FAIL + 1))
    return 1
}

# Sanity: did the shim assemble?
if ! grep -q '^emit_error()' "$SHIM_FILE"; then
    echo "shim missing emit_error — install.sh layout changed; update awk extraction in this script" >&2
    exit 2
fi
if ! grep -q '^emit_json_error()' "$SHIM_FILE"; then
    echo "shim missing emit_json_error — install.sh layout changed" >&2
    exit 2
fi

# ---------- Test 1: HOMEBREW_MISSING ----------
echo "Test: HOMEBREW_MISSING"
JSON="$(run_emit HOMEBREW_MISSING deps \
    "Homebrew required on macOS." \
    '/bin/bash -c brew-install' \
    'https://brew.sh')"
assert_field "$JSON" ok False
assert_field "$JSON" error_code HOMEBREW_MISSING
assert_field "$JSON" stage deps
assert_field "$JSON" fix_docs_url 'https://brew.sh'

# ---------- Test 2: XCODE_CLT_MISSING ----------
echo "Test: XCODE_CLT_MISSING"
JSON="$(run_emit XCODE_CLT_MISSING deps \
    "Xcode CLT required." \
    'xcode-select --install' \
    'https://developer.apple.com/xcode/resources/')"
assert_field "$JSON" error_code XCODE_CLT_MISSING
assert_field "$JSON" fix_command 'xcode-select --install'

# ---------- Test 3: PORT_IN_USE ----------
echo "Test: PORT_IN_USE"
JSON="$(run_emit PORT_IN_USE bind \
    "Port 8081 already in use." \
    'lsof -i:8081' \
    '')"
assert_field "$JSON" error_code PORT_IN_USE
assert_field "$JSON" stage bind
assert_field "$JSON" fix_docs_url ''

# ---------- Test 4: TAILSCALE_OFFLINE ----------
echo "Test: TAILSCALE_OFFLINE"
JSON="$(run_emit TAILSCALE_OFFLINE network \
    "Tailscale daemon not running." \
    'sudo tailscale up' \
    'https://tailscale.com/kb/1080/cli')"
assert_field "$JSON" error_code TAILSCALE_OFFLINE
assert_field "$JSON" stage network

# ---------- Test 5: APT_LOCK_HELD ----------
echo "Test: APT_LOCK_HELD"
JSON="$(run_emit APT_LOCK_HELD deps \
    "apt-get lock held." \
    'systemctl stop unattended-upgrades' \
    '')"
assert_field "$JSON" error_code APT_LOCK_HELD

# ---------- Test 5b: NODE_MISSING ----------
echo "Test: NODE_MISSING"
JSON="$(run_emit NODE_MISSING deps \
    "node not found after brew install — try: brew link --overwrite node@22" \
    'brew link --overwrite node@22' \
    'https://nodejs.org')"
assert_field "$JSON" error_code NODE_MISSING
assert_field "$JSON" stage deps
assert_field "$JSON" fix_command 'brew link --overwrite node@22'
assert_field "$JSON" fix_docs_url 'https://nodejs.org'

# ---------- Test 6: backwards compat — bare die() defaults to UNKNOWN_ERROR ----------
echo "Test: bare die() yields UNKNOWN_ERROR"
JSON="$(SYGEN_JSON_OUTPUT=1 bash -c "
    set +e
    source '$SHIM_FILE'
    die 'arbitrary failure not via emit_error'
" 2>/dev/null | grep -E '^\{' | tail -n1)"
assert_field "$JSON" error_code UNKNOWN_ERROR
assert_field "$JSON" fix_command ''
assert_field "$JSON" fix_docs_url ''

# ---------- Test 7: JSON escapes special chars correctly ----------
echo "Test: special chars escaped"
JSON="$(run_emit HOMEBREW_MISSING deps \
    'msg with "quotes" and \\backslash' \
    'cmd with "quotes"' \
    'https://brew.sh')"
ROUNDTRIP="$(printf '%s' "$JSON" | python3 -c "
import json,sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('error', ''))
except Exception as e:
    print('<parse-error>:', e)
" 2>&1)"
if [ "$ROUNDTRIP" = 'msg with "quotes" and \\backslash' ]; then
    PASS=$((PASS + 1))
else
    echo "  FAIL [escape] got=$ROUNDTRIP" >&2
    FAIL=$((FAIL + 1))
fi

# ---------- Test 8: _release_and_die — error field is human, error_code is UPPER ----------
run_release() {
    # $1 err_code, $2 details
    SYGEN_JSON_OUTPUT=1 bash -c "
        set +e
        source '$SHIM_FILE'
        STAGE='cert'
        _release_and_die \"\$1\" \"\$2\"
    " _ "$1" "$2" 2>/dev/null | grep -E '^\{' | tail -n1
}

contains_field() {
    # $1 json, $2 key, $3 substring expected within value
    local got
    got="$(printf '%s' "$1" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print('<parse-error>')
    sys.exit(0)
print(d.get('$2', ''))
")"
    case "$got" in
        *"$3"*)
            PASS=$((PASS + 1))
            return 0
            ;;
    esac
    echo "  FAIL [$2 contains] expected substring=$3 got=$got" >&2
    FAIL=$((FAIL + 1))
    return 1
}

echo "Test: _release_and_die installer_misconfigured"
JSON="$(run_release installer_misconfigured "certbot rejected its own arguments")"
assert_field "$JSON" error_code INSTALLER_MISCONFIGURED
assert_field "$JSON" stage cert
contains_field "$JSON" error "Installer configuration error"
contains_field "$JSON" error "certbot rejected its own arguments"
assert_field "$JSON" details "certbot rejected its own arguments"

echo "Test: _release_and_die tls_rate_limited"
JSON="$(run_release tls_rate_limited "All three CAs refused")"
assert_field "$JSON" error_code TLS_RATE_LIMITED
contains_field "$JSON" error "rate-limited"
# retry_after_hours is part of the cert-path contract — must survive.
assert_field "$JSON" retry_after_hours 1

echo "Test: _release_and_die default cert_failed"
JSON="$(run_release "" "")"
assert_field "$JSON" error_code CERT_FAILED
contains_field "$JSON" error "TLS certificate issuance failed"

# ---------- Result ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
