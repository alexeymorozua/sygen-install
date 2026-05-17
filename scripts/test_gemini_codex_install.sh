#!/usr/bin/env bash
# scripts/test_gemini_codex_install.sh — static + functional smoke test that
# install.sh wires up the multi-provider CLI install (subtask #11):
#
#   1. install.sh references both @google/gemini-cli and @openai/codex
#      (Linux + macOS branches each install via manifest_npm_install).
#   2. install.sh resolves EFFECTIVE_GEMINI_CLI_PATH / EFFECTIVE_CODEX_CLI_PATH
#      and emits the matching GEMINI_CLI_PATH / CODEX_CLI_PATH lines to .env.
#   3. install.sh substitutes the matching __GEMINI_CLI_PATH__ /
#      __CODEX_CLI_PATH__ placeholders during plist materialization.
#   4. pro.sygen.core.plist exposes both placeholders as launchd env vars.
#   5. manifest_npm_install behaves correctly when fed Gemini/Codex pkg names
#      against a fake npm shim — recording to installed_npm and skipping
#      preexisting binaries.
#
# Smoke-tests for the actual CLIs at runtime (`which gemini`, `gemini
# --version`) are out of scope here — they require a real install, which is
# what install.sh itself does. CI would run install.sh in a container, then
# probe the binaries; that's a different test surface.
#
# Run from the repo root:    bash scripts/test_gemini_codex_install.sh
# Exit status: 0 = all pass, non-zero = failure (count printed at end).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
CORE_PLIST="$REPO_ROOT/scripts/pro.sygen.core.plist"
[ -f "$INSTALL_SH" ]  || { echo "install.sh not found at $INSTALL_SH" >&2; exit 2; }
[ -f "$CORE_PLIST" ]  || { echo "core plist not found at $CORE_PLIST" >&2; exit 2; }

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

# ---------- Static checks: install.sh ----------
echo "[1] install.sh references both alternate provider CLI packages"
GEMINI_INSTALL_COUNT="$(grep -c 'manifest_npm_install "@google/gemini-cli"' "$INSTALL_SH" || true)"
CODEX_INSTALL_COUNT="$(grep -c 'manifest_npm_install "@openai/codex"'      "$INSTALL_SH" || true)"
# Two callsites each: Linux block + macOS block.
assert "@google/gemini-cli installed in both Linux and macOS branches" '[ "$GEMINI_INSTALL_COUNT" = "2" ]'
assert "@openai/codex installed in both Linux and macOS branches"      '[ "$CODEX_INSTALL_COUNT"  = "2" ]'

# Pre-existing detection branch (don't reinstall if user already has the CLI).
assert "Gemini pre-existing path records to manifest" \
    'grep -q "manifest_record_npm_preexisting \"@google/gemini-cli\"" "$INSTALL_SH"'
assert "Codex pre-existing path records to manifest" \
    'grep -q "manifest_record_npm_preexisting \"@openai/codex\""      "$INSTALL_SH"'

# Lenient policy: warn-and-continue on install failure (not emit_error).
# This is a deliberate trade-off — alternate providers shouldn't block the
# whole install if their npm registry hiccups.
assert "Gemini install failure warns (does not emit_error)" \
    'grep -q "Gemini provider disabled" "$INSTALL_SH"'
assert "Codex install failure warns (does not emit_error)" \
    'grep -q "Codex provider disabled" "$INSTALL_SH"'
assert "Gemini install path does NOT use emit_error" \
    '! grep -B 1 "Gemini provider disabled" "$INSTALL_SH" | grep -q "emit_error"'
assert "Codex install path does NOT use emit_error" \
    '! grep -B 1 "Codex provider disabled"  "$INSTALL_SH" | grep -q "emit_error"'

echo "[2] install.sh resolves EFFECTIVE_*_CLI_PATH for both alternates"
assert "EFFECTIVE_GEMINI_CLI_PATH is set from command -v gemini" \
    'grep -q "EFFECTIVE_GEMINI_CLI_PATH=\"\$(command -v gemini" "$INSTALL_SH"'
