#!/usr/bin/env bash
# scripts/test_bootstrap_apns.sh — verify bootstrap_apns_key() pulls the
# APNs auth key from the Worker on fresh installs and stays idempotent /
# graceful on edge cases.
#
# Context: install.sh historically expected operators to drop
# AuthKey_*.p8 into ${SYGEN_HOME}/_secrets/ by hand. Testers never did,
# so iOS push stayed off. bootstrap_apns_key() now:
#   1. If no EFFECTIVE_INSTALL_TOKEN, fetches an anonymous one from
#      /api/bootstrap/install-token (tailscale/publicdomain submodes
#      that never hit /api/provision).
#   2. POSTs to /api/bootstrap/apns with the install_token bearer.
#   3. Writes the returned .p8 to $SYGEN_ROOT/data/_secrets/AuthKey_<KEY_ID>.p8.
#   4. Carries Worker-supplied APNs config (team_id, bundle_id,
#      environment) into EFFECTIVE_* for the .env / plist writeout.
#
# Test matrix:
#   1) Worker returns full APNs config {key_id, key_b64, team_id,
#      bundle_id, environment} -> .p8 written, mode 0600, all four
#      EFFECTIVE_* vars populated, log emitted.
#   2) Worker returns 503 -> no file, warn emitted, function returns 0
#      (install must continue).
#   3) An AuthKey_*.p8 already on disk -> short-circuit, no curl, file
#      not overwritten.
#   4) No install_token in env + Worker install-token endpoint returns
#      200 with token -> fetches token, then fetches .p8 normally.
#   5) No install_token + install-token endpoint fails (non-2xx /
#      network) -> graceful skip, install continues without push.
#   6) Backward compat: Worker returns only {key_id, key_b64} (old
#      shape) -> EFFECTIVE_APNS_KEY_ID populated, others stay at their
#      pre-existing values.
#
# Run from the repo root:    bash scripts/test_bootstrap_apns.sh
# Exit status: 0 = all pass, non-zero = failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
[ -f "$INSTALL_SH" ] || { echo "install.sh not found at $INSTALL_SH" >&2; exit 2; }

SHIM_FILE="$(mktemp)"
WORK_DIR="$(mktemp -d)"
trap 'rm -f "$SHIM_FILE"; rm -rf "$WORK_DIR"' EXIT

# Preamble: log/warn to stderr (tests grep stderr), mktemp delegates to
# the real tool, base64/jq are real (no stubs needed).
cat >"$SHIM_FILE" <<'PREAMBLE'
log()  { printf 'LOG %s\n' "$*" >&2; }
warn() { printf 'WARN %s\n' "$*" >&2; }
PREAMBLE

