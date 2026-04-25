#!/usr/bin/env bash
# End-to-end smoke test for the deployed subdomain-service Worker.
#
# Hits a real Worker (default: https://install.sygen.pro) and exercises
# every public endpoint against real Cloudflare DNS + KV. Idempotent on
# the happy path: any subdomain it allocates is released at the end.
#
# Usage:
#   ./integration-test.sh
#   WORKER_URL=https://staging.example.workers.dev ./integration-test.sh
#
# See INTEGRATION_TEST_README.md for prerequisites and debugging tips.

set -euo pipefail

WORKER_URL="${WORKER_URL:-https://install.sygen.pro}"
DIG_RESOLVER="${DIG_RESOLVER:-1.1.1.1}"
DNS_PROPAGATION_TIMEOUT="${DNS_PROPAGATION_TIMEOUT:-60}"
RATE_LIMIT_MAX_ATTEMPTS="${RATE_LIMIT_MAX_ATTEMPTS:-6}"

# ---------- output helpers ----------------------------------------------------
if [[ -t 1 ]]; then
  C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YEL='\033[0;33m'
  C_BLU='\033[0;34m'; C_DIM='\033[2m'; C_RST='\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_RST=''
fi

CURRENT_STEP=""
step()  { CURRENT_STEP="$1"; printf "\n%b▶ %s%b\n" "$C_BLU" "$1" "$C_RST"; }
info()  { printf "  %b%s%b\n" "$C_DIM" "$1" "$C_RST"; }
pass()  { printf "  %bPASS%b %s\n" "$C_GRN" "$C_RST" "$1"; }
warn()  { printf "  %bWARN%b %s\n" "$C_YEL" "$C_RST" "$1"; }
fail()  {
  printf "\n%bFAIL%b at step: %s\n  %s\n" "$C_RED" "$C_RST" "$CURRENT_STEP" "$1" >&2
  exit 1
}

# ---------- prereqs -----------------------------------------------------------
require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}
require curl
require jq
require dig

# ---------- bookkeeping for cleanup ------------------------------------------
PRIMARY_TOKEN=""
PRIMARY_FQDN=""
RATE_BATCH_TOKENS=()