assert "EFFECTIVE_CODEX_CLI_PATH is set from command -v codex" \
    'grep -q "EFFECTIVE_CODEX_CLI_PATH=\"\$(command -v codex"  "$INSTALL_SH"'
assert "EFFECTIVE_GEMINI_CLI_PATH is sanitized for .env" \
    'grep -q "EFFECTIVE_GEMINI_CLI_PATH=\"\$(sanitize_env_value" "$INSTALL_SH"'
assert "EFFECTIVE_CODEX_CLI_PATH is sanitized for .env" \
    'grep -q "EFFECTIVE_CODEX_CLI_PATH=\"\$(sanitize_env_value"  "$INSTALL_SH"'

echo "[3] install.sh writes GEMINI_CLI_PATH and CODEX_CLI_PATH to .env"
assert "GEMINI_CLI_PATH=… emitted to .env"  'grep -q "GEMINI_CLI_PATH=\\\$EFFECTIVE_GEMINI_CLI_PATH" "$INSTALL_SH"'
assert "CODEX_CLI_PATH=… emitted to .env"   'grep -q "CODEX_CLI_PATH=\\\$EFFECTIVE_CODEX_CLI_PATH"   "$INSTALL_SH"'

echo "[4] install.sh substitutes plist placeholders"
assert "__GEMINI_CLI_PATH__ is substituted in install_native_plist" \
    'grep -q "s|__GEMINI_CLI_PATH__|\\\$EFFECTIVE_GEMINI_CLI_PATH|g" "$INSTALL_SH"'
assert "__CODEX_CLI_PATH__ is substituted in install_native_plist" \
    'grep -q "s|__CODEX_CLI_PATH__|\\\$EFFECTIVE_CODEX_CLI_PATH|g"   "$INSTALL_SH"'

# ---------- Static checks: pro.sygen.core.plist ----------
echo "[5] pro.sygen.core.plist exposes the env vars to launchd"
assert "plist declares GEMINI_CLI_PATH key"        'grep -q "<key>GEMINI_CLI_PATH</key>"   "$CORE_PLIST"'
assert "plist declares CODEX_CLI_PATH key"         'grep -q "<key>CODEX_CLI_PATH</key>"    "$CORE_PLIST"'
assert "plist references __GEMINI_CLI_PATH__"      'grep -q "__GEMINI_CLI_PATH__"          "$CORE_PLIST"'
assert "plist references __CODEX_CLI_PATH__"       'grep -q "__CODEX_CLI_PATH__"           "$CORE_PLIST"'

# ---------- Functional check: manifest_npm_install handles both pkgs ----------
echo "[6] manifest_npm_install records the right buckets for both pkgs"
SHIM="$WORK_DIR/shim.sh"
cat >"$SHIM" <<'PREAMBLE'
log()  { printf 'LOG %s\n' "$*" >&2; }
warn() { printf 'WARN %s\n' "$*" >&2; }
SYGEN_MANIFEST_INSTALLED_NPM=()
SYGEN_MANIFEST_PREEXISTING_NPM=()
_manifest_has_item() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}
manifest_record_npm_installed() {
    local pkg="$1"
    if _manifest_has_item "$pkg" \
            ${SYGEN_MANIFEST_INSTALLED_NPM[@]+"${SYGEN_MANIFEST_INSTALLED_NPM[@]}"} \
            ${SYGEN_MANIFEST_PREEXISTING_NPM[@]+"${SYGEN_MANIFEST_PREEXISTING_NPM[@]}"}; then
        return 0
    fi
    SYGEN_MANIFEST_INSTALLED_NPM+=("$pkg")
}
manifest_record_npm_preexisting() {
    local pkg="$1"
    if _manifest_has_item "$pkg" \
            ${SYGEN_MANIFEST_INSTALLED_NPM[@]+"${SYGEN_MANIFEST_INSTALLED_NPM[@]}"} \
            ${SYGEN_MANIFEST_PREEXISTING_NPM[@]+"${SYGEN_MANIFEST_PREEXISTING_NPM[@]}"}; then
        return 0
    fi
    SYGEN_MANIFEST_PREEXISTING_NPM+=("$pkg")
}
PREAMBLE

