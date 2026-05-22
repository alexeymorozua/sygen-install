#!/usr/bin/env bash
# scripts/test_gemini_codex_install.sh — static + functional smoke test that
# install.sh wires up the multi-provider CLI install (subtask #11, Phase 2c):
#
#   1. install.sh references both Antigravity (agy curl|bash) and
#      @openai/codex (npm). Phase 2c (2026-05-22) replaced the legacy
#      @google/gemini-cli npm entry with the install_agy_cli helper.
#   2. install.sh resolves EFFECTIVE_AGY_PATH / EFFECTIVE_CODEX_CLI_PATH
#      and emits the matching AGY_CLI_PATH / CODEX_CLI_PATH lines to .env.
#   3. install.sh substitutes the matching __AGY_CLI_PATH__ /
#      __CODEX_CLI_PATH__ placeholders during plist materialization.
#   4. pro.sygen.core.plist exposes both placeholders as launchd env vars.
#   5. manifest_npm_install behaves correctly when fed Codex pkg name
#      against a fake npm shim — recording to installed_npm and skipping
#      preexisting binaries.
#
# Smoke-tests for the actual CLIs at runtime (`which agy`, `agy --version`)
# are out of scope here — they require a real install, which is what
# install.sh itself does. CI would run install.sh in a container, then
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
AGY_INSTALL_COUNT="$(grep -c '^    install_agy_cli "\$HOME"' "$INSTALL_SH" || true)"
CODEX_INSTALL_COUNT="$(grep -c 'manifest_npm_install "@openai/codex"' "$INSTALL_SH" || true)"
# Two callsites each: Linux block + macOS block.
assert "install_agy_cli invoked in both Linux and macOS branches" '[ "$AGY_INSTALL_COUNT" = "2" ]'
assert "@openai/codex installed in both Linux and macOS branches" '[ "$CODEX_INSTALL_COUNT" = "2" ]'

# install_agy_cli definition + curl|bash invocation.
assert "install_agy_cli helper defined in install.sh" \
    'grep -q "^install_agy_cli()" "$INSTALL_SH"'
assert "install_agy_cli fetches Antigravity via curl|bash" \
    'grep -q "antigravity.google/cli/install.sh" "$INSTALL_SH"'

# Pre-existing detection branches.
assert "agy pre-existing path records binary as preexisting" \
    'grep -q "manifest_record_binary_preexisting" "$INSTALL_SH"'
assert "Codex pre-existing path records to manifest" \
    'grep -q "manifest_record_npm_preexisting \"@openai/codex\"" "$INSTALL_SH"'

# Lenient policy: warn-and-continue on install failure (not emit_error).
# Alternate providers shouldn't block the whole install if their
# registry/network hiccups.
assert "agy install failure warns (does not emit_error)" \
    'grep -q "Gemini provider disabled" "$INSTALL_SH"'
assert "Codex install failure warns (does not emit_error)" \
    'grep -q "Codex provider disabled" "$INSTALL_SH"'
assert "agy install path does NOT use emit_error" \
    '! grep -B 1 "Gemini provider disabled" "$INSTALL_SH" | grep -q "emit_error"'
assert "Codex install path does NOT use emit_error" \
    '! grep -B 1 "Codex provider disabled"  "$INSTALL_SH" | grep -q "emit_error"'

echo "[2] install.sh resolves EFFECTIVE_*_PATH for both alternates"
assert "EFFECTIVE_AGY_PATH is set from command -v agy" \
    'grep -q "EFFECTIVE_AGY_PATH=\"\$(command -v agy" "$INSTALL_SH"'
assert "EFFECTIVE_CODEX_CLI_PATH is set from command -v codex" \
    'grep -q "EFFECTIVE_CODEX_CLI_PATH=\"\$(command -v codex"  "$INSTALL_SH"'
assert "EFFECTIVE_AGY_PATH is sanitized for .env" \
    'grep -q "EFFECTIVE_AGY_PATH=\"\$(sanitize_env_value" "$INSTALL_SH"'
assert "EFFECTIVE_CODEX_CLI_PATH is sanitized for .env" \
    'grep -q "EFFECTIVE_CODEX_CLI_PATH=\"\$(sanitize_env_value"  "$INSTALL_SH"'