# Extract bootstrap_apns_key() body from install.sh by the same awk
# pattern used in test_brew_detection.sh / test_error_codes.sh.
awk '
    /^bootstrap_apns_key\(\) \{$/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/                { in_fn=0 }
' "$INSTALL_SH" >>"$SHIM_FILE"

if ! grep -q '^bootstrap_apns_key()' "$SHIM_FILE"; then
    echo "shim missing bootstrap_apns_key — install.sh layout changed; update awk extraction" >&2
    exit 2
fi

FAIL=0
PASS=0

# Helper: build a stub `curl` that recognises -o <file> and -w
# '%{http_code}' (the only flags bootstrap_apns_key actually uses), and
# dispatches based on which URL was requested. URL is the last
# positional argument that doesn't follow -o/-w/-H/-X.
#
# Args: stub_path  url1=body_file1,status1  url2=body_file2,status2 ...
# Where url is a literal substring matched against the request URL.
make_curl_stub() {
    local stub_path="$1"; shift
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'out=""'
        printf '%s\n' 'fmt=""'
        printf '%s\n' 'url=""'
        printf '%s\n' 'prev=""'
        printf '%s\n' 'for a in "$@"; do'
        printf '%s\n' '    case "$prev" in'
        printf '%s\n' '        -o) out="$a"; prev=""; continue ;;'
        printf '%s\n' '        -w) fmt="$a"; prev=""; continue ;;'
        printf '%s\n' '        -H|-X) prev=""; continue ;;'
        printf '%s\n' '    esac'
        printf '%s\n' '    case "$a" in'
        printf '%s\n' '        -o|-w|-H|-X) prev="$a" ;;'
        printf '%s\n' '        -*) prev="" ;;'
        printf '%s\n' '        https://*|http://*) url="$a"; prev="" ;;'
        printf '%s\n' '        *) prev="" ;;'
        printf '%s\n' '    esac'
        printf '%s\n' 'done'
        for spec in "$@"; do
            local pattern="${spec%%=*}"
            local rhs="${spec#*=}"
            local body_file="${rhs%%,*}"
            local http_code="${rhs#*,}"
            printf 'if [[ "$url" == *"%s"* ]]; then\n' "$pattern"
            printf '    if [ -n "$out" ]; then cat "%s" > "$out"; fi\n' "$body_file"
            printf '    if [ "$fmt" = '\''%%{http_code}'\'' ]; then printf '\''%%s'\'' "%s"; fi\n' "$http_code"
            printf '    if [ -z "$out" ] && [ "$fmt" != '\''%%{http_code}'\'' ]; then cat "%s"; fi\n' "$body_file"
            printf '    exit 0\n'
            printf 'fi\n'
        done
        # Fallback: HTTP 000, no body — simulates network failure for
        # any URL not matched above.
        printf '%s\n' 'if [ "$fmt" = '\''%{http_code}'\'' ]; then printf '\''000'\''; fi'
        printf '%s\n' 'exit 0'
    } >"$stub_path"
    chmod +x "$stub_path"
}

# ---------- Test 1: happy path — Worker returns full APNs config ----------
echo "Test 1: Worker 200 -> .p8 + team_id/bundle_id/environment populated"
SYGEN_ROOT="$WORK_DIR/t1"
mkdir -p "$SYGEN_ROOT/data/_secrets"

RESP_BODY="$WORK_DIR/resp1.json"
KEY_B64="$(printf 'STUB-P8-CONTENT' | base64)"
cat >"$RESP_BODY" <<EOF
{"ok":true,"key_id":"TESTKEY123","key_b64":"$KEY_B64","team_id":"4KQZ8D8P7T","bundle_id":"com.timedesign.sygen.ios","environment":"production"}
EOF
make_curl_stub "$WORK_DIR/curl" "/bootstrap/apns=$RESP_BODY,200"

OUT_ERR="$WORK_DIR/err1"
RC=0
SYGEN_ROOT="$SYGEN_ROOT" \
EFFECTIVE_INSTALL_TOKEN="sit_test_token_xxxxxxxxxx" \
EFFECTIVE_HEARTBEAT_URL="https://install.sygen.pro/api/heartbeat" \
EFFECTIVE_APNS_KEY_ID="" \
EFFECTIVE_APNS_TEAM_ID="" \
EFFECTIVE_APNS_BUNDLE_ID="" \
EFFECTIVE_APNS_ENVIRONMENT="" \
PATH="$WORK_DIR:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && bootstrap_apns_key && printf 'KEY_ID=%s\nTEAM_ID=%s\nBUNDLE_ID=%s\nENV=%s\n' \"\$EFFECTIVE_APNS_KEY_ID\" \"\$EFFECTIVE_APNS_TEAM_ID\" \"\$EFFECTIVE_APNS_BUNDLE_ID\" \"\$EFFECTIVE_APNS_ENVIRONMENT\"" \
    2>"$OUT_ERR" >"$WORK_DIR/out1" || RC=$?

OUT="$(cat "$WORK_DIR/out1")"
ERR="$(cat "$OUT_ERR")"
KEY_PATH="$SYGEN_ROOT/data/_secrets/AuthKey_TESTKEY123.p8"
MODE="$(stat -f '%Lp' "$KEY_PATH" 2>/dev/null || stat -c '%a' "$KEY_PATH" 2>/dev/null || echo missing)"

