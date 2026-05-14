#!/usr/bin/env bash
# scripts/test_bootstrap_apns.sh — verify bootstrap_apns_key() pulls the
# APNs auth key from the Worker on fresh installs and stays idempotent /
# graceful on edge cases.
#
# Context: install.sh historically expected operators to drop
# AuthKey_*.p8 into ${SYGEN_HOME}/_secrets/ by hand. Testers never did,
# so iOS push stayed off. bootstrap_apns_key() POSTs to
# /api/bootstrap/apns with the install_token bearer and writes the
# returned key to $SYGEN_ROOT/data/_secrets/AuthKey_<KEY_ID>.p8.
#
# Test matrix:
#   1) Worker returns {key_id, key_b64} -> .p8 written, mode 0600,
#      EFFECTIVE_APNS_KEY_ID populated, log emitted.
#   2) Worker returns 503 -> no file, warn emitted, function returns 0
#      (install must continue).
#   3) An AuthKey_*.p8 already on disk -> short-circuit, no curl, file
#      not overwritten.
#   4) No install_token in env -> short-circuit, no curl.
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

# Helper: build a stub `curl` that writes a canned response body + status
# to whatever -o/-w the caller supplied. Recognises only the flags
# bootstrap_apns_key actually uses (-o <file>, -w '%{http_code}').
make_curl_stub() {
    local stub_path="$1"
    local body_file="$2"   # file whose contents become the response body
    local http_code="$3"   # status to echo on stdout via -w '%{http_code}'
    cat >"$stub_path" <<EOF
#!/usr/bin/env bash
out=""
fmt=""
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-o" ]; then out="\$a"; prev=""; continue; fi
    if [ "\$prev" = "-w" ]; then fmt="\$a"; prev=""; continue; fi
    case "\$a" in
        -o|-w) prev="\$a" ;;
        *) prev="" ;;
    esac
done
if [ -n "\$out" ]; then cat "$body_file" > "\$out"; fi
[ "\$fmt" = '%{http_code}' ] && printf '%s' "$http_code"
exit 0
EOF
    chmod +x "$stub_path"
}

# ---------- Test 1: happy path — Worker returns key, .p8 written ----------
echo "Test 1: Worker 200 -> AuthKey_<id>.p8 written with mode 0600"
SYGEN_ROOT="$WORK_DIR/t1"
mkdir -p "$SYGEN_ROOT/data/_secrets"

RESP_BODY="$WORK_DIR/resp1.json"
# Real base64 of a tiny payload, so `base64 -d` produces deterministic bytes.
KEY_B64="$(printf 'STUB-P8-CONTENT' | base64)"
cat >"$RESP_BODY" <<EOF
{"ok":true,"key_id":"TESTKEY123","key_b64":"$KEY_B64"}
EOF
make_curl_stub "$WORK_DIR/curl" "$RESP_BODY" 200

OUT_ERR="$WORK_DIR/err1"
RC=0
SYGEN_ROOT="$SYGEN_ROOT" \
EFFECTIVE_INSTALL_TOKEN="sit_test_token_xxxxxxxxxx" \
EFFECTIVE_HEARTBEAT_URL="https://install.sygen.pro/api/heartbeat" \
EFFECTIVE_APNS_KEY_ID="" \
PATH="$WORK_DIR:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && bootstrap_apns_key && echo \"EFFECTIVE_APNS_KEY_ID=\$EFFECTIVE_APNS_KEY_ID\"" \
    2>"$OUT_ERR" >"$WORK_DIR/out1" || RC=$?

OUT="$(cat "$WORK_DIR/out1")"
ERR="$(cat "$OUT_ERR")"
KEY_PATH="$SYGEN_ROOT/data/_secrets/AuthKey_TESTKEY123.p8"
MODE="$(stat -f '%Lp' "$KEY_PATH" 2>/dev/null || stat -c '%a' "$KEY_PATH" 2>/dev/null || echo missing)"

if [ "$RC" = "0" ] \
    && [ -f "$KEY_PATH" ] \
    && [ "$MODE" = "600" ] \
    && [ "$(cat "$KEY_PATH")" = "STUB-P8-CONTENT" ] \
    && echo "$OUT" | grep -q '^EFFECTIVE_APNS_KEY_ID=TESTKEY123$' \
    && echo "$ERR" | grep -q 'APNs key installed'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC mode=$MODE key_path_exists=$([ -f "$KEY_PATH" ] && echo yes || echo no)" >&2
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
make_curl_stub "$WORK_DIR/curl" "$RESP_BODY" 503

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

# ---------- Test 4: no install_token -> short-circuit ----------
echo "Test 4: no EFFECTIVE_INSTALL_TOKEN -> short-circuit, no curl"
SYGEN_ROOT="$WORK_DIR/t4"
mkdir -p "$SYGEN_ROOT/data/_secrets"

cat >"$WORK_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo "CURL-WAS-CALLED" >&2
exit 99
EOF
chmod +x "$WORK_DIR/curl"

OUT_ERR="$WORK_DIR/err4"
RC=0
SYGEN_ROOT="$SYGEN_ROOT" \
EFFECTIVE_INSTALL_TOKEN="" \
EFFECTIVE_HEARTBEAT_URL="https://install.sygen.pro/api/heartbeat" \
EFFECTIVE_APNS_KEY_ID="" \
PATH="$WORK_DIR:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && bootstrap_apns_key" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
KEY_COUNT="$(find "$SYGEN_ROOT/data/_secrets" -name 'AuthKey_*.p8' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$RC" = "0" ] \
    && [ "$KEY_COUNT" = "0" ] \
    && ! echo "$ERR" | grep -q 'CURL-WAS-CALLED' \
    && echo "$ERR" | grep -q 'skip APNs bootstrap: no install_token'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC key_count=$KEY_COUNT" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