cleanup() {
  local rc=$?
  set +e
  if ((${#RATE_BATCH_TOKENS[@]})); then
    info "cleanup: releasing ${#RATE_BATCH_TOKENS[@]} rate-limit batch token(s)"
    local t
    for t in "${RATE_BATCH_TOKENS[@]}"; do
      curl -s -o /dev/null -X DELETE "$WORKER_URL/api/release" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg t "$t" '{install_token:$t}')" || true
    done
  fi
  if [[ $rc -ne 0 && -n "$PRIMARY_TOKEN" ]]; then
    info "cleanup: releasing primary token (test failed mid-run)"
    curl -s -o /dev/null -X DELETE "$WORKER_URL/api/release" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "$PRIMARY_TOKEN" '{install_token:$t}')" || true
  fi
  exit $rc
}
trap cleanup EXIT

# ---------- HTTP helper -------------------------------------------------------
# Writes body to $RESP_BODY and HTTP code to $RESP_CODE.
RESP_BODY=""
RESP_CODE=""
http() {
  local method="$1" path="$2" data="${3:-}"
  local tmp
  tmp="$(mktemp)"
  if [[ -n "$data" ]]; then
    RESP_CODE="$(curl -sS -o "$tmp" -w "%{http_code}" \
      -X "$method" "$WORKER_URL$path" \
      -H "Content-Type: application/json" \
      --data "$data")"
  else
    RESP_CODE="$(curl -sS -o "$tmp" -w "%{http_code}" \
      -X "$method" "$WORKER_URL$path")"
  fi
  RESP_BODY="$(cat "$tmp")"
  rm -f "$tmp"
}

assert_code() {
  local want="$1" ctx="$2"
  if [[ "$RESP_CODE" != "$want" ]]; then
    fail "$ctx: expected HTTP $want, got $RESP_CODE — body: $RESP_BODY"
  fi
}

assert_json_field() {
  local field="$1" ctx="$2"
  local v
  v="$(jq -r --arg f "$field" '.[$f] // empty' <<<"$RESP_BODY" 2>/dev/null)" \
    || fail "$ctx: response is not valid JSON — body: $RESP_BODY"
  [[ -n "$v" ]] || fail "$ctx: missing or empty field '$field' — body: $RESP_BODY"
}

# Wait until `dig` returns at least one line for the given record. Times
# out per DNS_PROPAGATION_TIMEOUT seconds.
wait_for_dns() {
  local rtype="$1" name="$2" deadline=$(( $(date +%s) + DNS_PROPAGATION_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    if dig +short +time=2 +tries=1 "@$DIG_RESOLVER" "$rtype" "$name" \
        | grep -q .; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Wait until `dig` returns NO lines (record gone).
wait_for_dns_gone() {
  local rtype="$1" name="$2" deadline=$(( $(date +%s) + DNS_PROPAGATION_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    if ! dig +short +time=2 +tries=1 "@$DIG_RESOLVER" "$rtype" "$name" \
        | grep -q .; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# ---------- preflight ---------------------------------------------------------
step "0/11 Preflight"
info "WORKER_URL = $WORKER_URL"
info "dig resolver = $DIG_RESOLVER"

CALLER_IP="$(curl -sS --max-time 5 https://ifconfig.me || true)"
[[ -n "$CALLER_IP" ]] || fail "could not determine caller IP via ifconfig.me"
info "caller IP    = $CALLER_IP"

# ---------- 1. provision ------------------------------------------------------
step "1/11 POST /api/provision"
http POST /api/provision '{}'
assert_code 200 "provision"
for f in fqdn install_token ttl_days heartbeat_url dns_challenge_url; do
  assert_json_field "$f" "provision"
done
PRIMARY_TOKEN="$(jq -r .install_token <<<"$RESP_BODY")"
PRIMARY_FQDN="$(jq -r .fqdn         <<<"$RESP_BODY")"
info "fqdn  = $PRIMARY_FQDN"
info "token = ${PRIMARY_TOKEN:0:12}…"
pass "provision returned all required fields"

# ---------- 2. dig fqdn -------------------------------------------------------
step "2/11 dig $PRIMARY_FQDN → expect $CALLER_IP"
if ! wait_for_dns A "$PRIMARY_FQDN"; then
  fail "DNS A record for $PRIMARY_FQDN did not appear within ${DNS_PROPAGATION_TIMEOUT}s"
fi
RESOLVED="$(dig +short "@$DIG_RESOLVER" A "$PRIMARY_FQDN" | head -n1)"
info "resolved → $RESOLVED"
if [[ "$RESOLVED" != "$CALLER_IP" ]]; then
  warn "resolved IP ($RESOLVED) != caller IP ($CALLER_IP) — NAT/proxy in front of test host?"
else
  pass "A record resolves to caller IP"
fi

# ---------- 3. dns-challenge POST (valid name) -------------------------------
step "3/11 POST /api/dns-challenge (valid name)"
VALID_CHALLENGE_NAME="_acme-challenge.${PRIMARY_FQDN}"
DUMMY_VALUE="integration-test-$(date +%s)-$RANDOM"
http POST /api/dns-challenge \
  "$(jq -n --arg t "$PRIMARY_TOKEN" --arg n "$VALID_CHALLENGE_NAME" --arg v "$DUMMY_VALUE" \
     '{install_token:$t, name:$n, value:$v}')"
assert_code 200 "dns-challenge POST"
CHALLENGE_RECORD_ID="$(jq -r .record_id <<<"$RESP_BODY")"
[[ -n "$CHALLENGE_RECORD_ID" && "$CHALLENGE_RECORD_ID" != "null" ]] \
  || fail "dns-challenge POST: missing record_id — body: $RESP_BODY"
info "record_id = $CHALLENGE_RECORD_ID"
pass "TXT record created for owned subdomain"

# ---------- 4. dns-challenge POST (out-of-scope name) -------------------------
step "4/11 POST /api/dns-challenge (out-of-scope name → expect 403)"
http POST /api/dns-challenge \
  "$(jq -n --arg t "$PRIMARY_TOKEN" \
     '{install_token:$t,
       name:"_acme-challenge.someoneelse.sygen.pro",
       value:"should-be-rejected"}')"
assert_code 403 "dns-challenge POST out-of-scope"
pass "out-of-scope challenge correctly rejected (403)"

# ---------- 5. dns-challenge DELETE ------------------------------------------
step "5/11 DELETE /api/dns-challenge"
http DELETE /api/dns-challenge \
  "$(jq -n --arg t "$PRIMARY_TOKEN" --arg n "$VALID_CHALLENGE_NAME" \
     '{install_token:$t, name:$n}')"
assert_code 200 "dns-challenge DELETE"
info "deleted = $(jq -r '.deleted // 0' <<<"$RESP_BODY")"
if ! wait_for_dns_gone TXT "$VALID_CHALLENGE_NAME"; then
  warn "TXT $VALID_CHALLENGE_NAME still resolvable after ${DNS_PROPAGATION_TIMEOUT}s (likely resolver cache); not a hard fail"
else
  pass "TXT record gone from authoritative DNS"
fi

# ---------- 6. heartbeat (valid) ---------------------------------------------
step "6/11 POST /api/heartbeat (valid token)"
http POST /api/heartbeat \
  "$(jq -n --arg t "$PRIMARY_TOKEN" '{install_token:$t}')"
assert_code 200 "heartbeat"
EXPIRES_AT="$(jq -r .expires_at <<<"$RESP_BODY")"
[[ -n "$EXPIRES_AT" && "$EXPIRES_AT" != "null" ]] \
  || fail "heartbeat: missing expires_at — body: $RESP_BODY"
NOW_EPOCH="$(date -u +%s)"
EXP_EPOCH="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${EXPIRES_AT%.*}" +%s 2>/dev/null \
            || date -u -d "$EXPIRES_AT" +%s 2>/dev/null \
            || echo 0)"
if (( EXP_EPOCH > NOW_EPOCH )); then
  pass "heartbeat extended TTL (expires_at $EXPIRES_AT is in future)"
else
  fail "heartbeat: expires_at not in future ($EXPIRES_AT)"
fi

# ---------- 7. heartbeat (bad token) -----------------------------------------
step "7/11 POST /api/heartbeat (bad token → expect 404)"
http POST /api/heartbeat \
  '{"install_token":"sit_completely_bogus_token_value_for_negative_test"}'
assert_code 404 "heartbeat bad token"
pass "unknown token correctly rejected (404)"

# ---------- 8. provision rate limit ------------------------------------------
# Step 1 already used 1 of the 5/h cap from this IP. We attempt up to
# RATE_LIMIT_MAX_ATTEMPTS more provisions back-to-back and assert that at
# least one returns 429. Successful tokens are tracked for cleanup so we
# don't leak orphan subdomains.
step "8/11 POST /api/provision ×${RATE_LIMIT_MAX_ATTEMPTS} → expect 429 within batch"
saw_429=0
for i in $(seq 1 "$RATE_LIMIT_MAX_ATTEMPTS"); do
  http POST /api/provision '{}'
  case "$RESP_CODE" in
    200)
      tok="$(jq -r .install_token <<<"$RESP_BODY")"
      fqdn="$(jq -r .fqdn         <<<"$RESP_BODY")"
      RATE_BATCH_TOKENS+=("$tok")
      info "  attempt $i: 200 ($fqdn)"
      ;;
    429)
      saw_429=1
      info "  attempt $i: 429 (rate-limited as expected)"
      break
      ;;
    *)
      fail "rate-limit batch attempt $i: unexpected HTTP $RESP_CODE — body: $RESP_BODY"
      ;;
  esac
done
if (( saw_429 == 1 )); then
  pass "rate limit triggered within ${RATE_LIMIT_MAX_ATTEMPTS} attempts"
else
  fail "no 429 seen after ${RATE_LIMIT_MAX_ATTEMPTS} provision attempts — rate limit not enforced?"
fi

# ---------- 9. release (valid) -----------------------------------------------
step "9/11 DELETE /api/release (valid token)"
http DELETE /api/release \
  "$(jq -n --arg t "$PRIMARY_TOKEN" '{install_token:$t}')"
assert_code 200 "release"
RELEASED="$(jq -r .released <<<"$RESP_BODY")"
[[ "$RELEASED" == "true" ]] || fail "release: expected released=true, got $RELEASED — body: $RESP_BODY"
if ! wait_for_dns_gone A "$PRIMARY_FQDN"; then
  warn "A record for $PRIMARY_FQDN still resolvable after ${DNS_PROPAGATION_TIMEOUT}s (likely resolver cache); not a hard fail"
else
  pass "A record gone from authoritative DNS"
fi

# ---------- 10. release (idempotent re-call with same token) -----------------
step "10/11 DELETE /api/release (re-release same token → expect ok=true, released=false)"
http DELETE /api/release \
  "$(jq -n --arg t "$PRIMARY_TOKEN" '{install_token:$t}')"
assert_code 200 "release idempotent"
OK_FLAG="$(jq -r .ok       <<<"$RESP_BODY")"
REL_FLAG="$(jq -r .released <<<"$RESP_BODY")"
[[ "$OK_FLAG" == "true" && "$REL_FLAG" == "false" ]] \
  || fail "release idempotent: expected ok=true released=false, got ok=$OK_FLAG released=$REL_FLAG — body: $RESP_BODY"
pass "idempotent re-release returns ok=true, released=false"
# clear so cleanup trap doesn't try to re-release a known-released token
PRIMARY_TOKEN=""

# ---------- 11. cleanup of rate-limit batch ----------------------------------
step "11/11 cleanup rate-limit batch (${#RATE_BATCH_TOKENS[@]} tokens)"
if ((${#RATE_BATCH_TOKENS[@]} == 0)); then
  info "no batch tokens to release"
else
  for t in "${RATE_BATCH_TOKENS[@]}"; do
    http DELETE /api/release \
      "$(jq -n --arg t "$t" '{install_token:$t}')"
    if [[ "$RESP_CODE" != "200" ]]; then
      warn "batch release got HTTP $RESP_CODE — body: $RESP_BODY"
    fi
  done
  RATE_BATCH_TOKENS=()  # prevent trap from double-releasing
  pass "rate-limit batch released"
fi

# ---------- summary -----------------------------------------------------------
printf "\n%bALL CHECKS PASSED%b\n" "$C_GRN" "$C_RST"
printf "  Worker: %s\n" "$WORKER_URL"
printf "  Primary subdomain (released): %s\n" "$PRIMARY_FQDN"
