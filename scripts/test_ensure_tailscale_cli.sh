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
#   1) tailscale CLI already in PATH                       -> log + rc=0, no brew call
#   2) CLI absent + brew absent                            -> die with manual-install hint
#   3) CLI absent + brew install succeeds                  -> CLI now in PATH, rc=0
#   4) CLI absent + brew install fails                     -> die with retry hint
#   5) CLI absent + App Store _MASReceipt present          -> die with App Store hint, no brew call
#   6) CLI absent + non-App-Store .app (no receipt)        -> standard brew path runs
#   7) CLI absent + brew cask `tailscale-app` registered   -> die with CLI-activation hint, no brew install
#   8) CLI absent + cask NOT registered (override)         -> standard brew path still runs
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

# Default the App Store receipt hook to a path that doesn't exist so the
# pre-existing tests (which target the brew-install path) don't trip
# the new App-Store branch when run on a Mac that actually has
# Tailscale.app from the App Store installed. Test 5 overrides this
# per-invocation to point at a fake receipt.
export SYGEN_TEST_TAILSCALE_RECEIPT="$WORK_DIR/no-such-receipt"

# Same idea for the brew-cask detection: force the override OFF so a
# tester running this on a Mac that actually has `tailscale-app` cask
# installed doesn't have every test fall into the new cask branch.
# Tests 7 and 8 override this per-invocation.
export SYGEN_TEST_TAILSCALE_CASK_INSTALLED=0

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

# ---------- Test 5: App Store _MASReceipt present -> die, no brew call ----------
echo "Test 5: App Store _MASReceipt present -> die with App Store hint, no brew call"
mkdir -p "$WORK_DIR/t5"
# Trap brew calls — App Store branch must short-circuit before brew runs.
cat >"$WORK_DIR/t5/brew" <<'EOF'
#!/usr/bin/env bash
echo "BREW-WAS-CALLED" >&2
exit 99
EOF
chmod +x "$WORK_DIR/t5/brew"
# Fake _MASReceipt — file just needs to exist at the configured path.
FAKE_RECEIPT="$WORK_DIR/t5/Tailscale.app/Contents/_MASReceipt/receipt"
mkdir -p "$(dirname "$FAKE_RECEIPT")"
: >"$FAKE_RECEIPT"

OUT_ERR="$WORK_DIR/err5"
RC=0
PATH="$WORK_DIR/t5:/usr/bin:/bin" \
SYGEN_TEST_TAILSCALE_RECEIPT="$FAKE_RECEIPT" \
bash -c "source '$SHIM_FILE' && ensure_tailscale_cli" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
if [ "$RC" = "1" ] \
    && echo "$ERR" | grep -q 'Tailscale.app from the App Store' \
    && echo "$ERR" | grep -q 'brew install --cask tailscale-app' \
    && ! echo "$ERR" | grep -q 'BREW-WAS-CALLED'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 6: receipt absent -> brew path still runs ----------
echo "Test 6: receipt absent (non-App-Store) -> brew install path runs"
mkdir -p "$WORK_DIR/t6"
# Reuse the working brew shim from Test 3 (creates a tailscale stub).
cat >"$WORK_DIR/t6/brew" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "install" ] && [ "\$2" = "tailscale" ]; then
    cat >"$WORK_DIR/t6/tailscale" <<'TS'
#!/usr/bin/env bash
exit 0
TS
    chmod +x "$WORK_DIR/t6/tailscale"
    exit 0
fi
exit 0
EOF
chmod +x "$WORK_DIR/t6/brew"
# Point SYGEN_TEST_TAILSCALE_RECEIPT at a non-existent path so the
# App Store branch is skipped — function should fall through to brew.
MISSING_RECEIPT="$WORK_DIR/t6/does-not-exist/receipt"

OUT_ERR="$WORK_DIR/err6"
RC=0
PATH="$WORK_DIR/t6:/usr/bin:/bin" \
SYGEN_TEST_TAILSCALE_RECEIPT="$MISSING_RECEIPT" \
bash -c "source '$SHIM_FILE' && ensure_tailscale_cli" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
if [ "$RC" = "0" ] \
    && echo "$ERR" | grep -q 'Installing tailscale via brew' \
    && ! echo "$ERR" | grep -q 'Tailscale.app from the App Store'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 7: cask `tailscale-app` registered + CLI missing -> die ----------
echo "Test 7: tailscale-app cask installed + CLI missing -> die with CLI-activation hint, no brew install"
mkdir -p "$WORK_DIR/t7"
# Trap brew install — the cask-installed branch must short-circuit
# BEFORE attempting `brew install tailscale` (which would start a
# second tailscaled competing with the cask daemon).
cat >"$WORK_DIR/t7/brew" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "install" ]; then
    echo "BREW-INSTALL-WAS-CALLED" >&2
    exit 99
fi
exit 0
EOF
chmod +x "$WORK_DIR/t7/brew"

OUT_ERR="$WORK_DIR/err7"
RC=0
PATH="$WORK_DIR/t7:/usr/bin:/bin" \
SYGEN_TEST_TAILSCALE_CASK_INSTALLED=1 \
bash -c "source '$SHIM_FILE' && ensure_tailscale_cli" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
if [ "$RC" = "1" ] \
    && echo "$ERR" | grep -q 'Tailscale.app is installed but the CLI is not on PATH' \
    && echo "$ERR" | grep -q 'Command Line Integration' \
    && echo "$ERR" | grep -q 'Re-run install.sh' \
    && ! echo "$ERR" | grep -q 'BREW-INSTALL-WAS-CALLED'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 8: cask NOT registered + CLI + brew absent -> generic die ----------
# Asserts the cask override of 0 keeps the function on its old code path
# (the existing Test 2 "no brew, no CLI" behaviour) — i.e. the new
# branch is gated behind real cask detection, not a default-on heuristic.
echo "Test 8: cask override=0 + CLI + brew absent -> generic brew-install hint"
mkdir -p "$WORK_DIR/t8"
# Empty PATH dir — neither tailscale nor brew available.

OUT_ERR="$WORK_DIR/err8"
RC=0
PATH="$WORK_DIR/t8:/usr/bin:/bin" \
SYGEN_TEST_TAILSCALE_CASK_INSTALLED=0 \
bash -c "source '$SHIM_FILE' && ensure_tailscale_cli" \
    2>"$OUT_ERR" || RC=$?

ERR="$(cat "$OUT_ERR")"
if [ "$RC" = "1" ] \
    && echo "$ERR" | grep -q 'Tailscale CLI required but neither installed nor reachable via brew' \
    && ! echo "$ERR" | grep -q 'Command Line Integration'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC" >&2
    echo "  stderr: $ERR" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
