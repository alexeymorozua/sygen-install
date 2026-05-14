#!/usr/bin/env bash
# scripts/test_ensure_tailscale_cli.sh — verify ensure_tailscale_cli()
# auto-installs the brew `tailscale` formula when the CLI is missing on
# macOS self-hosted (tailscale submode), and bails cleanly when it can't.
#
# Context: iOS app preflight (commit 8d1d0a1, 2026-05-12) SSH-probes the
# target Mac for a `tailscale` binary before kicking off install.sh. The
# App Store Tailscale.app can't double as CLI, so install.sh now restores
# the brew CLI on every pass — this test pins that behaviour.
#
# Test matrix:
#   1) tailscale CLI already in PATH       -> log + rc=0, no brew call
#   2) CLI absent + brew absent            -> die with manual-install hint
#   3) CLI absent + brew install succeeds  -> CLI now in PATH, rc=0
#   4) CLI absent + brew install fails     -> die with retry hint
#
# Run from the repo root:    bash scripts/test_ensure_tailscale_cli.sh
# Exit status: 0 = all pass, non-zero = failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
[ -f "$INSTALL_SH" ] || { echo "install.sh not found at $INSTALL_SH" >&2; exit 2; }

SHIM_FILE="$(mktemp)"
WORK_DIR="$(mktemp -d)"
trap 'rm -f "$SHIM_FILE"; rm -rf "$WORK_DIR"' EXIT

# Preamble: log/warn to stderr (tests grep stderr); die mirrors install.sh
# (print + exit 1) so we can assert messages.
cat >"$SHIM_FILE" <<'PREAMBLE'
log()  { printf 'LOG %s\n' "$*" >&2; }
warn() { printf 'WARN %s\n' "$*" >&2; }
die()  { printf 'DIE %s\n' "$*" >&2; exit 1; }
PREAMBLE

# Extract ensure_tailscale_cli() body using the same awk pattern as
# test_brew_detection.sh / test_bootstrap_apns.sh.
awk '
    /^ensure_tailscale_cli\(\) \{$/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/                  { in_fn=0 }
' "$INSTALL_SH" >>"$SHIM_FILE"

if ! grep -q '^ensure_tailscale_cli()' "$SHIM_FILE"; then
    echo "shim missing ensure_tailscale_cli — install.sh layout changed; update awk extraction" >&2
    exit 2
fi

FAIL=0
PASS=0

# ---------- Test 1: tailscale already in PATH -> short-circuit ----------
echo "Test 1: tailscale already in PATH -> rc=0, no brew call"
mkdir -p "$WORK_DIR/t1"
cat >"$WORK_DIR/t1/tailscale" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK_DIR/t1/tailscale"
# Trap brew calls — if brew runs in this test, it's a regression.
cat >"$WORK_DIR/t1/brew" <<'EOF'
#!/usr/bin/env bash
echo "BREW-WAS-CALLED" >&2
exit 99
EOF
chmod +x "$WORK_DIR/t1/brew"

OUT_ERR="$WORK_DIR/err1"
RC=0
PATH="$WORK_DIR/t1:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && ensure_tailscale_cli" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
if [ "$RC" = "0" ] \
    && echo "$ERR" | grep -q 'Tailscale CLI present at' \
    && ! echo "$ERR" | grep -q 'BREW-WAS-CALLED'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 2: CLI absent + brew absent -> die ----------
echo "Test 2: CLI + brew both absent -> die with manual-install hint"
mkdir -p "$WORK_DIR/t2"
# Empty dir on PATH — neither tailscale nor brew available.
OUT_ERR="$WORK_DIR/err2"
RC=0
PATH="$WORK_DIR/t2:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && ensure_tailscale_cli" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
if [ "$RC" = "1" ] \
    && echo "$ERR" | grep -q 'Tailscale CLI required but neither installed nor reachable via brew' \
    && echo "$ERR" | grep -q 'pkgs.tailscale.com'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 3: brew install succeeds, CLI appears -> rc=0 ----------
echo "Test 3: brew install creates tailscale -> rc=0"
mkdir -p "$WORK_DIR/t3"
# Stub brew that, on `brew install tailscale`, drops a tailscale stub
# into the same PATH dir so command -v finds it next call.
cat >"$WORK_DIR/t3/brew" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "install" ] && [ "\$2" = "tailscale" ]; then
    cat >"$WORK_DIR/t3/tailscale" <<'TS'
#!/usr/bin/env bash
exit 0
TS
    chmod +x "$WORK_DIR/t3/tailscale"
    exit 0
fi
exit 0
EOF
chmod +x "$WORK_DIR/t3/brew"

OUT_ERR="$WORK_DIR/err3"
RC=0
PATH="$WORK_DIR/t3:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && ensure_tailscale_cli" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
if [ "$RC" = "0" ] \
    && echo "$ERR" | grep -q 'Installing tailscale via brew' \
    && echo "$ERR" | grep -q 'Tailscale CLI installed:' \
    && [ -x "$WORK_DIR/t3/tailscale" ]; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC tailscale_exists=$([ -x "$WORK_DIR/t3/tailscale" ] && echo yes || echo no)" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 4: brew install fails -> die ----------
echo "Test 4: brew install fails -> die with retry hint"
mkdir -p "$WORK_DIR/t4"
cat >"$WORK_DIR/t4/brew" <<'EOF'
#!/usr/bin/env bash
# Simulate "No available formula", network error, etc.
echo "Error: Failed to install" >&2
exit 1
EOF
chmod +x "$WORK_DIR/t4/brew"

OUT_ERR="$WORK_DIR/err4"
RC=0
PATH="$WORK_DIR/t4:/usr/bin:/bin" \
bash -c "source '$SHIM_FILE' && ensure_tailscale_cli" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
if [ "$RC" = "1" ] \
    && echo "$ERR" | grep -q 'brew install tailscale failed' \
    && echo "$ERR" | grep -q 'Try manually: brew install tailscale'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