if [ "$RC" = "0" ] \
    && [ -f "$KEY_PATH" ] \
    && [ "$MODE" = "600" ] \
    && [ "$(cat "$KEY_PATH")" = "STUB-P8-CONTENT" ] \
    && echo "$OUT" | grep -q '^KEY_ID=TESTKEY123$' \
    && echo "$OUT" | grep -q '^TEAM_ID=4KQZ8D8P7T$' \
    && echo "$OUT" | grep -q '^BUNDLE_ID=com.timedesign.sygen.ios$' \
    && echo "$OUT" | grep -q '^ENV=production$' \
    && echo "$ERR" | grep -q 'APNs key installed'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC mode=$MODE" >&2
    echo "  stdout: $OUT" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 2: Worker 503 -> no file, install continues ----------
echo "Test 2: Worker 503 -> no file, warn emitted, rc=0"
SYGEN_ROOT="$WORK_DIR/t2"
mkdir -p "$SYGEN_ROOT/data/_secrets"

RESP_BODY="$WORK_DIR/resp2.json"
echo '{"ok":false,"error":"apns_not_configured"}' >"$RESP_BODY"
make_curl_stub "$WORK_DIR/curl" "/bootstrap/apns=$RESP_BODY,503"

OUT_ERR="$WORK_DIR/err2"
RC=0
SYGEN_ROOT="$SYGEN_ROOT" \
EFFECTIVE_INSTALL_TOKEN="sit_test_token_xxxxxxxxxx" \
EFFECTIVE_HEARTBEAT_URL="https://install.sygen.pro/api/heartbeat" \
EFFECTIVE_APNS_KEY_ID="" \
PATH="$WORK_DIR:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && bootstrap_apns_key" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
KEY_COUNT="$(find "$SYGEN_ROOT/data/_secrets" -name 'AuthKey_*.p8' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$RC" = "0" ] \
    && [ "$KEY_COUNT" = "0" ] \
    && echo "$ERR" | grep -q 'APNs bootstrap skipped (HTTP 503)'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC key_count=$KEY_COUNT" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 3: existing AuthKey_*.p8 -> short-circuit, no overwrite ----------
echo "Test 3: existing AuthKey_*.p8 -> short-circuit, no curl, file untouched"
SYGEN_ROOT="$WORK_DIR/t3"
mkdir -p "$SYGEN_ROOT/data/_secrets"
PRE_EXISTING="$SYGEN_ROOT/data/_secrets/AuthKey_PREEXIST01.p8"
echo "ORIGINAL-CONTENT" >"$PRE_EXISTING"
chmod 600 "$PRE_EXISTING"

# Curl stub that would FAIL the test if it ran (writes attacker payload).
cat >"$WORK_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo "CURL-WAS-CALLED" >&2
exit 99
EOF
chmod +x "$WORK_DIR/curl"

OUT_ERR="$WORK_DIR/err3"
RC=0
SYGEN_ROOT="$SYGEN_ROOT" \
EFFECTIVE_INSTALL_TOKEN="sit_test_token_xxxxxxxxxx" \
EFFECTIVE_HEARTBEAT_URL="https://install.sygen.pro/api/heartbeat" \
EFFECTIVE_APNS_KEY_ID="" \
PATH="$WORK_DIR:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && bootstrap_apns_key" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
if [ "$RC" = "0" ] \
    && [ "$(cat "$PRE_EXISTING")" = "ORIGINAL-CONTENT" ] \
    && ! echo "$ERR" | grep -q 'CURL-WAS-CALLED' \
    && echo "$ERR" | grep -q 'APNs key already present'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC file=$(cat "$PRE_EXISTING")" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 4: no install_token + install-token endpoint returns 200 ----------
