#!/usr/bin/env bash
# scripts/test_cli_upgrade.sh — static + functional tests for the
# "pre-existing CLIs are never updated" fix (1.6.287).
#
# Background: recording a CLI as pre-existing answers "may uninstall.sh
# remove this?" — it must not also freeze the version. It did, and a
# Debian host sat on @anthropic-ai/claude-code 2.1.87 while upstream was
# at 2.1.273.
#
# Covers:
#   1. manifest_npm_refresh_preexisting is wired into all four npm
#      pre-existing branches (claude/codex × Linux/macOS).
#   2. install_agy_cli refreshes agy in place at the canonical path and
#      leaves an agy installed anywhere else alone.
#   3. install_agy_cli call sites tolerate a non-zero return (`set -e` is
#      active for the whole installer and Antigravity is optional).
#   4. manifest_npm_refresh_preexisting only upgrades npm-owned copies,
#      and returns 0 on every failure path so `set -e` cannot abort an
#      install over a stale CLI.
#   5. _path_is_under / _resolve_symlink_chain edge cases.
#   6. run_with_timeout bounds agy update on hosts without timeout(1).
#   7. The "update it yourself" hint matches how the CLI was installed —
#      a native claude (~/.local/share/claude/versions/) must not be told
#      to npm install -g a copy nothing on PATH resolves to.
#
# Run from the repo root:    bash scripts/test_cli_upgrade.sh
# Exit status: 0 = all pass, non-zero = failure (count printed at end).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
[ -f "$INSTALL_SH" ] || { echo "install.sh not found at $INSTALL_SH" >&2; exit 2; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

FAIL=0
PASS=0

assert() {
    local label="$1"; local cond="$2"
    if eval "$cond"; then
        PASS=$((PASS+1))
        printf '  ok   %s\n' "$label"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s   (cond: %s)\n' "$label" "$cond" >&2
    fi
}

# ---------- Static checks ----------
echo "[1] refresh helper wired into every npm pre-existing branch"
assert "manifest_npm_refresh_preexisting defined" \
    'grep -q "^manifest_npm_refresh_preexisting()" "$INSTALL_SH"'
CLAUDE_REFRESH="$(grep -c 'manifest_npm_refresh_preexisting "@anthropic-ai/claude-code"' "$INSTALL_SH" || true)"
CODEX_REFRESH="$(grep -c 'manifest_npm_refresh_preexisting "@openai/codex"' "$INSTALL_SH" || true)"
assert "claude refreshed in both Linux and macOS branches" '[ "$CLAUDE_REFRESH" = "2" ]'
assert "codex refreshed in both Linux and macOS branches"  '[ "$CODEX_REFRESH" = "2" ]'
# The pre-existing bucket must survive the refresh — uninstall.sh keys off it.
PREEXIST_CLAUDE="$(grep -c 'manifest_record_npm_preexisting "@anthropic-ai/claude-code"' "$INSTALL_SH" || true)"
assert "claude still recorded as preexisting (uninstall must not remove it)" \
    '[ "$PREEXIST_CLAUDE" = "2" ]'

echo "[2] agy refresh policy"
assert "agy at the canonical path is refreshed via its own updater" \
    'grep -q "\"\$agy_bin\" update" "$INSTALL_SH"'
assert "agy update is fed /dev/null so it cannot hang non-interactively" \
    'grep -q "</dev/null" "$INSTALL_SH"'
assert "agy update runs under a wall-clock limit (stalled socket, not just a prompt)" \
    'grep -q "run_with_timeout 300 env HOME=\"\$home_dir\" \"\$agy_bin\" update" "$INSTALL_SH"'
assert "agy update timeout is reported distinctly from a plain failure" \
    'grep -q "agy update timed out" "$INSTALL_SH"'
assert "agy found elsewhere on PATH is left untouched" \
    'grep -q "not updating \$existing" "$INSTALL_SH"'
assert "agy update failure warns rather than aborting" \
    'grep -q "agy update failed" "$INSTALL_SH"'

echo "[3] optional-CLI installs cannot abort the installer (set -e)"
AGY_GUARDED="$(grep -c '^    install_agy_cli "\$HOME" || true$' "$INSTALL_SH" || true)"
assert "both install_agy_cli call sites tolerate a non-zero return" \
    '[ "$AGY_GUARDED" = "2" ]'

# ---------- Functional checks ----------
echo "[4] manifest_npm_refresh_preexisting picks its targets correctly"

SHIM="$WORK_DIR/shim.sh"
cat >"$SHIM" <<'PREAMBLE'
log()  { printf 'LOG %s\n' "$*" >&2; }
warn() { printf 'WARN %s\n' "$*" >&2; }
PREAMBLE

extract_fn() {
    awk -v fn="$1" '
        $0 == fn "() {" { in_fn=1 }
        in_fn           { print }
        in_fn && /^\}$/ { in_fn=0 }
    ' "$INSTALL_SH" >>"$SHIM"
}
extract_fn run_with_timeout
extract_fn _resolve_symlink_chain
extract_fn _path_is_under
extract_fn _cli_update_hint
extract_fn manifest_npm_refresh_preexisting