awk '
    /^manifest_npm_install\(\) \{$/ { in_fn=1 }
    in_fn { print }
    in_fn && /^\}$/                 { in_fn=0 }
' "$INSTALL_SH" >>"$SHIM"

grep -q '^manifest_npm_install()' "$SHIM" \
    || { echo "shim missing manifest_npm_install (install.sh layout changed)" >&2; exit 2; }

# Fake npm shim: prints success without doing anything. The real npm would
# fetch from the registry; this exercise is about the bookkeeping wrapper.
FAKE_NPM="$WORK_DIR/fake-npm"
cat >"$FAKE_NPM" <<'NPMSCRIPT'
#!/usr/bin/env bash
# Mock npm: success, no-op. We only validate the bookkeeping wrapper.
echo "fake-npm called with: $*"
exit 0
NPMSCRIPT
chmod +x "$FAKE_NPM"

# Case A: both bins absent → manifest_npm_install records "installed_by_sygen".
# NB: ``set -u`` here would trip on empty arrays (e.g.
# ``${SYGEN_MANIFEST_PREEXISTING_NPM[*]}`` when the array is empty), so we
# rely on -e/-o pipefail-free defaults — the assertions on OUT_* are what
# catch a regression in the wrapper logic.
OUT_A="$(bash -c "
    PATH=/usr/bin:/bin   # no gemini / codex on PATH
    source '$SHIM'
    manifest_npm_install '@google/gemini-cli' gemini '$FAKE_NPM' >/dev/null 2>&1
    manifest_npm_install '@openai/codex'      codex  '$FAKE_NPM' >/dev/null 2>&1
    printf 'installed=%s\n' \"\${SYGEN_MANIFEST_INSTALLED_NPM[*]:-}\"
    printf 'preexisting=%s\n' \"\${SYGEN_MANIFEST_PREEXISTING_NPM[*]:-}\"
" 2>"$WORK_DIR/err_a")"
INSTALLED_A="$(echo "$OUT_A" | sed -n 's/^installed=//p')"
PREEX_A="$(echo "$OUT_A"     | sed -n 's/^preexisting=//p')"
assert "case A (bins absent): both pkgs recorded as installed_by_sygen" \
    '[ "$INSTALLED_A" = "@google/gemini-cli @openai/codex" ]'
assert "case A (bins absent): preexisting list empty" \
    '[ -z "$PREEX_A" ]'

# Case B: both bins present → manifest_npm_install records "preexisting".
# Use real script files (not symlinks to /bin/true) so command -v
# resolves cleanly under sandbox/CI environments that block symlink
# follow-through to system bins.
mkdir -p "$WORK_DIR/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/gemini"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/codex"
chmod +x "$WORK_DIR/bin/gemini" "$WORK_DIR/bin/codex"
OUT_B="$(bash -c "
    PATH='$WORK_DIR/bin':/usr/bin:/bin
    source '$SHIM'
    manifest_npm_install '@google/gemini-cli' gemini '$FAKE_NPM' >/dev/null 2>&1
    manifest_npm_install '@openai/codex'      codex  '$FAKE_NPM' >/dev/null 2>&1
    printf 'installed=%s\n' \"\${SYGEN_MANIFEST_INSTALLED_NPM[*]:-}\"
    printf 'preexisting=%s\n' \"\${SYGEN_MANIFEST_PREEXISTING_NPM[*]:-}\"
" 2>"$WORK_DIR/err_b")"
INSTALLED_B="$(echo "$OUT_B" | sed -n 's/^installed=//p')"
PREEX_B="$(echo "$OUT_B"     | sed -n 's/^preexisting=//p')"
assert "case B (bins present): both pkgs recorded as preexisting" \
    '[ "$PREEX_B" = "@google/gemini-cli @openai/codex" ]'
assert "case B (bins present): installed list empty" \
    '[ -z "$INSTALLED_B" ]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