echo "Test 4: no token in env -> fetch anonymous install-token + then .p8"
SYGEN_ROOT="$WORK_DIR/t4"
mkdir -p "$SYGEN_ROOT/data/_secrets"

TK_RESP="$WORK_DIR/tk4.json"
echo '{"ok":true,"install_token":"sit_anon_abcdef0123456789","ttl_seconds":3600}' >"$TK_RESP"
APNS_RESP="$WORK_DIR/apns4.json"
KEY_B64_4="$(printf 'STUB-FROM-ANON' | base64)"
cat >"$APNS_RESP" <<EOF
{"ok":true,"key_id":"ANON12345","key_b64":"$KEY_B64_4","team_id":"4KQZ8D8P7T","bundle_id":"com.timedesign.sygen.ios","environment":"production"}
EOF
make_curl_stub "$WORK_DIR/curl" \
    "/bootstrap/install-token=$TK_RESP,200" \
    "/bootstrap/apns=$APNS_RESP,200"

OUT_ERR="$WORK_DIR/err4"
RC=0
SYGEN_ROOT="$SYGEN_ROOT" \
EFFECTIVE_INSTALL_TOKEN="" \
EFFECTIVE_HEARTBEAT_URL="https://install.sygen.pro/api/heartbeat" \
EFFECTIVE_APNS_KEY_ID="" \
EFFECTIVE_APNS_TEAM_ID="" \
EFFECTIVE_APNS_BUNDLE_ID="" \
EFFECTIVE_APNS_ENVIRONMENT="" \
PATH="$WORK_DIR:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && bootstrap_apns_key && echo \"KEY_ID=\$EFFECTIVE_APNS_KEY_ID TEAM_ID=\$EFFECTIVE_APNS_TEAM_ID\"" \
    2>"$OUT_ERR" >"$WORK_DIR/out4" || RC=$?

OUT="$(cat "$WORK_DIR/out4")"
ERR="$(cat "$OUT_ERR")"
KEY_PATH4="$SYGEN_ROOT/data/_secrets/AuthKey_ANON12345.p8"
if [ "$RC" = "0" ] \
    && [ -f "$KEY_PATH4" ] \
    && echo "$OUT" | grep -q 'KEY_ID=ANON12345 TEAM_ID=4KQZ8D8P7T' \
    && echo "$ERR" | grep -q 'Anonymous install-token acquired' \
    && echo "$ERR" | grep -q 'APNs key installed'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  stdout: $OUT" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 5: no install_token + install-token endpoint fails -> graceful skip ----------
echo "Test 5: no token + install-token endpoint fails -> skip APNs gracefully"
SYGEN_ROOT="$WORK_DIR/t5"
mkdir -p "$SYGEN_ROOT/data/_secrets"

# install-token returns empty response (HTTP 000 / network failure).
# Stub built with no URL mappings means EVERY request returns 000/empty.
make_curl_stub "$WORK_DIR/curl"

OUT_ERR="$WORK_DIR/err5"
RC=0
SYGEN_ROOT="$SYGEN_ROOT" \
EFFECTIVE_INSTALL_TOKEN="" \
EFFECTIVE_HEARTBEAT_URL="https://install.sygen.pro/api/heartbeat" \
EFFECTIVE_APNS_KEY_ID="" \
PATH="$WORK_DIR:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && bootstrap_apns_key" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
KEY_COUNT5="$(find "$SYGEN_ROOT/data/_secrets" -name 'AuthKey_*.p8' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$RC" = "0" ] \
    && [ "$KEY_COUNT5" = "0" ] \
    && echo "$ERR" | grep -q 'skip APNs bootstrap: no install_token (anonymous fallback failed)'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC key_count=$KEY_COUNT5" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 6: backward compat — Worker returns only key_id + key_b64 ----------
echo "Test 6: backward compat — old Worker shape ({key_id,key_b64} only)"
SYGEN_ROOT="$WORK_DIR/t6"
mkdir -p "$SYGEN_ROOT/data/_secrets"