for fn in run_with_timeout _resolve_symlink_chain _path_is_under \
          _cli_update_hint manifest_npm_refresh_preexisting; do
    grep -q "^$fn()" "$SHIM" \
        || { echo "shim missing $fn (install.sh layout changed)" >&2; exit 2; }
done

# Fake npm. Answers `prefix -g` / `ls -g --parseable` from env vars so each
# case can pose a different host layout, and appends every `install` call to
# $NPM_CALLS so we can assert whether an upgrade was actually attempted.
FAKE_NPM="$WORK_DIR/fake-npm"
cat >"$FAKE_NPM" <<'NPMSCRIPT'
#!/usr/bin/env bash
case "$1" in
    prefix) printf '%s\n' "${FAKE_NPM_PREFIX:-}" ;;
    ls)     printf '%s' "${FAKE_NPM_LS:-}"; [ -n "${FAKE_NPM_LS:-}" ] && printf '\n' ;;
    install)
        printf '%s\n' "$*" >>"$NPM_CALLS"
        exit "${FAKE_NPM_INSTALL_RC:-0}"
        ;;
esac
exit 0
NPMSCRIPT
chmod +x "$FAKE_NPM"

PREFIX="$WORK_DIR/prefix"
mkdir -p "$PREFIX/bin" "$WORK_DIR/elsewhere/bin"
make_cli() {  # $1 = path, $2 = version string
    printf '#!/bin/sh\necho "%s"\n' "$2" >"$1"
    chmod +x "$1"
}
make_cli "$PREFIX/bin/claude" "2.1.273 (Claude Code)"
make_cli "$WORK_DIR/elsewhere/bin/claude" "2.1.87 (Claude Code)"

PKG="@anthropic-ai/claude-code"

# Runs the helper under the installer's own `set -euo pipefail` so a
# non-zero return would surface as a non-zero script exit.
run_case() {  # $1 = PATH bin dir, rest = env assignments
    local bin_dir="$1"; shift
    NPM_CALLS="$WORK_DIR/npm_calls"
    : >"$NPM_CALLS"
    env NPM_CALLS="$NPM_CALLS" "$@" \
        bash -c "
            set -euo pipefail
            PATH='$bin_dir':/usr/bin:/bin
            export PATH
            source '$SHIM'
            manifest_npm_refresh_preexisting '$PKG' claude '$FAKE_NPM'
            printf 'rc=%s\n' \$?
        " 2>"$WORK_DIR/stderr"
}

# Case A — npm owns the package and the PATH binary is inside the prefix.
OUT_A="$(run_case "$PREFIX/bin" \
    FAKE_NPM_PREFIX="$PREFIX" FAKE_NPM_LS="$PREFIX/lib/node_modules/$PKG")"
CALLS_A="$(cat "$WORK_DIR/npm_calls")"
assert "case A (npm-owned): returns 0"          '[ "$OUT_A" = "rc=0" ]'
assert "case A (npm-owned): upgrades to @latest" \
    '[ "$CALLS_A" = "install -g $PKG@latest --fetch-timeout=60000 --fetch-retries=1" ]'

# Case B — brew / distro / manual install: npm has never heard of it.
OUT_B="$(run_case "$PREFIX/bin" FAKE_NPM_PREFIX="$PREFIX" FAKE_NPM_LS="")"
CALLS_B="$(cat "$WORK_DIR/npm_calls")"
assert "case B (not npm-managed): returns 0"    '[ "$OUT_B" = "rc=0" ]'
assert "case B (not npm-managed): no npm install (would create a 2nd copy)" \
    '[ -z "$CALLS_B" ]'
