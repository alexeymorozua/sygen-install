#!/usr/bin/env bash
# scripts/test_brew_detection.sh — verify ensure_brew_in_path() probes
# the filesystem before bailing with HOMEBREW_MISSING.
#
# Context: a user who just ran the official brew installer sometimes
# still gets HOMEBREW_MISSING because their current Terminal session's
# PATH hasn't been re-sourced yet. ensure_brew_in_path() looks at the
# canonical /opt/homebrew + /usr/local locations and `eval`s
# `brew shellenv` to close that gap before we declare brew missing.
#
# This test extracts the function from install.sh and exercises:
#   1) brew binary present (via SYGEN_TEST_BREW_BIN) but not in PATH
#      -> shellenv eval logged, function returns path, exit 0
#   2) brew binary not anywhere (SYGEN_TEST_BREW_BIN=NONE)
#      -> function returns 1 (caller will emit HOMEBREW_MISSING)
#   3) brew already in PATH (separate path entry)
#      -> no shellenv eval logged, function still returns path, exit 0
#
# Run from the repo root:    bash scripts/test_brew_detection.sh
# Exit status: 0 = all pass, non-zero = failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
[ -f "$INSTALL_SH" ] || { echo "install.sh not found at $INSTALL_SH" >&2; exit 2; }

SHIM_FILE="$(mktemp)"
WORK_DIR="$(mktemp -d)"
trap 'rm -f "$SHIM_FILE"; rm -rf "$WORK_DIR"' EXIT

# Minimal preamble: log emits to stderr with a known prefix so test 3
# can grep for the "sourcing shellenv" line.
cat >"$SHIM_FILE" <<'PREAMBLE'
log()  { printf 'LOG %s\n' "$*" >&2; }
warn() { printf 'WARN %s\n' "$*" >&2; }
PREAMBLE

# Extract the ensure_brew_in_path() function body from install.sh by
# the same awk pattern used in test_error_codes.sh.
awk '
    /^ensure_brew_in_path\(\) \{$/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/                 { in_fn=0 }
' "$INSTALL_SH" >>"$SHIM_FILE"

if ! grep -q '^ensure_brew_in_path()' "$SHIM_FILE"; then
    echo "shim missing ensure_brew_in_path — install.sh layout changed; update awk extraction" >&2
    exit 2
fi

# Fake brew binary that emits a no-op shellenv (adds its own dir to PATH).
FAKE_BREW="$WORK_DIR/fake-brew"
cat >"$FAKE_BREW" <<EOF
#!/usr/bin/env bash
# Stand-in for the real brew. shellenv prints export lines; for tests
# we only need it to leave brew callable via the directory it sits in.
case "\$1" in
    shellenv) echo "export PATH=\"$WORK_DIR:\$PATH\"" ;;
    *) echo "fake brew called with: \$*" ;;
esac
EOF
chmod +x "$FAKE_BREW"

FAIL=0
PASS=0

# ---------- Test 1: filesystem-detected brew loads into PATH ----------
echo "Test 1: brew on disk but not in PATH -> shellenv eval'd"
OUT="$(SYGEN_TEST_BREW_BIN="$FAKE_BREW" bash -c "
    # Strip ALL user PATH entries so brew isn't accidentally already callable.
    PATH=/usr/bin:/bin
    source '$SHIM_FILE'
    ensure_brew_in_path
" 2>"$WORK_DIR/err1")"
RC=$?
ERR="$(cat "$WORK_DIR/err1")"
if [ "$RC" = "0" ] && [ "$OUT" = "$FAKE_BREW" ] && echo "$ERR" | grep -q 'sourcing shellenv'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC stdout=$OUT stderr=$ERR" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 2: brew absent -> return 1 (caller will emit HOMEBREW_MISSING) ----------
echo "Test 2: brew not on disk -> ensure_brew_in_path returns 1"
SYGEN_TEST_BREW_BIN=NONE bash -c "
    PATH=/usr/bin:/bin
    source '$SHIM_FILE'
    ensure_brew_in_path >/dev/null 2>/dev/null
"
RC=$?
if [ "$RC" = "1" ]; then
    PASS=$((PASS+1))
else
    echo "  FAIL: expected rc=1 got=$RC" >&2
    FAIL=$((FAIL+1))
fi

# ---------- Test 3: brew already in PATH -> no shellenv eval ----------
echo "Test 3: brew already in PATH -> shellenv eval skipped"
# Symlink the fake brew under the name "brew" so command -v finds it.
ln -sf "$FAKE_BREW" "$WORK_DIR/brew"
OUT="$(SYGEN_TEST_BREW_BIN="$FAKE_BREW" PATH="$WORK_DIR:/usr/bin:/bin" bash -c "
    source '$SHIM_FILE'
    ensure_brew_in_path
" 2>"$WORK_DIR/err3")"
RC=$?
ERR="$(cat "$WORK_DIR/err3")"
if [ "$RC" = "0" ] && [ "$OUT" = "$FAKE_BREW" ] && ! echo "$ERR" | grep -q 'sourcing shellenv'; then
    PASS=$((PASS+1))
else
    echo "  FAIL: rc=$RC stdout=$OUT stderr=$ERR (expected no shellenv log)" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