RESP_BODY6="$WORK_DIR/resp6.json"
KEY_B64_6="$(printf 'OLD-WORKER-CONTENT' | base64)"
cat >"$RESP_BODY6" <<EOF
{"ok":true,"key_id":"OLDKEYABC","key_b64":"$KEY_B64_6"}
EOF
make_curl_stub "$WORK_DIR/curl" "/bootstrap/apns=$RESP_BODY6,200"

OUT_ERR="$WORK_DIR/err6"
RC=0
# Pre-populate EFFECTIVE_APNS_TEAM_ID/BUNDLE_ID/ENV to assert they're
# preserved (precedence: operator > Worker).
SYGEN_ROOT="$SYGEN_ROOT" \
EFFECTIVE_INSTALL_TOKEN="sit_test_token_xxxxxxxxxx" \
EFFECTIVE_HEARTBEAT_URL="https://install.sygen.pro/api/heartbeat" \
EFFECTIVE_APNS_KEY_ID="" \
EFFECTIVE_APNS_TEAM_ID="OPERATOR_TEAM" \
EFFECTIVE_APNS_BUNDLE_ID="operator.bundle.id" \
EFFECTIVE_APNS_ENVIRONMENT="sandbox" \
PATH="$WORK_DIR:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && bootstrap_apns_key && printf 'KEY_ID=%s\nTEAM_ID=%s\nBUNDLE_ID=%s\nENV=%s\n' \"\$EFFECTIVE_APNS_KEY_ID\" \"\$EFFECTIVE_APNS_TEAM_ID\" \"\$EFFECTIVE_APNS_BUNDLE_ID\" \"\$EFFECTIVE_APNS_ENVIRONMENT\"" \
    2>"$OUT_ERR" >"$WORK_DIR/out6" || RC=$?

OUT6="$(cat "$WORK_DIR/out6")"
KEY_PATH6="$SYGEN_ROOT/data/_secrets/AuthKey_OLDKEYABC.p8"
if [ "$RC" = "0" ] \
    && [ -f "$KEY_PATH6" ] \
    && echo "$OUT6" | grep -q '^KEY_ID=OLDKEYABC$' \
    && echo "$OUT6" | grep -q '^TEAM_ID=OPERATOR_TEAM$' \
    && echo "$OUT6" | grep -q '^BUNDLE_ID=operator.bundle.id$' \
    && echo "$OUT6" | grep -q '^ENV=sandbox$'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  stdout: $OUT6" >&2
    echo "  stderr: $(cat "$OUT_ERR")" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 7: anonymous fallback does NOT leak into EFFECTIVE_INSTALL_TOKEN ----------
# Anonymous bootstrap tokens are tagged subdomain="anonymous" in TOKEN_INDEX.
# If install.sh's .env writeout (which only persists EFFECTIVE_INSTALL_TOKEN)
# captured an anonymous token, future re-runs would feed it to eab /
# heartbeat / release endpoints where SUBDOMAIN_RESERVATIONS.get("anonymous")
# returns null → the Worker's defensive cleanup deletes the token. The fix
# stores the anonymous token in a function-local var so it never escapes
# the function and never appears in .env. Verify here.
echo "Test 7: anonymous fallback does NOT set EFFECTIVE_INSTALL_TOKEN at caller scope"
SYGEN_ROOT="$WORK_DIR/t7"
mkdir -p "$SYGEN_ROOT/data/_secrets"

TK_RESP7="$WORK_DIR/tk7.json"
echo '{"ok":true,"install_token":"sit_anon_DEADBEEF","ttl_seconds":14400}' >"$TK_RESP7"
APNS_RESP7="$WORK_DIR/apns7.json"
KEY_B64_7="$(printf 'PAYLOAD-7' | base64)"
cat >"$APNS_RESP7" <<EOF
{"ok":true,"key_id":"ANON7KEY","key_b64":"$KEY_B64_7"}
EOF
make_curl_stub "$WORK_DIR/curl" \
    "/bootstrap/install-token=$TK_RESP7,200" \
    "/bootstrap/apns=$APNS_RESP7,200"