assert "case B (not npm-managed): warns with a manual hint" \
    'grep -q "not an npm global package" "$WORK_DIR/stderr"'

# Case C — npm has the package, but PATH resolves to a different copy.
OUT_C="$(run_case "$WORK_DIR/elsewhere/bin" \
    FAKE_NPM_PREFIX="$PREFIX" FAKE_NPM_LS="$PREFIX/lib/node_modules/$PKG")"
CALLS_C="$(cat "$WORK_DIR/npm_calls")"
assert "case C (shadowed copy): returns 0"      '[ "$OUT_C" = "rc=0" ]'
assert "case C (shadowed copy): no npm install" '[ -z "$CALLS_C" ]'
assert "case C (shadowed copy): warns about the prefix mismatch" \
    'grep -q "outside the global npm prefix" "$WORK_DIR/stderr"'

# Case D — registry unreachable / global prefix not writable.
OUT_D="$(run_case "$PREFIX/bin" \
    FAKE_NPM_PREFIX="$PREFIX" FAKE_NPM_LS="$PREFIX/lib/node_modules/$PKG" \
    FAKE_NPM_INSTALL_RC=1)"
assert "case D (npm install fails): still returns 0 — install must continue" \
    '[ "$OUT_D" = "rc=0" ]'
assert "case D (npm install fails): warns instead of aborting" \
    'grep -q "keeping the claude already installed" "$WORK_DIR/stderr"'

# Case E — no npm on the host at all.
OUT_E="$(NPM_CALLS="$WORK_DIR/npm_calls" bash -c "
    set -euo pipefail
    PATH='$PREFIX/bin'
    export PATH
    source '$SHIM'
    manifest_npm_refresh_preexisting '$PKG' claude '$WORK_DIR/no-such-npm'
    printf 'rc=%s\n' \$?
" 2>"$WORK_DIR/stderr")"
assert "case E (no npm): returns 0"             '[ "$OUT_E" = "rc=0" ]'
assert "case E (no npm): warns with the manual command" \
    'grep -q "npm install -g $PKG@latest" "$WORK_DIR/stderr"'

echo "[5] path helpers"
# _path_is_under expects an already-resolved path (the helper feeds it
# _resolve_symlink_chain output); mktemp dirs live under a symlinked /var
# on macOS, so resolve here too.
PATH_HELPER_OUT="$(bash -c "
    set -uo pipefail
    source '$SHIM'
    resolved=\"\$(_resolve_symlink_chain '$PREFIX/bin/claude')\"
    _path_is_under \"\$resolved\"     '$PREFIX' && echo under
    _path_is_under '/usr/bin/claude' '$PREFIX' || echo not_under
    _path_is_under '/usr/bin/claude' '/'       || echo root_refused
    _path_is_under '/usr/bin/claude' ''        || echo empty_refused
" 2>/dev/null)"
assert "_path_is_under: child path matches"   'echo "$PATH_HELPER_OUT" | grep -q "^under$"'
assert "_path_is_under: unrelated path does not"  'echo "$PATH_HELPER_OUT" | grep -q "^not_under$"'
assert "_path_is_under: refuses / as root"    'echo "$PATH_HELPER_OUT" | grep -q "^root_refused$"'
assert "_path_is_under: refuses empty root"   'echo "$PATH_HELPER_OUT" | grep -q "^empty_refused$"'

# Sibling-prefix trap: /opt/homebrew2 must not count as under /opt/homebrew.
mkdir -p "$WORK_DIR/prefix2/bin"
make_cli "$WORK_DIR/prefix2/bin/claude" "2.0.0"
SIBLING_OUT="$(bash -c "
    set -uo pipefail
    source '$SHIM'
    resolved=\"\$(_resolve_symlink_chain '$WORK_DIR/prefix2/bin/claude')\"
    _path_is_under \"\$resolved\" '$PREFIX' || echo sibling_rejected
" 2>/dev/null)"
assert "_path_is_under: sibling prefix rejected" '[ "$SIBLING_OUT" = "sibling_rejected" ]'