echo "[3] install.sh writes AGY_CLI_PATH and CODEX_CLI_PATH to .env"
assert "AGY_CLI_PATH=… emitted to .env"   'grep -q "AGY_CLI_PATH=\\\$EFFECTIVE_AGY_PATH" "$INSTALL_SH"'
assert "CODEX_CLI_PATH=… emitted to .env" 'grep -q "CODEX_CLI_PATH=\\\$EFFECTIVE_CODEX_CLI_PATH" "$INSTALL_SH"'
# Negative: legacy GEMINI_CLI_PATH= must not be re-emitted.
assert "legacy GEMINI_CLI_PATH= no longer emitted to .env" \
    '! grep -q "echo \"GEMINI_CLI_PATH=" "$INSTALL_SH"'

echo "[4] install.sh substitutes plist placeholders"
assert "__AGY_CLI_PATH__ is substituted in install_native_plist" \
    'grep -q "s|__AGY_CLI_PATH__|\\\$EFFECTIVE_AGY_PATH|g" "$INSTALL_SH"'
assert "__CODEX_CLI_PATH__ is substituted in install_native_plist" \
    'grep -q "s|__CODEX_CLI_PATH__|\\\$EFFECTIVE_CODEX_CLI_PATH|g"   "$INSTALL_SH"'

# ---------- Static checks: pro.sygen.core.plist ----------
echo "[5] pro.sygen.core.plist exposes the env vars to launchd"
assert "plist declares AGY_CLI_PATH key"          'grep -q "<key>AGY_CLI_PATH</key>"    "$CORE_PLIST"'
assert "plist declares CODEX_CLI_PATH key"        'grep -q "<key>CODEX_CLI_PATH</key>"  "$CORE_PLIST"'
assert "plist references __AGY_CLI_PATH__"        'grep -q "__AGY_CLI_PATH__"           "$CORE_PLIST"'
assert "plist references __CODEX_CLI_PATH__"      'grep -q "__CODEX_CLI_PATH__"         "$CORE_PLIST"'
# Negative: legacy GEMINI_CLI_PATH key must not survive in the template.
assert "plist no longer carries legacy GEMINI_CLI_PATH key" \
    '! grep -q "<key>GEMINI_CLI_PATH</key>" "$CORE_PLIST"'

# ---------- Functional check: manifest_npm_install handles codex ----------
echo "[6] manifest_npm_install records the right buckets for codex"
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

# Case A: codex absent → manifest_npm_install records "installed_by_sygen".
OUT_A="$(bash -c "
    PATH=/usr/bin:/bin   # no codex on PATH
    source '$SHIM'
    manifest_npm_install '@openai/codex' codex '$FAKE_NPM' >/dev/null 2>&1
    printf 'installed=%s\n' \"\${SYGEN_MANIFEST_INSTALLED_NPM[*]:-}\"
    printf 'preexisting=%s\n' \"\${SYGEN_MANIFEST_PREEXISTING_NPM[*]:-}\"
" 2>"$WORK_DIR/err_a")"
INSTALLED_A="$(echo "$OUT_A" | sed -n 's/^installed=//p')"
PREEX_A="$(echo "$OUT_A"     | sed -n 's/^preexisting=//p')"
assert "case A (bin absent): codex recorded as installed_by_sygen" \
    '[ "$INSTALLED_A" = "@openai/codex" ]'
assert "case A (bin absent): preexisting list empty" \
    '[ -z "$PREEX_A" ]'

# Case B: codex present → manifest_npm_install records "preexisting".
mkdir -p "$WORK_DIR/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/codex"
chmod +x "$WORK_DIR/bin/codex"
OUT_B="$(bash -c "
    PATH='$WORK_DIR/bin':/usr/bin:/bin
    source '$SHIM'
    manifest_npm_install '@openai/codex' codex '$FAKE_NPM' >/dev/null 2>&1
    printf 'installed=%s\n' \"\${SYGEN_MANIFEST_INSTALLED_NPM[*]:-}\"
    printf 'preexisting=%s\n' \"\${SYGEN_MANIFEST_PREEXISTING_NPM[*]:-}\"
" 2>"$WORK_DIR/err_b")"
INSTALLED_B="$(echo "$OUT_B" | sed -n 's/^installed=//p')"
PREEX_B="$(echo "$OUT_B"     | sed -n 's/^preexisting=//p')"
assert "case B (bin present): codex recorded as preexisting" \
    '[ "$PREEX_B" = "@openai/codex" ]'
assert "case B (bin present): installed list empty" \
    '[ -z "$INSTALLED_B" ]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