OUT_ERR="$WORK_DIR/err7"
RC=0
SYGEN_ROOT="$SYGEN_ROOT" \
EFFECTIVE_INSTALL_TOKEN="" \
EFFECTIVE_HEARTBEAT_URL="https://install.sygen.pro/api/heartbeat" \
EFFECTIVE_APNS_KEY_ID="" \
PATH="$WORK_DIR:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && bootstrap_apns_key && printf 'AFTER_INSTALL_TOKEN=[%s]\nAFTER_BOOTSTRAP_TOKEN=[%s]\n' \"\${EFFECTIVE_INSTALL_TOKEN:-}\" \"\${EFFECTIVE_APNS_BOOTSTRAP_TOKEN:-}\"" \
    2>"$OUT_ERR" >"$WORK_DIR/out7" || RC=$?

OUT7="$(cat "$WORK_DIR/out7")"
KEY_PATH7="$SYGEN_ROOT/data/_secrets/AuthKey_ANON7KEY.p8"
if [ "$RC" = "0" ] \
    && [ -f "$KEY_PATH7" ] \
    && echo "$OUT7" | grep -q '^AFTER_INSTALL_TOKEN=\[\]$' \
    && echo "$OUT7" | grep -q '^AFTER_BOOTSTRAP_TOKEN=\[\]$'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  expected EFFECTIVE_INSTALL_TOKEN and EFFECTIVE_APNS_BOOTSTRAP_TOKEN both empty at caller scope" >&2
    echo "  stdout: $OUT7" >&2
    echo "  stderr: $(cat "$OUT_ERR")" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 8: real EFFECTIVE_INSTALL_TOKEN preserved unchanged ----------
# Reservation-bound installs (auto submode) get a real install_token from
# /api/provision. bootstrap_apns_key() must use it as-is and never
# overwrite it — re-runs of install.sh need to keep using the same token
# for eab/heartbeat/release calls.
echo "Test 8: real EFFECTIVE_INSTALL_TOKEN preserved unchanged after bootstrap"
SYGEN_ROOT="$WORK_DIR/t8"
mkdir -p "$SYGEN_ROOT/data/_secrets"

APNS_RESP8="$WORK_DIR/apns8.json"
KEY_B64_8="$(printf 'PAYLOAD-8' | base64)"
cat >"$APNS_RESP8" <<EOF
{"ok":true,"key_id":"REAL8KEY","key_b64":"$KEY_B64_8"}
EOF
make_curl_stub "$WORK_DIR/curl" "/bootstrap/apns=$APNS_RESP8,200"

OUT_ERR="$WORK_DIR/err8"
RC=0
SYGEN_ROOT="$SYGEN_ROOT" \
EFFECTIVE_INSTALL_TOKEN="sit_real_RESERVATION_TOKEN_xyz" \
EFFECTIVE_HEARTBEAT_URL="https://install.sygen.pro/api/heartbeat" \
EFFECTIVE_APNS_KEY_ID="" \
PATH="$WORK_DIR:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && bootstrap_apns_key && printf 'AFTER=[%s]\n' \"\${EFFECTIVE_INSTALL_TOKEN:-}\"" \
    2>"$OUT_ERR" >"$WORK_DIR/out8" || RC=$?

OUT8="$(cat "$WORK_DIR/out8")"
KEY_PATH8="$SYGEN_ROOT/data/_secrets/AuthKey_REAL8KEY.p8"
if [ "$RC" = "0" ] \
    && [ -f "$KEY_PATH8" ] \
    && echo "$OUT8" | grep -q '^AFTER=\[sit_real_RESERVATION_TOKEN_xyz\]$'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  expected EFFECTIVE_INSTALL_TOKEN unchanged" >&2
    echo "  stdout: $OUT8" >&2
    echo "  stderr: $(cat "$OUT_ERR")" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