ln -sf "$PREFIX/bin/claude" "$WORK_DIR/elsewhere/bin/claude-link"
LINK_OUT="$(bash -c "
    set -uo pipefail
    source '$SHIM'
    _resolve_symlink_chain '$WORK_DIR/elsewhere/bin/claude-link'
" 2>/dev/null)"
assert "_resolve_symlink_chain: follows a symlink to its target" \
    '[ "$(cd "$PREFIX/bin" && pwd -P)/claude" = "$LINK_OUT" ]'

echo "[6] run_with_timeout (macOS has neither timeout nor gtimeout)"
# A PATH with nothing but `sleep` and `sh` forces the hand-rolled fallback
# branch on every platform, including Linux where timeout(1) exists.
MINBIN="$WORK_DIR/minbin"
mkdir -p "$MINBIN"
ln -sf "$(command -v sleep)" "$MINBIN/sleep"
ln -sf "$(command -v sh)" "$MINBIN/sh"

TIMEOUT_START="$(date +%s)"
TIMEOUT_RC="$(bash -c "
    set -uo pipefail
    PATH='$MINBIN'
    export PATH
    source '$SHIM'
    rc=0
    run_with_timeout 1 sleep 30 || rc=\$?
    printf '%s\n' \"\$rc\"
" 2>/dev/null)"
TIMEOUT_ELAPSED=$(( $(date +%s) - TIMEOUT_START ))
assert "run_with_timeout: returns 124 on expiry (matches timeout(1))" \
    '[ "$TIMEOUT_RC" = "124" ]'
assert "run_with_timeout: actually kills the child instead of waiting it out" \
    '[ "$TIMEOUT_ELAPSED" -lt 15 ]'

PASSTHRU_RC="$(bash -c "
    set -uo pipefail
    PATH='$MINBIN'
    export PATH
    source '$SHIM'
    rc=0
    run_with_timeout 30 sh -c 'exit 7' || rc=\$?
    printf '%s\n' \"\$rc\"
" 2>/dev/null)"
assert "run_with_timeout: passes the child's exit status through" \
    '[ "$PASSTHRU_RC" = "7" ]'

echo "[7] update hint matches how the CLI was actually installed"
NATIVE_VERSIONS="$WORK_DIR/home/.local/share/claude/versions"
mkdir -p "$NATIVE_VERSIONS" "$WORK_DIR/native/bin"
make_cli "$NATIVE_VERSIONS/2.1.87" "2.1.87 (Claude Code)"
ln -sf "$NATIVE_VERSIONS/2.1.87" "$WORK_DIR/native/bin/claude"

HINT_OUT="$(bash -c "
    set -uo pipefail
    source '$SHIM'
    _cli_update_hint claude '$NATIVE_VERSIONS/2.1.87'; echo
    _cli_update_hint claude '/opt/homebrew/bin/claude'; echo
" 2>/dev/null)"
assert "native claude install is told to use its own updater" \
    'echo "$HINT_OUT" | head -1 | grep -q "claude update"'
assert "native claude install is NOT told to npm install -g" \
    '! echo "$HINT_OUT" | head -1 | grep -q "npm install"'
assert "unknown install method gets a neutral hint" \
    'echo "$HINT_OUT" | tail -1 | grep -q "same way it was installed"'
assert "unknown install method is NOT told to npm install -g" \
    '! echo "$HINT_OUT" | tail -1 | grep -q "npm install"'

# End to end: a host with BOTH a native claude on PATH and an npm global
# copy — the exact macOS layout. The npm copy must not be "updated" as if
# it were the one in use.
run_case "$WORK_DIR/native/bin" \
    FAKE_NPM_PREFIX="$PREFIX" FAKE_NPM_LS="$PREFIX/lib/node_modules/$PKG" >/dev/null
CALLS_NATIVE="$(cat "$WORK_DIR/npm_calls")"
assert "native-on-PATH + npm shadow copy: no npm install" '[ -z "$CALLS_NATIVE" ]'
assert "native-on-PATH + npm shadow copy: advises the native updater" \
    'grep -q "claude update" "$WORK_DIR/stderr"'
assert "native-on-PATH + npm shadow copy: does not advise npm install -g" \
    '! grep -q "npm install -g" "$WORK_DIR/stderr"'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
