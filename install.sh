#!/usr/bin/env bash
# Sygen install script — NATIVE install (no Docker, no Colima).
#
# Linux  (Debian 12+/Ubuntu 22+ VPS): apt, Python 3.14 venv, Node 22, systemd
#        units (sygen-core, sygen-admin, sygen-updater), nginx vhost + cert
#        via certbot DNS-01.
# macOS  (Darwin): Homebrew (python@3.14 + node@22 + whisper-cpp), per-user
#        Python venv at $SYGEN_ROOT/venv, admin tarball at $SYGEN_ROOT/admin,
#        launchd LaunchAgents (pro.sygen.core, pro.sygen.admin,
#        pro.sygen.updater). Three sub-modes (selected via SELF_HOSTED_MODE):
#          - localhost     (default w/o Tailscale) — http://localhost only,
#                          iPhone cannot reach it (App Transport Security).
#          - tailscale     (recommended)           — HTTPS on the tailnet via
#                          `tailscale serve`, valid cert from Tailscale.
#                          iPhone must also be on this tailnet.
#          - publicdomain  (advanced)              — same Worker DNS-01 flow as
#                          Linux auto-mode, brew nginx terminates TLS on 443.
#                          Requires NAT port forwarding 80/443 → Mac on router.
#
# Required env (Linux + custom-mode only — auto-mode needs nothing):
#   SYGEN_SUBDOMAIN   e.g. "alice" → alice.sygen.pro
#   CF_API_TOKEN      Cloudflare token with DNS:Edit on the zone
#   CF_ZONE_ID        Cloudflare zone id for SYGEN_DOMAIN
#
# Optional env:
#   SYGEN_DOMAIN              default: sygen.pro
#   ANTHROPIC_API_KEY         injected into core process env
#   SYGEN_INSTALL_BASE_URL    default: https://install.sygen.pro
#                             (source of nginx.conf.tmpl + service templates)
#   SYGEN_CORE_VERSION        default: 1.6.75 — version of `sygen` Python
#                             package to install (or "latest" to query
#                             GitHub Releases for the latest tag).
#   SYGEN_ADMIN_VERSION       default: 0.5.55 — version of sygen-admin
#                             tarball to download from GitHub Releases.
#   SYGEN_RELEASE_SOURCE      default: github (download wheel + tarball
#                             from GitHub Releases). "source" = build from
#                             a local checkout in SYGEN_CORE_SOURCE_DIR /
#                             SYGEN_ADMIN_SOURCE_DIR (transitional / dev).
#   SYGEN_CORE_SOURCE_DIR     when SYGEN_RELEASE_SOURCE=source: path to
#                             a `sygen` checkout (pip install <dir>).
#   SYGEN_ADMIN_SOURCE_DIR    when SYGEN_RELEASE_SOURCE=source: path to
#                             a `sygen-admin` checkout (npm ci && build).
#   SYGEN_ADMIN_PORT          host port for admin, default 8080
#   SELF_HOSTED_MODE          (macOS) localhost | tailscale | publicdomain.
#                             (Linux) tailscale only.
#                             If unset on macOS: auto-detect Tailscale and
#                             prompt (interactive) or fall back to localhost.
#                             If unset on Linux: auto-mode (Worker subdomain).
#   SYGEN_JSON_OUTPUT=1       emit a single JSON line on stdout instead of the
#                             human banner (progress logs still go to stderr).
#                             Equivalent to passing `--json-output` as a flag.
#                             Useful for SSH-driven deploy wizards.
#
# The core service bootstraps its own "admin" user on first boot and writes the
# one-time password to $SYGEN_ROOT/data/_secrets/.initial_admin_password. The
# installer prints it at the end. $SYGEN_ROOT is /srv/sygen on Linux and
# $HOME/.sygen-local on macOS. Native processes own these ports:
#   localhost:8081 — sygen-core   (FastAPI/aiohttp REST + WebSocket)
#   localhost:8080 — sygen-admin  (Next.js standalone, default SYGEN_ADMIN_PORT)
#   localhost:8082 — sygen-updater (FastAPI, bound to 127.0.0.1, bearer-authed)
#
# Usage:
#   # Linux (VPS, run as root):
#   curl -fsSL https://install.sygen.pro/install.sh | \
#     SYGEN_SUBDOMAIN=alice \
#     CF_API_TOKEN=cfat_xxx \
#     CF_ZONE_ID=6ae59801f8ac7b5dc33b6e32d844b0a6 \
#     bash
#
#   # macOS (local dev, regular user — localhost only, Mac-only access):
#   curl -fsSL https://install.sygen.pro/install.sh | bash
#
#   # macOS self-hosted with iPhone access via Tailscale (recommended):
#   curl -fsSL https://install.sygen.pro/install.sh | \
#     SELF_HOSTED_MODE=tailscale bash
#
#   # macOS self-hosted on a public *.sygen.pro (advanced — needs router port forward):
#   curl -fsSL https://install.sygen.pro/install.sh | \
#     SELF_HOSTED_MODE=publicdomain bash
set -euo pipefail

# ---------- Line-buffer stdout/stderr ----------
# Without this, bash's default 4 KB block buffer on stdout (and 1 KB on
# stderr when not a TTY) can hide progress for minutes during long-silent
# phases — `apt-get install -y docker-ce` (~2-3 min of downloads),
# `docker compose pull` (~1-3 min per image), and the DNS-propagation
# poll loop (~30-90 s of `dig` retries). The iOS / Android wizards tail
# /tmp/sygen-install.log live; without flushing, the log file stays empty
# until the buffer fills, the wizard's progress UI never advances past
# the initial "downloading installer" phase, and users assume the install
# hung. Re-exec under `stdbuf -oL -eL` (GNU coreutils, ships with every
# Debian/Ubuntu/RHEL by default; macOS gets it via `brew install
# coreutils` → `gstdbuf`, but our macOS branch always runs in a TTY so
# the buffer is already line-buffered there → the re-exec is a no-op).
# SYGEN_INSTALL_NO_STDBUF=1 prevents an infinite re-exec loop.
if [ -z "${SYGEN_INSTALL_NO_STDBUF:-}" ] && command -v stdbuf >/dev/null 2>&1; then
    export SYGEN_INSTALL_NO_STDBUF=1
    exec stdbuf -oL -eL "$0" "$@"
fi

# ---------- Output mode (human banner vs. machine-parseable JSON) ----------
# --json-output (or SYGEN_JSON_OUTPUT=1) makes the installer emit a single
# JSON line on stdout at the end (success or failure) and route progress
# logs to stderr so SSH-driven deploy wizards can parse the result without
# scraping a human banner that may change formatting.
JSON_OUTPUT="${SYGEN_JSON_OUTPUT:-0}"
# --self-hosted={localhost|tailscale|publicdomain} mirrors SELF_HOSTED_MODE
# but is parseable by SSH-driven wizards that prefer flags over env vars.
# CLI flag wins over env var (operator intent is more explicit).
for arg in "$@"; do
    case "$arg" in
        --json-output) JSON_OUTPUT=1 ;;
        --self-hosted=*) SELF_HOSTED_MODE="${arg#--self-hosted=}" ;;
        --self-hosted)
            printf '\033[0;31mXX\033[0m %s\n' "--self-hosted requires a value: --self-hosted=localhost|tailscale|publicdomain" >&2
            exit 1
            ;;
    esac
done
JSON_DONE=0
STAGE="init"

log()  {
    if [ "$JSON_OUTPUT" = "1" ]; then
        printf '\033[0;36m==>\033[0m %s\n' "$*" >&2
    else
        printf '\033[0;36m==>\033[0m %s\n' "$*"
    fi
}
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }
die()  {
    printf '\033[0;31mXX\033[0m %s\n' "$*" >&2
    if [ "$JSON_OUTPUT" = "1" ] && [ "$JSON_DONE" = "0" ]; then
        emit_json_error "$*"
    fi
    exit 1
}

# Minimal JSON string escape: backslash, double-quote, and the common
# control chars. Sufficient for the values we emit (paths, image refs,
# fqdns, the alphanumeric admin password). No NUL handling — shell vars
# can't carry NUL anyway.
json_escape() {
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

# ---------- Install manifest (v1.6.46+) ----------
# Captures what install.sh actually puts on the host (vs. what was already
# there) so uninstall.sh can remove ONLY what we own. Brew packages and
# the Colima profile are the load-bearing fields — they may have been
# installed by the user before sygen, in which case we must not touch
# them on uninstall.
#
# On re-runs the original classification is preserved (see manifest_load):
# a package preexisting at first install must stay "preexisting" forever,
# even though `brew list` will now succeed for sygen-installed packages
# too. The manifest is written via a trap-on-EXIT handler so a partial
# install (curl timeout, brew install fail, etc.) still leaves a manifest
# behind — without it, a re-run would reclassify already-on-disk packages
# as "preexisting" and uninstall would orphan them on the host.
SYGEN_MANIFEST_INSTALLED_PKGS=()
SYGEN_MANIFEST_PREEXISTING_PKGS=()
SYGEN_MANIFEST_PLISTS=()
# v1.6.49+: files install.sh downloaded to host paths OUTSIDE $SYGEN_ROOT
# (today: whisper ggml model under ~/.local/share/whisper-cpp/models). Only
# files we actually fetched land here — preexisting model files stay
# unrecorded so uninstall.sh never touches a model the user pre-staged.
# Each entry is a JSON object literal: {"path":"…","purpose":"…","size_bytes":N}.
SYGEN_MANIFEST_DOWNLOADED=()
# v1.7+ (native): per-platform autostart artifacts. macOS gets three
# LaunchAgents (core / admin / updater); Linux gets the matching systemd
# units. Tracked redundantly in SYGEN_MANIFEST_PLISTS too so the existing
# unload loops in uninstall.sh keep working — the dedicated fields here
# are for self-documenting manifests and the iOS preview UI.
SYGEN_MANIFEST_AUTOSTART_PLISTS=()
SYGEN_MANIFEST_AUTOSTART_LINUX_UNITS=()
# Resolved native artefact paths. Recorded so uninstall can rm -rf them
# directly without having to re-derive locations from $SYGEN_ROOT.
SYGEN_MANIFEST_CORE_VENV=""
SYGEN_MANIFEST_ADMIN_DIR=""
SYGEN_MANIFEST_CORE_VERSION=""
SYGEN_MANIFEST_ADMIN_VERSION=""

_manifest_has_item() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

manifest_record_pkg_installed() {
    local pkg="$1"
    if _manifest_has_item "$pkg" \
            ${SYGEN_MANIFEST_INSTALLED_PKGS[@]+"${SYGEN_MANIFEST_INSTALLED_PKGS[@]}"} \
            ${SYGEN_MANIFEST_PREEXISTING_PKGS[@]+"${SYGEN_MANIFEST_PREEXISTING_PKGS[@]}"}; then
        return 0
    fi
    log "manifest: recording $pkg as installed_by_sygen"
    SYGEN_MANIFEST_INSTALLED_PKGS+=("$pkg")
}

manifest_record_pkg_preexisting() {
    local pkg="$1"
    if _manifest_has_item "$pkg" \
            ${SYGEN_MANIFEST_INSTALLED_PKGS[@]+"${SYGEN_MANIFEST_INSTALLED_PKGS[@]}"} \
            ${SYGEN_MANIFEST_PREEXISTING_PKGS[@]+"${SYGEN_MANIFEST_PREEXISTING_PKGS[@]}"}; then
        return 0
    fi
    log "manifest: recording $pkg as preexisting"
    SYGEN_MANIFEST_PREEXISTING_PKGS+=("$pkg")
}

manifest_record_plist() {
    local label="$1"
    if _manifest_has_item "$label" \
            ${SYGEN_MANIFEST_PLISTS[@]+"${SYGEN_MANIFEST_PLISTS[@]}"}; then
        return 0
    fi
    SYGEN_MANIFEST_PLISTS+=("$label")
}

manifest_record_downloaded() {
    # $1 = absolute host path that install.sh just downloaded (post-SHA-verify
    # for the whisper model — never call this on a file we'll later delete).
    # $2 = machine-readable purpose tag (e.g. whisper_small_model).
    #
    # Idempotent across re-runs: manifest_load reseeds SYGEN_MANIFEST_DOWNLOADED
    # before sections run, so a re-run that re-discovers an already-recorded
    # path must not duplicate the entry. Skip silently on dup; caller can
    # always call this unconditionally on a successful download.
    local path="$1"
    local purpose="$2"
    local entry
    for entry in ${SYGEN_MANIFEST_DOWNLOADED[@]+"${SYGEN_MANIFEST_DOWNLOADED[@]}"}; do
        case "$entry" in
            *"\"path\":\"$path\""*) return 0 ;;
        esac
    done
    local size
    size="$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    log "manifest: recording downloaded $path (purpose=$purpose, $size bytes)"
    SYGEN_MANIFEST_DOWNLOADED+=("{\"path\":$(json_escape "$path"),\"purpose\":$(json_escape "$purpose"),\"size_bytes\":$size}")
}

manifest_record_autostart_plist() {
    # $1 = launchd label (e.g. pro.sygen.colima). The plist path is
    # always $HOME/Library/LaunchAgents/<label>.plist on macOS. We also
    # record the label in plists_installed so the existing manifest-driven
    # uninstall path picks it up without a second loop — the dedicated
    # autostart_macos_plists field below is only for human/preview use.
    local label="$1"
    manifest_record_plist "$label"
    local plist="$HOME/Library/LaunchAgents/${label}.plist"
    if _manifest_has_item "$plist" \
            ${SYGEN_MANIFEST_AUTOSTART_PLISTS[@]+"${SYGEN_MANIFEST_AUTOSTART_PLISTS[@]}"}; then
        return 0
    fi
    SYGEN_MANIFEST_AUTOSTART_PLISTS+=("$plist")
}

manifest_record_autostart_linux_unit() {
    # $1 = absolute path to an installed systemd unit file. Idempotent —
    # we install three units (core/admin/updater) so multiple calls are
    # expected; a duplicate path on a re-run must not re-add itself.
    local path="$1"
    if _manifest_has_item "$path" \
            ${SYGEN_MANIFEST_AUTOSTART_LINUX_UNITS[@]+"${SYGEN_MANIFEST_AUTOSTART_LINUX_UNITS[@]}"}; then
        return 0
    fi
    SYGEN_MANIFEST_AUTOSTART_LINUX_UNITS+=("$path")
}

manifest_set_native_paths() {
    # Record the resolved venv / admin paths and target versions. Called
    # once per install run from the install stage; safe to re-set on a
    # re-run since the paths are deterministic from $SYGEN_ROOT.
    SYGEN_MANIFEST_CORE_VENV="$1"
    SYGEN_MANIFEST_ADMIN_DIR="$2"
    SYGEN_MANIFEST_CORE_VERSION="$3"
    SYGEN_MANIFEST_ADMIN_VERSION="$4"
}

# Wrap `brew list || brew install` so each package call lands in the
# right manifest bucket. Used for the macOS deps loop.
manifest_brew_install() {
    local pkg="$1"
    if brew list "$pkg" >/dev/null 2>&1; then
        manifest_record_pkg_preexisting "$pkg"
    else
        manifest_record_pkg_installed "$pkg"
        brew install "$pkg"
    fi
}

# Atomic JSON writer. Schema is consumed by uninstall.sh AND by the
# /api/system/uninstall/preview endpoint — see CONTRACT_admin_api.md.
#
# Symlink hardening: bash can't open(O_NOFOLLOW), but we can refuse to
# write through a pre-existing symlink at either the temp or target path.
# The manifest lives inside $SYGEN_ROOT so a symlink there would have to
# be planted by something with $SYGEN_ROOT write access — at which point
# the host is already compromised — but the check is cheap and would
# catch a misconfigured symlink-following backup tool.
manifest_write() {
    local path="$1"
    [ -z "$path" ] && return 0
    local dir
    dir="$(dirname "$path")"
    mkdir -p "$dir" 2>/dev/null || true
    local tmp="$path.$$.tmp"
    if [ -L "$path" ]; then
        warn "manifest target is a symlink, refusing to follow: $path"
        return 1
    fi
    if [ -L "$tmp" ]; then
        warn "manifest temp path is a symlink, refusing to follow: $tmp"
        return 1
    fi
    local installed_at
    installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # umask 022 → 0644 on file create. Defensive belt+suspenders alongside
    # the chmod below — protects against a process-wide umask 077 caller
    # leaving the file 0600 (which would still be readable by sygen-core
    # since both run as the installing user, but unreadable by future
    # tooling that runs as a different user).
    local prev_umask
    prev_umask="$(umask)"
    umask 022
    {
        printf '{\n'
        # version=3 (v1.7+ native install): drops colima_profile_*, adds
        # install_mode + core_venv/admin_dir/core_version/admin_version
        # plus a multi-value autostart_linux_units. Older v1/v2 manifests
        # carry install_mode="docker" implicitly (absent ⇒ docker) — see
        # uninstall.sh's routing on $USE_NATIVE_MODE.
        printf '  "version": 3,\n'
        printf '  "install_mode": "native",\n'
        printf '  "installed_at": %s,\n' "$(json_escape "$installed_at")"
        printf '  "sygen_root": %s,\n' "$(json_escape "$SYGEN_ROOT")"
        printf '  "core_venv": %s,\n' "$(json_escape "$SYGEN_MANIFEST_CORE_VENV")"
        printf '  "admin_dir": %s,\n' "$(json_escape "$SYGEN_MANIFEST_ADMIN_DIR")"
        printf '  "core_version": %s,\n' "$(json_escape "$SYGEN_MANIFEST_CORE_VERSION")"
        printf '  "admin_version": %s,\n' "$(json_escape "$SYGEN_MANIFEST_ADMIN_VERSION")"
        printf '  "installed_pkgs": ['
        local first=1 p
        for p in ${SYGEN_MANIFEST_INSTALLED_PKGS[@]+"${SYGEN_MANIFEST_INSTALLED_PKGS[@]}"}; do
            [ $first -eq 0 ] && printf ', '
            printf '%s' "$(json_escape "$p")"; first=0
        done
        printf '],\n'
        printf '  "preexisting_pkgs": ['
        first=1
        for p in ${SYGEN_MANIFEST_PREEXISTING_PKGS[@]+"${SYGEN_MANIFEST_PREEXISTING_PKGS[@]}"}; do
            [ $first -eq 0 ] && printf ', '
            printf '%s' "$(json_escape "$p")"; first=0
        done
        printf '],\n'
        printf '  "plists_installed": ['
        first=1
        for p in ${SYGEN_MANIFEST_PLISTS[@]+"${SYGEN_MANIFEST_PLISTS[@]}"}; do
            [ $first -eq 0 ] && printf ', '
            printf '%s' "$(json_escape "$p")"; first=0
        done
        printf '],\n'
        # downloaded_files entries are pre-rendered JSON object literals
        # (see manifest_record_downloaded) so we just splice them with
        # commas — saves another shell-side JSON encoder.
        printf '  "downloaded_files": ['
        first=1
        for p in ${SYGEN_MANIFEST_DOWNLOADED[@]+"${SYGEN_MANIFEST_DOWNLOADED[@]}"}; do
            [ $first -eq 0 ] && printf ', '
            printf '%s' "$p"; first=0
        done
        printf '],\n'
        printf '  "autostart_macos_plists": ['
        first=1
        for p in ${SYGEN_MANIFEST_AUTOSTART_PLISTS[@]+"${SYGEN_MANIFEST_AUTOSTART_PLISTS[@]}"}; do
            [ $first -eq 0 ] && printf ', '
            printf '%s' "$(json_escape "$p")"; first=0
        done
        printf '],\n'
        printf '  "autostart_linux_units": ['
        first=1
        for p in ${SYGEN_MANIFEST_AUTOSTART_LINUX_UNITS[@]+"${SYGEN_MANIFEST_AUTOSTART_LINUX_UNITS[@]}"}; do
            [ $first -eq 0 ] && printf ', '
            printf '%s' "$(json_escape "$p")"; first=0
        done
        printf ']\n'
        printf '}\n'
    } > "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    mv "$tmp" "$path"
    umask "$prev_umask"
}

# Single-source manifest writer. Writes the canonical $SYGEN_ROOT path
# first, then mirrors it into the bind-mounted host_updates dir via cp
# so the preview endpoint and uninstall.sh can never disagree on what
# was recorded. Two independent manifest_write calls used to be possible
# (disk full on the second) — this one-source-of-truth approach makes
# that impossible.
manifest_write_all() {
    [ -z "${SYGEN_ROOT:-}" ] && return 0
    local primary="$SYGEN_ROOT/.install_manifest.json"
    local mirror="$SYGEN_ROOT/host_updates/install_manifest.json"
    if ! manifest_write "$primary"; then
        warn "could not write install manifest at $primary"
        return 1
    fi
    if [ -d "$SYGEN_ROOT/host_updates" ]; then
        if [ -L "$mirror" ]; then
            warn "manifest mirror is a symlink, refusing to overwrite: $mirror"
        else
            cp -f "$primary" "$mirror" 2>/dev/null \
                || warn "could not mirror manifest to $mirror — preview endpoint may report stale state"
        fi
    fi
    return 0
}

# Restore prior classification from disk so a re-run doesn't reclassify
# "preexisting at first install" → "installed by us" (which would let
# uninstall remove a brew package the user owned before sygen).
manifest_load() {
    local path="$1"
    [ -f "$path" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    local out
    out="$(python3 - "$path" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        m = json.load(f)
except Exception:
    sys.exit(0)
for p in m.get('installed_pkgs') or []:
    if isinstance(p, str): print('I\t' + p)
for p in m.get('preexisting_pkgs') or []:
    if isinstance(p, str): print('P\t' + p)
for p in m.get('plists_installed') or []:
    if isinstance(p, str): print('L\t' + p)
for d in m.get('downloaded_files') or []:
    if not isinstance(d, dict): continue
    p = d.get('path')
    if not isinstance(p, str) or not p: continue
    purpose = d.get('purpose')
    if not isinstance(purpose, str): purpose = ''
    size = d.get('size_bytes')
    if not isinstance(size, int) or size < 0: size = 0
    print('D\t' + json.dumps({'path': p, 'purpose': purpose, 'size_bytes': size}, separators=(',', ':')))
for p in m.get('autostart_macos_plists') or []:
    if isinstance(p, str) and p: print('A\t' + p)
# v3+ multi-value; v2 had a single autostart_linux_unit string — accept both.
units = m.get('autostart_linux_units')
if isinstance(units, list):
    for u in units:
        if isinstance(u, str) and u: print('U\t' + u)
else:
    u = m.get('autostart_linux_unit')
    if isinstance(u, str) and u: print('U\t' + u)
PY
)"
    [ -z "$out" ] && return 0
    while IFS=$'\t' read -r kind val; do
        case "$kind" in
            I) SYGEN_MANIFEST_INSTALLED_PKGS+=("$val") ;;
            P) SYGEN_MANIFEST_PREEXISTING_PKGS+=("$val") ;;
            L) SYGEN_MANIFEST_PLISTS+=("$val") ;;
            D) SYGEN_MANIFEST_DOWNLOADED+=("$val") ;;
            A) SYGEN_MANIFEST_AUTOSTART_PLISTS+=("$val") ;;
            U) SYGEN_MANIFEST_AUTOSTART_LINUX_UNITS+=("$val") ;;
        esac
    done <<< "$out"
}

# Strict allowlist validators for the two values that come back from the
# Cloudflare provisioning Worker. Both are interpolated into shell
# scripts, nginx config, JSON config, and `rm -rf` paths — a Worker
# compromise OR an MITM during the provision request would otherwise
# pivot to root code execution on every fresh install. Validate ONCE
# right after the jq -r parse so all downstream paths are clean.
#
# FQDN: lowercase DNS-safe label[.label]+, RFC 1035 length caps. Rejects
# any whitespace, shell metacharacter, '/', '..', '#', quotes — i.e.
# everything that could break out of a `server_name`/`rm -rf <path>`/
# JSON-string context.
validate_fqdn() {
    local fqdn=${1-}
    local label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
    local re="^${label}(\.${label})+$"
    if [ "${#fqdn}" -lt 1 ] || [ "${#fqdn}" -gt 253 ]; then return 1; fi
    [[ "$fqdn" =~ $re ]] || return 1
    return 0
}

# DNS-challenge URL: must be HTTPS to a known-safe host expression. Rejects
# anything containing shell metacharacters or quotes — the value lands
# inside double-quoted bash assignments in /usr/local/sbin/sygen-acme-*.sh
# generated below. Regex stored in a variable so bash doesn't word-split
# the metacharacters inside [[ =~ ]].
validate_https_url() {
    local url=${1-}
    local re='^https://[A-Za-z0-9._/?:&=%~+-]+$'
    if [ "${#url}" -lt 8 ] || [ "${#url}" -gt 2048 ]; then return 1; fi
    case "$url" in
        https://*) ;;
        *) return 1 ;;
    esac
    [[ "$url" =~ $re ]] || return 1
    return 0
}

emit_json_error() {
    if [ "$JSON_OUTPUT" != "1" ] || [ "$JSON_DONE" = "1" ]; then return 0; fi
    JSON_DONE=1
    local err="${1:-install failed}"
    local details="${2:-}"
    printf '{"ok":false,"error":%s,"stage":%s,"details":%s}\n' \
        "$(json_escape "$err")" \
        "$(json_escape "$STAGE")" \
        "$(json_escape "$details")"
}

# _release_and_die — used in the cert-issuance cascade to fail cleanly.
#   1. Best-effort release of the Worker subdomain reservation, so a
#      cert-fail doesn't leak a 30-day KV slot. Worker is the source of
#      truth for the FQDN's lifecycle.
#   2. Best-effort cleanup of any half-written LE/ZeroSSL state on disk
#      so a re-run from the iOS wizard starts clean.
#   3. Structured JSON error in $JSON_OUTPUT mode (so the iOS / web wizard
#      can distinguish "rate-limited, retry later" from "config wrong").
#   4. die() with the same message — non-JSON callers see it on stderr.
_release_and_die() {
    local err_code="${1:-cert_failed}"
    local details="${2:-}"
    if [ -n "${SYGEN_INSTALL_TOKEN:-}" ]; then
        warn "Releasing subdomain reservation back to the pool (cert failure)"
        curl -fsS --ipv4 -X DELETE \
            -H "Content-Type: application/json" \
            -d "$(jq -nc --arg t "$SYGEN_INSTALL_TOKEN" '{install_token:$t}')" \
            "https://install.${DOMAIN}/api/release" >/dev/null 2>&1 || true
    fi
    if [ -n "${FQDN:-}" ]; then
        # CERTBOT_LIVE_DIR defaults to /etc/letsencrypt; macOS publicdomain
        # mode points it at $SYGEN_ROOT/letsencrypt instead. Use the live
        # value so we don't try to rm -rf a path that doesn't exist on the
        # other OS (harmless but noisy in dry-runs).
        local le_root="${CERTBOT_LIVE_DIR:-/etc/letsencrypt}"
        rm -rf "$le_root/live/$FQDN" \
               "$le_root/archive/$FQDN" \
               "$le_root/renewal/$FQDN.conf" 2>/dev/null || true
    fi
    if [ "$JSON_OUTPUT" = "1" ] && [ "$JSON_DONE" = "0" ]; then
        JSON_DONE=1
        printf '{"ok":false,"error":%s,"stage":%s,"details":%s,"retry_after_hours":1}\n' \
            "$(json_escape "$err_code")" \
            "$(json_escape "$STAGE")" \
            "$(json_escape "$details")"
        exit 1
    fi
    die "$err_code: $details"
}

# apt-get retry on lock contention. unattended-upgrades or the cloud-init
# package run during the first 5 min of a freshly-provisioned VPS holds
# /var/lib/dpkg/lock-frontend; apt-get then aborts with "Could not get
# lock". Wrap every apt-get call so we wait the upgrade out instead of
# bailing the whole install. ~12 attempts × 5 s = 1 min total budget.
apt_retry() {
    local i=0
    while [ $i -lt 12 ]; do
        if apt-get "$@"; then return 0; fi
        i=$((i + 1))
        warn "apt-get failed (attempt $i/12) — likely dpkg lock; retrying in 5 s"
        sleep 5
    done
    die "apt-get failed after 60 s — likely locked by unattended-upgrades. Try: sudo killall apt-get apt; wait 5 min and re-run."
}

# Catch unexpected non-zero exits (set -e failures from commands that
# don't go through die()) so JSON consumers always get one final line.
# Also flushes whatever manifest state we accumulated so far so a partial
# install (curl timeout in stage X, brew install fail, etc.) leaves a
# manifest behind. Without this, a re-run after a partial would re-see
# brew packages as already-on-disk and reclassify them as "preexisting"
# — and a later uninstall would orphan them on the host.
on_exit() {
    local code=$?
    if [ -n "${SYGEN_ROOT:-}" ] && [ -d "$SYGEN_ROOT" ]; then
        manifest_write_all || true
    fi
    if [ "$JSON_OUTPUT" = "1" ] && [ "$JSON_DONE" = "0" ] && [ "$code" -ne 0 ]; then
        emit_json_error "install script exited with code $code" "stage=$STAGE"
    fi
}
trap on_exit EXIT

# ---------- Platform detection ----------
OS="$(uname -s)"
LOCAL_MODE=0
# Sub-mode (cross-platform meaning):
#   localhost     — macOS only: Colima + http://localhost (iPhone can't reach)
#   tailscale     — macOS or Linux: HTTPS via `tailscale serve` on the tailnet.
#                   Use case: home server / NAT'd box reachable only by tailnet
#                   peers. No public IP needed, no Worker subdomain, no LE cert
#                   (Tailscale issues + renews the cert via MagicDNS+ACME).
#   publicdomain  — macOS only: Worker DNS-01 + brew nginx + LE cert + router PF
#                   (Linux equivalent IS auto-mode — same Worker provisioning,
#                    no separate "publicdomain" submode needed.)
SELF_HOSTED_SUBMODE=""
case "$OS" in
    Darwin)
        LOCAL_MODE=1
        SELF_HOSTED_SUBMODE="${SELF_HOSTED_MODE:-}"
        ;;
    Linux)
        # Linux supports SELF_HOSTED_MODE=tailscale only. localhost makes no
        # sense for a headless server; publicdomain is just the existing
        # auto-mode by another name. Reject other submode values explicitly.
        SELF_HOSTED_SUBMODE="${SELF_HOSTED_MODE:-}"
        case "$SELF_HOSTED_SUBMODE" in
            ""|tailscale) ;;
            localhost|publicdomain)
                die "SELF_HOSTED_MODE='${SELF_HOSTED_SUBMODE}' is macOS-only. On Linux use auto-mode (unset env) or SELF_HOSTED_MODE=tailscale."
                ;;
            *)
                die "Invalid SELF_HOSTED_MODE='${SELF_HOSTED_SUBMODE}' on Linux (expected: tailscale or unset)"
                ;;
        esac
        ;;
    *)
        die "Unsupported OS: $OS. Supported: Linux (Debian/Ubuntu), macOS."
        ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64|aarch64|arm64) ;;
    *) die "Unsupported architecture: $ARCH. Supported: x86_64/amd64, aarch64/arm64." ;;
esac

# Resolve macOS sub-mode (auto-detect / prompt / default) before we touch any
# env-dependent state. We keep this block self-contained so the rest of the
# script can branch on $SELF_HOSTED_SUBMODE without re-checking $SELF_HOSTED_MODE.
if [ $LOCAL_MODE -eq 1 ]; then
    case "${SELF_HOSTED_SUBMODE:-}" in
        ""|localhost|tailscale|publicdomain) ;;
        *)
            die "Invalid SELF_HOSTED_MODE='${SELF_HOSTED_SUBMODE}' (expected: localhost, tailscale, publicdomain, or unset)"
            ;;
    esac

    if [ -z "$SELF_HOSTED_SUBMODE" ]; then
        # Auto-detect: a logged-in Tailscale tailnet means the operator
        # almost certainly wants Tailscale mode (iPhone reachability).
        # Otherwise default to legacy localhost behaviour.
        ts_available=0
        if command -v tailscale >/dev/null 2>&1 \
                && tailscale status >/dev/null 2>&1; then
            ts_available=1
        fi

        # Try interactive prompt for human installs (never via curl|bash JSON).
        # /dev/tty is set even when stdin is the curl pipe, so we explicitly
        # try it before giving up and falling back to a default.
        prompt_choice=""
        if [ "$JSON_OUTPUT" != "1" ] && [ -e /dev/tty ]; then
            {
                echo ""
                echo "macOS self-hosted mode — choose how iPhone will reach this Mac:"
                if [ "$ts_available" = "1" ]; then
                    echo "  [1] tailscale     (recommended — Tailscale tailnet detected)"
                else
                    echo "  [1] tailscale     (Tailscale not installed — pick this only after"
                    echo "                     installing it from https://tailscale.com/kb/1017/install)"
                fi
                echo "  [2] publicdomain  (advanced — needs NAT port forwarding 80/443 on your router)"
                echo "  [3] localhost     (Mac-only access, no iPhone connectivity)"
                if [ "$ts_available" = "1" ]; then
                    printf "Choice [1]: "
                else
                    printf "Choice [3]: "
                fi
            } > /dev/tty 2>&1 || true
            read -r prompt_choice < /dev/tty 2>/dev/null || prompt_choice=""
        fi

        case "${prompt_choice:-}" in
            1|tailscale)    SELF_HOSTED_SUBMODE="tailscale" ;;
            2|publicdomain) SELF_HOSTED_SUBMODE="publicdomain" ;;
            3|localhost)    SELF_HOSTED_SUBMODE="localhost" ;;
            "")
                if [ "$ts_available" = "1" ]; then
                    SELF_HOSTED_SUBMODE="tailscale"
                else
                    SELF_HOSTED_SUBMODE="localhost"
                fi
                ;;
            *)
                die "Invalid choice '$prompt_choice' (expected 1/2/3 or tailscale/publicdomain/localhost)"
                ;;
        esac
    fi
fi

# ---------- Env parsing (conditional) ----------
DOMAIN="${SYGEN_DOMAIN:-sygen.pro}"
# Default to raw.githubusercontent.com so re-running install.sh always
# fetches the current nginx.conf.tmpl + service templates. The GitHub
# Pages CDN at install.sygen.pro caches for ~10 min, which causes
# operators to silently install yesterday's templates. Override
# SYGEN_INSTALL_BASE_URL when testing a fork.
BASE_URL="${SYGEN_INSTALL_BASE_URL:-https://raw.githubusercontent.com/alexeymorozua/sygen-install/main}"
# Default versions are pinned to the tags that exist as GitHub Releases.
# Override SYGEN_CORE_VERSION / SYGEN_ADMIN_VERSION to install a different
# release. SYGEN_RELEASE_SOURCE=source pulls from local checkouts
# (SYGEN_CORE_SOURCE_DIR / SYGEN_ADMIN_SOURCE_DIR) — the transitional path
# for a freshly-cut commit that isn't released yet.
CORE_VERSION="${SYGEN_CORE_VERSION:-1.6.75}"
ADMIN_VERSION="${SYGEN_ADMIN_VERSION:-0.5.55}"
RELEASE_SOURCE="${SYGEN_RELEASE_SOURCE:-github}"
CORE_SOURCE_DIR="${SYGEN_CORE_SOURCE_DIR:-}"
ADMIN_SOURCE_DIR="${SYGEN_ADMIN_SOURCE_DIR:-}"
CORE_GITHUB_REPO="${SYGEN_CORE_GITHUB_REPO:-alexeymorozua/sygen}"
ADMIN_GITHUB_REPO="${SYGEN_ADMIN_GITHUB_REPO:-alexeymorozua/sygen-admin}"

# AUTO_MODE=1 means "ask install.sygen.pro for a free <id>.sygen.pro".
# The Worker also creates the A record (using CF-Connecting-IP). install.sh
# never holds a Cloudflare token in auto-mode — DNS-01 challenges are
# answered through Worker-mediated /api/dns-challenge endpoints (see
# subdomain-service/README.md). AUTO_MODE=0 means the operator supplied
# their own subdomain + Cloudflare token (legacy / admin-managed installs).
# AUTO_MODE_REUSE=1 means we're re-running install.sh on a host that already
# went through provision once; we must NOT call /api/provision again (would
# orphan the live record + waste a slot) — we re-read the saved token + fqdn
# from the existing .env / config.json instead.
AUTO_MODE=0
AUTO_MODE_REUSE=0
SYGEN_INSTALL_TOKEN=""
SYGEN_INSTALL_HEARTBEAT_URL=""
SYGEN_DNS_CHALLENGE_URL=""
PROVISION_URL="${SYGEN_PROVISION_URL:-https://install.${DOMAIN}/api/provision}"

if [ $LOCAL_MODE -eq 1 ]; then
    SYGEN_ROOT="$HOME/.sygen-local"
    SYGEN_ADMIN_PORT="${SYGEN_ADMIN_PORT:-8080}"

    case "$SELF_HOSTED_SUBMODE" in
        localhost)
            SUB="${SYGEN_SUBDOMAIN:-local}"
            FQDN="localhost"
            ADMIN_URL="http://localhost:${SYGEN_ADMIN_PORT}"
            CORS_ORIGIN="http://localhost:${SYGEN_ADMIN_PORT}"
            log "macOS detected — localhost mode (Colima + http://localhost, no TLS)"
            warn "  iPhone cannot reach http://localhost (App Transport Security blocks plain HTTP)."
            warn "  For iPhone access, re-run with SELF_HOSTED_MODE=tailscale or =publicdomain."
            ;;
        tailscale)
            # Pre-flight: CLI must be reachable AND the daemon authenticated.
            # We don't try to log the user in — Tailscale auth flows are
            # interactive (browser/SSO) and beyond install.sh's mandate.
            #
            # Tailscale 1.96+ from the Mac App Store does NOT install a
            # /usr/local/bin/tailscale wrapper; the `install-cli` subcommand
            # is gone. So we look in PATH first, then fall back to the
            # in-bundle binary at /Applications/Tailscale.app/... — calling
            # it directly works (whereas a symlink to it crashes with a
            # bundleIdentifier registry error). Variable is exported so
            # later `tailscale serve` calls use the same resolved path.
            TAILSCALE_BIN=""
            if command -v tailscale >/dev/null 2>&1; then
                TAILSCALE_BIN="$(command -v tailscale)"
            elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
                TAILSCALE_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
                log "Using Tailscale binary from /Applications/Tailscale.app (CLI not in PATH)"
            else
                die "SELF_HOSTED_MODE=tailscale but Tailscale not found. Install from https://tailscale.com/download (Mac App Store works), run 'tailscale up' (or open the app and log in), then retry."
            fi
            export TAILSCALE_BIN
            ts_status_json="$("$TAILSCALE_BIN" status --json 2>/dev/null)" \
                || die "Tailscale daemon not running or device not logged in. Open Tailscale.app (or run 'tailscale up') and retry."

            # jq isn't guaranteed yet on a fresh Mac (we install it below) —
            # use python3 (always present on modern macOS) to extract DNSName
            # so the pre-flight error fires before we run brew install.
            ts_fqdn="$(printf '%s' "$ts_status_json" \
                | python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("Self") or {}).get("DNSName") or "").rstrip("."))' \
                2>/dev/null)"
            if [ -z "$ts_fqdn" ]; then
                die "Could not determine Tailscale FQDN (empty Self.DNSName). Enable MagicDNS + HTTPS Certificates in your tailnet admin: https://login.tailscale.com/admin/dns"
            fi

            FQDN="$ts_fqdn"
            SUB="${FQDN%%.*}"
            ADMIN_URL="https://$FQDN"
            CORS_ORIGIN="https://$FQDN"
            log "macOS detected — Tailscale mode (HTTPS via tailnet)"
            log "  fqdn=$FQDN"
            log "  iPhone must also be on this tailnet (install Tailscale from the App Store)"
            ;;
        publicdomain)
            # Mirrors Linux auto-mode: Worker mints a free <id>.sygen.pro and
            # creates the A record from the request's CF-Connecting-IP. No
            # Cloudflare token on the host. Differs from Linux only in
            # platform glue (brew nginx + brew certbot + Colima).
            AUTO_MODE=1
            SUB=""        # populated by /api/provision below
            FQDN=""       # populated by /api/provision below
            ADMIN_URL=""  # populated by /api/provision below
            CORS_ORIGIN=""
            log "macOS detected — public-domain mode (Worker /api/provision + brew nginx)"
            warn "  iPhone access requires NAT port forwarding on your router:"
            warn "    external 80  -> this Mac, port 80"
            warn "    external 443 -> this Mac, port 443"
            warn "  Without those, the cert is still issued (DNS-01) but the iPhone can't reach the Mac."
            ;;
        *)
            die "internal: SELF_HOSTED_SUBMODE='$SELF_HOSTED_SUBMODE' not handled"
            ;;
    esac
elif [ "$SELF_HOSTED_SUBMODE" = "tailscale" ]; then
    # Linux + Tailscale-mode: server lives in a tailnet, accessible by
    # MagicDNS hostname only. No Worker subdomain, no public IP needed,
    # no LE cert dance — `tailscale serve` terminates TLS using the cert
    # Tailscale auto-issues + auto-renews. iPhone must also be on the
    # same tailnet to reach the box.
    SYGEN_ROOT="/srv/sygen"
    SYGEN_ADMIN_PORT="${SYGEN_ADMIN_PORT:-8080}"
    if [ "$EUID" -ne 0 ]; then
        die "Run as root on Linux (sudo bash or ssh root@...)"
    fi

    # Pre-flight: tailscale CLI installed AND daemon up. If CLI is missing
    # we install it via Tailscale's official apt repo (idempotent), but we
    # do NOT auto-`tailscale up` because that's an interactive browser auth.
    if ! command -v tailscale >/dev/null 2>&1; then
        log "Installing Tailscale via official apt repo"
        export DEBIAN_FRONTEND=noninteractive
        apt_retry update -qq
        apt_retry install -y -qq curl gnupg
        # Detect distro codename for the Tailscale repo URL (bookworm/bullseye/
        # noble/jammy/etc). Falls back to bookworm — works for current Debian
        # stable + Ubuntu LTS; Tailscale ships universal packages.
        . /etc/os-release 2>/dev/null || true
        TS_CODENAME="${VERSION_CODENAME:-bookworm}"
        TS_DISTRO="${ID:-debian}"
        curl -fsSL "https://pkgs.tailscale.com/stable/${TS_DISTRO}/${TS_CODENAME}.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
            || die "Failed to fetch Tailscale apt key (codename=${TS_CODENAME}, distro=${TS_DISTRO})"
        curl -fsSL "https://pkgs.tailscale.com/stable/${TS_DISTRO}/${TS_CODENAME}.tailscale-keyring.list" \
            -o /etc/apt/sources.list.d/tailscale.list \
            || die "Failed to fetch Tailscale apt sources list"
        apt_retry update -qq
        apt_retry install -y -qq tailscale
        die "Tailscale installed. Run 'sudo tailscale up' to log in to your tailnet, then re-run this installer."
    fi

    # Linux apt-installed tailscale is always in PATH; macOS may need a
    # bundle-resolved binary. TAILSCALE_BIN is the single source of truth
    # for every later invocation.
    TAILSCALE_BIN="$(command -v tailscale)"
    export TAILSCALE_BIN
    ts_status_json="$("$TAILSCALE_BIN" status --json 2>/dev/null)" \
        || die "Tailscale daemon not running or device not logged in. Run 'sudo tailscale up' and retry."

    # python3 is preinstalled on every modern Debian/Ubuntu. Same parser
    # as the macOS branch — keep them in sync.
    ts_fqdn="$(printf '%s' "$ts_status_json" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("Self") or {}).get("DNSName") or "").rstrip("."))' \
        2>/dev/null)"
    if [ -z "$ts_fqdn" ]; then
        die "Could not determine Tailscale FQDN (empty Self.DNSName). Enable MagicDNS + HTTPS Certificates in your tailnet admin: https://login.tailscale.com/admin/dns"
    fi

    FQDN="$ts_fqdn"
    SUB="${FQDN%%.*}"
    ADMIN_URL="https://$FQDN"
    CORS_ORIGIN="https://$FQDN"
    log "Linux + Tailscale mode (HTTPS via tailnet $FQDN)"
    log "  iPhone must also be on this tailnet to reach the box"
elif [ -z "${SYGEN_SUBDOMAIN:-}" ] && [ -z "${CF_API_TOKEN:-}" ]; then
    # Auto-mode — provision a free <id>.sygen.pro from install.sygen.pro.
    # FQDN/SUB/CF_API_TOKEN/CF_ZONE_ID/CF_RECORD_ID are filled in by the
    # provision step below, after deps (jq) are installed.
    AUTO_MODE=1
    SYGEN_ROOT="/srv/sygen"
    log "Linux detected — auto-mode (will provision <id>.${DOMAIN} from $PROVISION_URL)"
    if [ "$EUID" -ne 0 ]; then
        die "Run as root on Linux (sudo bash or ssh root@...)"
    fi
else
    SUB="${SYGEN_SUBDOMAIN:?SYGEN_SUBDOMAIN required (or unset both SYGEN_SUBDOMAIN and CF_API_TOKEN for auto-mode)}"
    FQDN="${SUB}.${DOMAIN}"
    # Validate operator-supplied subdomain — same allowlist as auto-mode
    # so a typo / shell metachar / path-traversal can't slip through.
    validate_fqdn "$FQDN" \
        || die "SYGEN_SUBDOMAIN '$SUB' is not a valid DNS label (allowed [a-z0-9-], 1-63 chars)"
    CF_API_TOKEN="${CF_API_TOKEN:?CF_API_TOKEN required for custom-mode install}"
    CF_ZONE_ID="${CF_ZONE_ID:?CF_ZONE_ID required for custom-mode install}"
    SYGEN_ROOT="/srv/sygen"
    ADMIN_URL="https://$FQDN"
    CORS_ORIGIN="https://$FQDN"
    log "Linux detected — custom mode (subdomain $FQDN supplied by operator)"
    if [ "$EUID" -ne 0 ]; then
        die "Run as root on Linux (sudo bash or ssh root@...)"
    fi
fi

if [ $LOCAL_MODE -eq 0 ] && [ "$AUTO_MODE" -eq 0 ]; then
    . /etc/os-release 2>/dev/null || true
    log "Host: ${PRETTY_NAME:-unknown} — deploying $FQDN"
elif [ $LOCAL_MODE -eq 0 ]; then
    . /etc/os-release 2>/dev/null || true
    log "Host: ${PRETTY_NAME:-unknown} — fqdn will be assigned by provisioning service"
elif [ "$SELF_HOSTED_SUBMODE" = "publicdomain" ]; then
    log "Host: macOS $(sw_vers -productVersion 2>/dev/null || echo unknown) — fqdn will be assigned by provisioning service"
else
    log "Host: macOS $(sw_vers -productVersion 2>/dev/null || echo unknown) — deploying $ADMIN_URL"
fi

# Manifest path is bound to the now-final SYGEN_ROOT. Load any prior
# manifest BEFORE the package install loops so re-runs preserve the
# original classification (a package marked "preexisting" at first
# install must not flip to "installed_by_us" just because it's now on
# disk thanks to the previous sygen install).
SYGEN_MANIFEST_PATH="$SYGEN_ROOT/.install_manifest.json"
manifest_load "$SYGEN_MANIFEST_PATH"

# ---------- 1. System packages ----------
STAGE="deps"
if [ $LOCAL_MODE -eq 0 ]; then
    log "Installing system packages (native install — no Docker)"
    export DEBIAN_FRONTEND=noninteractive
    apt_retry update -qq

    # Base packages always needed. nginx + certbot ONLY for paths that
    # terminate TLS themselves (auto-mode + custom-mode). Tailscale-mode
    # delegates TLS to `tailscale serve` so nginx + certbot are skipped.
    # python3-venv: required for `python3 -m venv`. python3-pip: needed for
    # `pip install` inside the venv (the venv inherits pip from the base).
    # P1-10: include `tar` defensively — stock Debian/Ubuntu has it but
    # minimal LXC/container images sometimes don't, and we extract the
    # admin tarball during install.
    BASE_PKGS="ca-certificates curl jq gnupg openssl python3 python3-venv python3-pip build-essential tar"
    if [ "$SELF_HOSTED_SUBMODE" = "tailscale" ]; then
        # shellcheck disable=SC2086
        apt_retry install -y -qq $BASE_PKGS
    else
        # shellcheck disable=SC2086
        apt_retry install -y -qq $BASE_PKGS nginx certbot python3-certbot-dns-cloudflare
    fi

    # Node 22 LTS via NodeSource — Ubuntu 24.04 ships Node 18, which is
    # too old for current Next.js. Idempotent: setup_22.x is a no-op if
    # the apt source is already present.
    if ! command -v node >/dev/null 2>&1 || ! node -v 2>/dev/null | grep -qE '^v(2[2-9]|[3-9][0-9])\.'; then
        log "Installing Node.js 22 LTS via NodeSource"
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        apt_retry install -y -qq nodejs
    fi

    # whisper-cli is best-effort on Linux (apt package is gated to
    # trixie+/24.10+). Fall through quietly — sygen-core ships no longer
    # ships whisper-cli with the package, so we install whisper.cpp via
    # apt where available and download the model regardless (handled in
    # the whisper section).
    if ! command -v whisper-cli >/dev/null 2>&1 && ! command -v whisper-cpp >/dev/null 2>&1; then
        apt_retry install -y -qq whisper-cpp 2>/dev/null \
            || apt_retry install -y -qq whisper.cpp 2>/dev/null \
            || warn "whisper.cpp not installable via apt on this distro — voice transcription disabled until installed manually"
    fi

    # Host metrics (Linux): /proc reports real values directly, no
    # need for a host-side daemon to bypass a VM (we no longer have one).
    # Keep the env-file generation conditional on macOS only.
else
    # ---------- 1-macos. Brew deps (python@3.14 + node@22 + whisper-cpp) ----------
    log "macOS: checking Homebrew"
    if ! command -v brew >/dev/null 2>&1; then
        die "Homebrew required on macOS. Install from https://brew.sh then re-run."
    fi

    log "macOS: installing native runtime deps (python@3.14, node@22, jq, whisper-cpp)"
    # Native install needs:
    #   python@3.14  — runtime for sygen-core + sygen-updater venv
    #   node@22      — runtime for sygen-admin (Next.js standalone)
    #   jq           — used by provision response parsing, .env edits
    #   whisper-cpp  — voice transcription binary (ggml model fetched separately)
    # nginx + pipx (certbot) are publicdomain-only.
    macos_pkgs=(python@3.14 node@22 jq whisper-cpp)
    if [ "$SELF_HOSTED_SUBMODE" = "publicdomain" ]; then
        # certbot via pipx (isolated venv) — see publicdomain block below.
        macos_pkgs+=(nginx pipx)
    fi
    for pkg in "${macos_pkgs[@]}"; do
        manifest_brew_install "$pkg"
    done

    # certbot in an isolated pipx venv — first run creates it, re-runs are
    # a no-op via `pipx list | grep`. inject pulls in the manual-DNS
    # plugin we use for Worker-mediated DNS-01 (no provider key needed
    # at install time; the auth-hook script POSTs to install.sygen.pro).
    if [ "$SELF_HOSTED_SUBMODE" = "publicdomain" ]; then
        pipx ensurepath >/dev/null 2>&1 || true
        export PATH="$HOME/.local/bin:$PATH"
        if ! pipx list 2>/dev/null | grep -q "package certbot "; then
            log "macOS: installing certbot in isolated pipx venv"
            pipx install certbot >/dev/null \
                || die "pipx install certbot failed — see error above"
        fi
        if [ -n "${CF_API_TOKEN:-}" ]; then
            pipx inject certbot certbot-dns-cloudflare >/dev/null 2>&1 \
                || warn "pipx inject certbot-dns-cloudflare failed — custom-mode cert may fail"
        fi
    fi

    # Resolve Python + Node binaries. brew installs python@3.14 as
    # `python3.14` (not the default `python3`) and node@22 as `node` —
    # but only after `brew link --force --overwrite node@22`. Resolve
    # paths explicitly so we can hardcode them in the venv shebang and
    # the launchd plists below.
    PYTHON_BREW_BIN="$(brew --prefix python@3.14 2>/dev/null)/bin/python3.14"
    if [ ! -x "$PYTHON_BREW_BIN" ]; then
        PYTHON_BREW_BIN="$(command -v python3.14 || true)"
    fi
    [ -x "$PYTHON_BREW_BIN" ] \
        || die "python3.14 not found after brew install — try: brew link --overwrite python@3.14"

    NODE_BREW_BIN="$(brew --prefix node@22 2>/dev/null)/bin/node"
    if [ ! -x "$NODE_BREW_BIN" ]; then
        NODE_BREW_BIN="$(command -v node || true)"
    fi
    [ -x "$NODE_BREW_BIN" ] \
        || die "node not found after brew install — try: brew link --overwrite node@22"

    # Detect host CPU/RAM/disk so the core agent can report host-true
    # metrics on the dashboard. Native processes already see real host
    # values via psutil, but we keep these env vars for parity with the
    # cross-platform code path that consumes SYGEN_HOST_*.
    HOST_CPU="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    HOST_RAM_BYTES="$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0)"
    HOST_RAM_GB=$(( HOST_RAM_BYTES / 1024 / 1024 / 1024 ))
    HOST_CPU_MODEL="$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    HOST_DISK_TOTAL_KB="$(df -k / 2>/dev/null | awk 'NR==2 {print $2}')"
    HOST_DISK_TOTAL_BYTES=$(( ${HOST_DISK_TOTAL_KB:-0} * 1024 ))
    HOST_DISK_TOTAL_GB=$(( HOST_DISK_TOTAL_BYTES / 1024 / 1024 / 1024 ))

    if [ "$HOST_RAM_GB" -gt 0 ] && [ "$HOST_RAM_GB" -lt 8 ]; then
        die "host has only ${HOST_RAM_GB} GB RAM — sygen requires at least 8 GB native (16 GB recommended for active workloads). Upgrade hardware or use a remote VPS install."
    fi

    {
        printf 'SYGEN_HOST_CPU_COUNT=%s\n' "$HOST_CPU"
        printf 'SYGEN_HOST_CPU_MODEL=%s\n' "$HOST_CPU_MODEL"
        printf 'SYGEN_HOST_RAM_TOTAL_BYTES=%s\n' "$HOST_RAM_BYTES"
        printf 'SYGEN_HOST_DISK_TOTAL_BYTES=%s\n' "$HOST_DISK_TOTAL_BYTES"
    } > /tmp/sygen-host-metrics.env
fi

# Resolve PYTHON_BIN + NODE_BIN once so install/autostart sections agree.
# Linux: apt-installed python3 (3.12+ on Ubuntu 24.04 is fine — sygen
# pyproject.toml requires >=3.11). macOS: the brew @3.14 paths set above.
if [ $LOCAL_MODE -eq 1 ]; then
    PYTHON_BIN="$PYTHON_BREW_BIN"
    NODE_BIN="$NODE_BREW_BIN"
else
    PYTHON_BIN="$(command -v python3 || true)"
    NODE_BIN="$(command -v node || true)"
    [ -x "$PYTHON_BIN" ] || die "python3 not found after apt install"
    [ -x "$NODE_BIN" ] || die "node not found after NodeSource install"
fi
log "  python: $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"
log "  node:   $NODE_BIN ($("$NODE_BIN" --version 2>&1))"

# ---------- 1b. Unattended-upgrades (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
    log "Enabling unattended-upgrades"
    apt_retry install -y -qq unattended-upgrades

    # Idempotently enable daily check + unattended install. We deliberately
    # don't touch /etc/apt/apt.conf.d/50unattended-upgrades — the distro
    # default ships security-only, which is what we want.
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT
    if systemctl list-unit-files unattended-upgrades.service >/dev/null 2>&1; then
        systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
    fi
fi

# ---------- 1c. Auto-provision subdomain (auto-mode: Linux or macOS publicdomain) ----------
# Runs after deps install so jq + curl are guaranteed. The Worker creates the
# A record pointing at the CF-Connecting-IP it sees on this request; install.sh
# never holds a Cloudflare token. ACME DNS-01 challenges go through Worker-
# mediated endpoints (see subdomain-service for the contract).
if [ "$AUTO_MODE" -eq 1 ]; then
    STAGE="provision"

    # Re-run detection: a previous successful auto-mode install left
    # SYGEN_INSTALL_TOKEN in /srv/sygen/.env. Calling /api/provision again
    # would burn a fresh slot AND drop the existing live DNS/TLS into limbo,
    # so we reuse what's already on disk instead — UNLESS the Worker has
    # since sweep'd the reservation (>30 days no heartbeat: VPS was down,
    # crontab broken, etc). In that case the install_token + cached FQDN
    # are stale: A record is gone, heartbeat URL returns 404. We detect
    # that with a probe call and fall through to fresh provision, leaving
    # /srv/sygen/data/* untouched so the user keeps their data.
    if [ -f "$SYGEN_ROOT/.env" ] && grep -q '^SYGEN_INSTALL_TOKEN=' "$SYGEN_ROOT/.env"; then
        SYGEN_INSTALL_TOKEN=$(grep '^SYGEN_INSTALL_TOKEN=' "$SYGEN_ROOT/.env" | head -n1 | cut -d= -f2-)
        SYGEN_INSTALL_HEARTBEAT_URL=$(grep '^SYGEN_INSTALL_HEARTBEAT_URL=' "$SYGEN_ROOT/.env" 2>/dev/null | head -n1 | cut -d= -f2- || true)
        SYGEN_DNS_CHALLENGE_URL=$(grep '^SYGEN_DNS_CHALLENGE_URL=' "$SYGEN_ROOT/.env" 2>/dev/null | head -n1 | cut -d= -f2- || true)

        # Probe Worker — is the reservation still alive? Default to the
        # canonical heartbeat URL if .env didn't carry one (older installs).
        PROBE_URL="${SYGEN_INSTALL_HEARTBEAT_URL:-https://install.${DOMAIN}/api/heartbeat}"
        log "Auto-mode re-run: probing Worker reservation (heartbeat $PROBE_URL)"
        PROBE_HTTP=$(curl -sS --ipv4 -o /tmp/sygen-heartbeat-probe.json -w '%{http_code}' \
            -X POST -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg t "$SYGEN_INSTALL_TOKEN" '{install_token:$t}')" \
            "$PROBE_URL" 2>/dev/null || echo "000")

        if [ "$PROBE_HTTP" = "200" ]; then
            AUTO_MODE_REUSE=1
            log "Auto-mode re-run: reservation alive — skipping provision"
            if [ -f "$SYGEN_ROOT/data/config/config.json" ]; then
                SUB=$(jq -r '.instance_name // empty' "$SYGEN_ROOT/data/config/config.json" 2>/dev/null || true)
            fi
            [ -n "${SUB:-}" ] || die "auto-mode re-run: heartbeat ok but cannot recover subdomain — config.json missing or has no instance_name. Wipe $SYGEN_ROOT/data/config and rerun."
            FQDN="${SUB}.${DOMAIN}"
            ADMIN_URL="https://$FQDN"
            CORS_ORIGIN="https://$FQDN"
            log "Auto-mode re-run: continuing with existing $FQDN"
        elif [ "$PROBE_HTTP" = "404" ] || [ "$PROBE_HTTP" = "401" ]; then
            warn "Auto-mode re-run: Worker dropped the reservation (probe HTTP $PROBE_HTTP)."
            warn "  This means the VPS was offline >30 days OR weekly heartbeats were not running."
            warn "  Recovering: requesting a NEW subdomain — the old one is freed."
            warn "  YOUR DATA IS PRESERVED ($SYGEN_ROOT/data/*). Only the URL will change."
            # Strip the now-orphaned token + URL hints from .env so the
            # install.sh blocks below treat this as a fresh provision but
            # DON'T touch /srv/sygen/data — the user's DB, secrets, sessions
            # all survive. config.json's instance_name will be overwritten
            # below once the new subdomain is assigned.
            sed -i.bak \
                -e '/^SYGEN_INSTALL_TOKEN=/d' \
                -e '/^SYGEN_INSTALL_HEARTBEAT_URL=/d' \
                -e '/^SYGEN_DNS_CHALLENGE_URL=/d' \
                "$SYGEN_ROOT/.env" 2>/dev/null || true
            rm -f "$SYGEN_ROOT/.env.bak" 2>/dev/null || true
            # Also remove the dead LE cert dir if it exists; certbot will
            # request a fresh one for the new FQDN below.
            if [ -f "$SYGEN_ROOT/data/config/config.json" ]; then
                OLD_SUB=$(jq -r '.instance_name // empty' "$SYGEN_ROOT/data/config/config.json" 2>/dev/null || true)
                # Validate before letting it anywhere near `rm -rf`. A
                # tampered config.json with instance_name="../../../etc"
                # would otherwise let the cert-cleanup step wipe arbitrary
                # paths as root.
                if [ -n "$OLD_SUB" ] && validate_fqdn "${OLD_SUB}.${DOMAIN}" \
                    && [ -d "/etc/letsencrypt/live/${OLD_SUB}.${DOMAIN}" ]; then
                    log "Removing stale LE cert for old FQDN ${OLD_SUB}.${DOMAIN}"
                    rm -rf "/etc/letsencrypt/live/${OLD_SUB}.${DOMAIN}" \
                           "/etc/letsencrypt/archive/${OLD_SUB}.${DOMAIN}" \
                           "/etc/letsencrypt/renewal/${OLD_SUB}.${DOMAIN}.conf" 2>/dev/null || true
                fi
            fi
            SYGEN_INSTALL_TOKEN=""
            SYGEN_INSTALL_HEARTBEAT_URL=""
            SYGEN_DNS_CHALLENGE_URL=""
            # Fall through to fresh provision in the else-branch below.
        else
            # Network failure / Worker 5xx / DNS not resolving — DON'T
            # nuke the local token (it might still be valid). Reuse it
            # and let the rest of the script try; if DNS really gone,
            # the propagation check at line ~510 will surface it.
            warn "Auto-mode re-run: heartbeat probe inconclusive (HTTP $PROBE_HTTP) — keeping existing token"
            AUTO_MODE_REUSE=1
            if [ -f "$SYGEN_ROOT/data/config/config.json" ]; then
                SUB=$(jq -r '.instance_name // empty' "$SYGEN_ROOT/data/config/config.json" 2>/dev/null || true)
            fi
            [ -n "${SUB:-}" ] || die "auto-mode re-run: cannot recover subdomain — config.json missing or has no instance_name. Wipe $SYGEN_ROOT/data/config and rerun for a fresh provision."
            FQDN="${SUB}.${DOMAIN}"
            # Defence in depth: if config.json was tampered with offline,
            # the recovered SUB could carry shell metachars or path traversal
            # into nginx, rm -rf, etc. Reject before any downstream use.
            validate_fqdn "$FQDN" \
                || die "auto-mode re-run: instance_name '$SUB' from config.json is not a valid DNS label"
            ADMIN_URL="https://$FQDN"
            CORS_ORIGIN="https://$FQDN"
            log "Auto-mode re-run: continuing with existing $FQDN"
        fi
    fi

    # Fresh provision: either no prior install OR a re-run where heartbeat
    # probe revealed the reservation was sweep'd.
    if [ -z "${SYGEN_INSTALL_TOKEN:-}" ]; then
        log "Auto-mode: requesting subdomain from $PROVISION_URL"
        # --ipv4 forces curl to resolve+connect over IPv4 so Worker sees an
        # IPv4 in CF-Connecting-IP and creates an A record (not AAAA).
        # Critical: install.sh's later DNS-propagation check only looks for
        # A; on dual-stack hosts (e.g. Hostiko) curl would otherwise pick
        # IPv6 first → Worker creates AAAA → propagation check times out.
        #
        # Retry 3× with 5 s backoff on 5xx (CF Workers occasionally 502
        # mid-deploy). curl --retry handles non-2xx + transient connect
        # failures; --retry-all-errors covers POST + the 5xx case explicitly.
        PROVISION_RESPONSE=""
        provision_rc=0
        for attempt in 1 2 3; do
            if PROVISION_RESPONSE=$(curl -fsS --ipv4 \
                    --retry 0 --max-time 30 \
                    -X POST -H "Content-Type: application/json" \
                    -d '{}' "$PROVISION_URL" 2>/dev/null); then
                provision_rc=0
                break
            fi
            provision_rc=$?
            if [ "$attempt" -lt 3 ]; then
                warn "provision request failed (attempt $attempt/3) — retrying in 5 s"
                sleep 5
            fi
        done
        if [ $provision_rc -ne 0 ]; then
            die "provision request failed after 3 attempts (network or 5xx) — set SYGEN_SUBDOMAIN/CF_API_TOKEN/CF_ZONE_ID to use a custom subdomain"
        fi

        FQDN=$(printf '%s' "$PROVISION_RESPONSE" | jq -r '.fqdn // empty')
        SYGEN_INSTALL_TOKEN=$(printf '%s' "$PROVISION_RESPONSE" | jq -r '.install_token // empty')
        SYGEN_INSTALL_HEARTBEAT_URL=$(printf '%s' "$PROVISION_RESPONSE" | jq -r '.heartbeat_url // empty')
        SYGEN_DNS_CHALLENGE_URL=$(printf '%s' "$PROVISION_RESPONSE" | jq -r '.dns_challenge_url // empty')

        if [ -z "$FQDN" ] || [ -z "$SYGEN_INSTALL_TOKEN" ] || [ -z "$SYGEN_DNS_CHALLENGE_URL" ]; then
            die "provision response missing required fields (got: $PROVISION_RESPONSE)"
        fi

        # Hard validation: a compromised / spoofed Worker must NOT be able
        # to inject shell, nginx, JSON, or path-traversal payloads via
        # these values. They flow into rm -rf paths, nginx server_name,
        # and a generated /usr/local/sbin/sygen-acme-*.sh hook script.
        validate_fqdn "$FQDN" \
            || die "provision response: invalid fqdn '$FQDN' (allowed chars [a-z0-9.-], DNS labels only)"
        validate_https_url "$SYGEN_DNS_CHALLENGE_URL" \
            || die "provision response: invalid dns_challenge_url (must be plain https URL with safe chars)"
        if [ -n "$SYGEN_INSTALL_HEARTBEAT_URL" ]; then
            validate_https_url "$SYGEN_INSTALL_HEARTBEAT_URL" \
                || die "provision response: invalid heartbeat_url"
        fi

        SUB="${FQDN%%.*}"
        ADMIN_URL="https://$FQDN"
        CORS_ORIGIN="https://$FQDN"
        log "Auto-mode: assigned $FQDN (install_token will be saved for weekly heartbeats)"
    fi
fi

# ---------- 2. Public IP + Cloudflare DNS (Linux + macOS publicdomain) ----------
# Auto-mode: Worker created the A record from CF-Connecting-IP during
#   /api/provision. install.sh holds no CF token, so we just verify the
#   record points at the right IP and warn (don't fail) on mismatch — that
#   would mean the host's egress IP differs from what CF saw, which the
#   operator must reconcile manually. On a Mac behind NAT this matches the
#   router's WAN IP, which is what we want for port-forwarded reachability.
# Custom mode: operator owns the zone + token, install.sh upserts directly
#   (Linux only; macOS doesn't expose this path).
needs_dns=0
if [ $LOCAL_MODE -eq 0 ] && [ "$SELF_HOSTED_SUBMODE" != "tailscale" ]; then
    # Linux auto-mode + custom-mode need DNS verify (Worker created A record).
    # Linux+tailscale uses MagicDNS (no public A record), skip.
    needs_dns=1
elif [ "$SELF_HOSTED_SUBMODE" = "publicdomain" ]; then
    needs_dns=1
fi

if [ "$needs_dns" -eq 1 ] && [ "$AUTO_MODE_REUSE" -eq 1 ]; then
    log "Auto-mode re-run: skipping DNS upsert — record was set by original install"
fi
if [ "$needs_dns" -eq 1 ] && [ "$AUTO_MODE_REUSE" -eq 0 ]; then
    STAGE="dns"
    log "Detecting public IP"
    PUBLIC_IP=$(curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me)
    [ -n "$PUBLIC_IP" ] || die "Could not determine public IP"
    log "  public_ip=$PUBLIC_IP"

    if [ "$AUTO_MODE" -eq 1 ]; then
        log "Auto-mode: A record was created by Worker — waiting for DNS propagation"
        DNS_GOT=""
        # 60 × 4 s = up to 4 min: busy CF zones occasionally need ≥ 3 min.
        # Try multiple resolvers per tick — a single resolver (1.1.1.1) can
        # cache a fresh NXDOMAIN for the new label, which then sticks for
        # the rest of the wait window even after CF has the record.
        for i in $(seq 1 60); do
            for resolver in 1.1.1.1 8.8.8.8 9.9.9.9; do
                DNS_GOT=$(dig +short +time=2 +tries=1 A "$FQDN" "@$resolver" 2>/dev/null || true)
                if [ -n "$DNS_GOT" ]; then break; fi
            done
            if [ -n "$DNS_GOT" ]; then break; fi
            if [ $((i % 10)) -eq 0 ]; then
                log "  waiting for DNS… (${i}/60, ~$((i * 4))s elapsed)"
            fi
            sleep 4
        done
        if [ -z "$DNS_GOT" ]; then
            die "Worker-created A record for $FQDN did not propagate within ~4 min"
        fi
        if [ "$DNS_GOT" != "$PUBLIC_IP" ]; then
            warn "A record points at $DNS_GOT but VPS public IP is $PUBLIC_IP."
            warn "  This usually means the host egresses through a different IP than"
            warn "  Cloudflare saw on the /api/provision request (NAT, VPN, IPv6, ...)."
            warn "  Sygen will continue using $DNS_GOT — fix the A record manually if"
            warn "  it should point at $PUBLIC_IP (admin-managed flow, out-of-band)."
        else
            log "  DNS resolved: $DNS_GOT"
        fi
    else
        CF_AUTH="Authorization: Bearer $CF_API_TOKEN"
        DNS_PAYLOAD=$(jq -nc --arg n "$FQDN" --arg c "$PUBLIC_IP" \
            '{type:"A",name:$n,content:$c,ttl:120,proxied:false}')

        log "Upserting Cloudflare A record $FQDN -> $PUBLIC_IP"
        EXISTING=$(curl -fsS "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$FQDN&type=A" \
            -H "$CF_AUTH" | jq -r '.result[0].id // empty')
        if [ -n "$EXISTING" ]; then
            curl -fsS -X PUT \
                "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$EXISTING" \
                -H "$CF_AUTH" -H "Content-Type: application/json" --data "$DNS_PAYLOAD" \
                >/dev/null
            log "  updated existing record"
        else
            curl -fsS -X POST \
                "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
                -H "$CF_AUTH" -H "Content-Type: application/json" --data "$DNS_PAYLOAD" \
                >/dev/null
            log "  created new record"
        fi

        log "Waiting for DNS propagation..."
        # 60 × 4 s = up to 4 min, multi-resolver. See auto-mode block above
        # for rationale (busy CF zones / cached NXDOMAIN on a single resolver).
        for i in $(seq 1 60); do
            for resolver in 1.1.1.1 8.8.8.8 9.9.9.9; do
                got=$(dig +short +time=2 +tries=1 A "$FQDN" "@$resolver" 2>/dev/null || true)
                if [ "$got" = "$PUBLIC_IP" ]; then break; fi
            done
            if [ "$got" = "$PUBLIC_IP" ]; then
                log "  DNS resolved: $got"
                break
            fi
            if [ $((i % 10)) -eq 0 ]; then
                log "  waiting for DNS… (${i}/60, ~$((i * 4))s elapsed)"
            fi
            sleep 4
        done
    fi
fi

# ---------- 3. TLS cert (Linux + macOS publicdomain) ----------
# Auto-mode: certbot answers DNS-01 via Worker-mediated hooks at
#   /usr/local/sbin/sygen-acme-{auth,cleanup}-hook.sh. The hooks read the
#   install_token from $SYGEN_ROOT/.env and POST/DELETE the TXT through
#   $SYGEN_DNS_CHALLENGE_URL — no CF credentials on the host.
# Custom mode: operator's CF token directly via --dns-cloudflare.
# macOS publicdomain re-uses the auto-mode hook flow; the only platform
# differences are sudo for /etc/letsencrypt + the certbot binary path
# (Homebrew puts it in $(brew --prefix)/bin instead of /usr/bin).
needs_cert=0
if [ $LOCAL_MODE -eq 0 ] && [ "$SELF_HOSTED_SUBMODE" != "tailscale" ]; then
    needs_cert=1
elif [ "$SELF_HOSTED_SUBMODE" = "publicdomain" ]; then
    needs_cert=1
fi

# Pick a sudo wrapper + certbot binary path + storage layout for both
# Linux and brew-on-macOS. Linux runs install.sh as root and writes the
# hooks/cert state into the standard system paths. macOS in non-TTY SSH
# can't prompt for sudo, so we keep cert state inside SYGEN_ROOT (user-
# writable) and skip sudo entirely. Functionally identical from certbot's
# point of view — it just reads the dirs we hand it via --config-dir &
# friends.
SUDO=""
CERTBOT_BIN="certbot"
ACME_HOOK_DIR="/usr/local/sbin"
CERTBOT_CONFIG_DIR=""
CERTBOT_LIVE_DIR="/etc/letsencrypt"
if [ "$needs_cert" -eq 1 ] && [ $LOCAL_MODE -eq 1 ]; then
    # macOS: prefer the pipx-installed certbot from the deps stage above
    # (~/.local/bin/certbot), then ~/.local/bin from PATH, then brew as
    # legacy fallback. pipx isolation means certbot's Python deps never
    # collide with whatever pip globals the user already has in their
    # brew prefix.
    if [ -x "$HOME/.local/bin/certbot" ]; then
        CERTBOT_BIN="$HOME/.local/bin/certbot"
    elif command -v certbot >/dev/null 2>&1; then
        CERTBOT_BIN="$(command -v certbot)"
    elif [ -x "$(brew --prefix 2>/dev/null)/bin/certbot" ]; then
        CERTBOT_BIN="$(brew --prefix)/bin/certbot"
    fi
    # macOS: hooks + cert state in user-space so certbot needs no sudo.
    ACME_HOOK_DIR="$SYGEN_ROOT/acme-hooks"
    CERTBOT_CONFIG_DIR="$SYGEN_ROOT/letsencrypt"
    CERTBOT_LIVE_DIR="$CERTBOT_CONFIG_DIR"
fi

if [ "$needs_cert" -eq 1 ]; then
    STAGE="cert"

    if [ "$AUTO_MODE" -eq 1 ]; then
        # Hooks must exist before any cert renewal too — install once,
        # certbot.timer / re-runs reuse them on every renew.
        log "Installing ACME DNS-01 manual hooks (Worker-mediated)"
        $SUDO mkdir -p "$ACME_HOOK_DIR"
        $SUDO tee "$ACME_HOOK_DIR/sygen-acme-auth-hook.sh" >/dev/null <<HOOK
#!/usr/bin/env bash
# Sygen ACME DNS-01 auth hook — POSTs the TXT challenge to the Worker.
# Invoked by certbot --manual-auth-hook with CERTBOT_DOMAIN + CERTBOT_VALIDATION
# in the environment. Never touches a Cloudflare token.
set -euo pipefail

ENV_FILE="$SYGEN_ROOT/.env"
DEFAULT_DNS_CHALLENGE_URL="$SYGEN_DNS_CHALLENGE_URL"

if [ -z "\${SYGEN_INSTALL_TOKEN:-}" ] && [ -f "\$ENV_FILE" ]; then
    SYGEN_INSTALL_TOKEN=\$(grep '^SYGEN_INSTALL_TOKEN=' "\$ENV_FILE" | head -n1 | cut -d= -f2-)
fi
if [ -z "\${SYGEN_INSTALL_TOKEN:-}" ]; then
    echo "sygen-acme-auth-hook: SYGEN_INSTALL_TOKEN not set and \$ENV_FILE missing" >&2
    exit 1
fi
if [ -z "\${SYGEN_DNS_CHALLENGE_URL:-}" ] && [ -f "\$ENV_FILE" ]; then
    SYGEN_DNS_CHALLENGE_URL=\$(grep '^SYGEN_DNS_CHALLENGE_URL=' "\$ENV_FILE" | head -n1 | cut -d= -f2-)
fi
DNS_CHALLENGE_URL="\${SYGEN_DNS_CHALLENGE_URL:-\$DEFAULT_DNS_CHALLENGE_URL}"

NAME="_acme-challenge.\${CERTBOT_DOMAIN}"
PAYLOAD=\$(jq -nc \\
    --arg t "\$SYGEN_INSTALL_TOKEN" \\
    --arg n "\$NAME" \\
    --arg v "\$CERTBOT_VALIDATION" \\
    '{install_token:\$t,name:\$n,value:\$v}')

curl -fsS --ipv4 -X POST -H "Content-Type: application/json" \\
    -d "\$PAYLOAD" "\$DNS_CHALLENGE_URL" >/dev/null \\
    || { echo "sygen-acme-auth-hook: POST failed" >&2; exit 1; }

# Give CF DNS a moment to propagate before certbot polls Let's Encrypt.
# CF is global within seconds; 20s is the same belt LE itself uses.
sleep 20
HOOK
        $SUDO chmod 0755 "$ACME_HOOK_DIR/sygen-acme-auth-hook.sh"

        $SUDO tee "$ACME_HOOK_DIR/sygen-acme-cleanup-hook.sh" >/dev/null <<HOOK
#!/usr/bin/env bash
# Sygen ACME DNS-01 cleanup hook — DELETEs the challenge TXT via the Worker.
# Best-effort: an error here doesn't fail the cert (record will be swept
# eventually), so we exit 0 even on Worker errors.
set -uo pipefail

ENV_FILE="$SYGEN_ROOT/.env"
DEFAULT_DNS_CHALLENGE_URL="$SYGEN_DNS_CHALLENGE_URL"

if [ -z "\${SYGEN_INSTALL_TOKEN:-}" ] && [ -f "\$ENV_FILE" ]; then
    SYGEN_INSTALL_TOKEN=\$(grep '^SYGEN_INSTALL_TOKEN=' "\$ENV_FILE" | head -n1 | cut -d= -f2-)
fi
if [ -z "\${SYGEN_INSTALL_TOKEN:-}" ]; then
    echo "sygen-acme-cleanup-hook: SYGEN_INSTALL_TOKEN not set; skipping" >&2
    exit 0
fi
if [ -z "\${SYGEN_DNS_CHALLENGE_URL:-}" ] && [ -f "\$ENV_FILE" ]; then
    SYGEN_DNS_CHALLENGE_URL=\$(grep '^SYGEN_DNS_CHALLENGE_URL=' "\$ENV_FILE" | head -n1 | cut -d= -f2-)
fi
DNS_CHALLENGE_URL="\${SYGEN_DNS_CHALLENGE_URL:-\$DEFAULT_DNS_CHALLENGE_URL}"

NAME="_acme-challenge.\${CERTBOT_DOMAIN}"
PAYLOAD=\$(jq -nc \\
    --arg t "\$SYGEN_INSTALL_TOKEN" \\
    --arg n "\$NAME" \\
    '{install_token:\$t,name:\$n}')

curl -fsS --ipv4 -X DELETE -H "Content-Type: application/json" \\
    -d "\$PAYLOAD" "\$DNS_CHALLENGE_URL" >/dev/null \\
    || echo "sygen-acme-cleanup-hook: DELETE failed (non-fatal)" >&2

exit 0
HOOK
        $SUDO chmod 0755 "$ACME_HOOK_DIR/sygen-acme-cleanup-hook.sh"
    fi

    # Build --config-dir/--work-dir/--logs-dir overrides for macOS so
    # certbot stays in user-space; empty on Linux (default /etc/letsencrypt).
    CERTBOT_DIR_ARGS=""
    if [ -n "$CERTBOT_CONFIG_DIR" ]; then
        CERTBOT_DIR_ARGS="--config-dir $CERTBOT_CONFIG_DIR --work-dir ${CERTBOT_CONFIG_DIR}-work --logs-dir ${CERTBOT_CONFIG_DIR}-logs"
        mkdir -p "$CERTBOT_CONFIG_DIR" "${CERTBOT_CONFIG_DIR}-work" "${CERTBOT_CONFIG_DIR}-logs"
    fi

    if [ "$AUTO_MODE_REUSE" -eq 1 ]; then
        log "Auto-mode re-run: cert already present, skipping certbot"
    elif $SUDO test -f "$CERTBOT_LIVE_DIR/live/$FQDN/fullchain.pem"; then
        log "  cert already present, skipping"
    elif [ "$AUTO_MODE" -eq 1 ]; then
        # Log the certbot version up front so any CLI-argument failure
        # (Round 7) is debuggable from the install log without re-running.
        log "  certbot version: $($SUDO "$CERTBOT_BIN" --version 2>&1 | head -n1)"
        # Cert issuance cascade (auto-mode only):
        #   1. Let's Encrypt (primary) — 50 cert/week per registered domain,
        #      override-able to 1000+. Worker-mediated DNS-01 hooks.
        #   2. ZeroSSL (fallback) — independent rate-limit budget. EAB
        #      credentials fetched from Worker on demand. Same DNS-01
        #      hooks (Worker doesn't care which CA generated the
        #      validation token).
        # If both fail we release the subdomain (so it doesn't leak a KV
        # slot on cert-fail) and emit a structured JSON error with
        # `tls_rate_limited` code so iOS/web wizards can show a
        # meaningful retry message.
        # Capture certbot stderr so we can tell a CLI-argument failure
        # (the same on every CA — installer bug, not rate limit) apart
        # from genuine CA refusals. Without this distinction the cascade
        # would hit all three CAs at CLI-parse speed and emit a bogus
        # `tls_rate_limited` that asks the user to wait an hour for a
        # bug they can't fix from the wizard.
        CERT_STDERR=""
        cert_try() {
            # Args: <ca-name> [extra certbot args...]
            local ca_name="$1"; shift
            log "  attempt: $ca_name"
            local stderr_file
            stderr_file="$(mktemp -t sygen-certbot-XXXXXX)"
            # shellcheck disable=SC2086 # CERTBOT_DIR_ARGS expansion is intentional
            #
            # NOTE: --manual-public-ip-logging-ok was deprecated in
            # certbot 1.x and removed entirely in 5.x. Do NOT add it
            # back without checking certbot --version on the smallest
            # supported distro. Manual-hook public-IP logging is on by
            # default since 2.x and there's no replacement flag.
            $SUDO env \
                SYGEN_INSTALL_TOKEN="$SYGEN_INSTALL_TOKEN" \
                SYGEN_DNS_CHALLENGE_URL="$SYGEN_DNS_CHALLENGE_URL" \
                "$CERTBOT_BIN" certonly --non-interactive --agree-tos \
                $CERTBOT_DIR_ARGS \
                --preferred-challenges dns \
                --manual \
                --manual-auth-hook "$ACME_HOOK_DIR/sygen-acme-auth-hook.sh" \
                --manual-cleanup-hook "$ACME_HOOK_DIR/sygen-acme-cleanup-hook.sh" \
                -d "$FQDN" \
                "$@" 2> >(tee "$stderr_file" >&2)
            local rc=$?
            CERT_STDERR="$(head -n5 "$stderr_file" 2>/dev/null | tr '\n' ' ')"
            rm -f "$stderr_file"
            return $rc
        }

        # Detect installer-side breakage: certbot exits non-zero with an
        # "unrecognized arguments"/"argument" error message before talking
        # to any CA. In that case all three CA attempts will fail the
        # exact same way at CLI-parse speed; abort the cascade with an
        # honest error so the user doesn't get told to wait an hour.
        cert_was_cli_fail() {
            case "$CERT_STDERR" in
                *"unrecognized arguments"*) return 0 ;;
                *"error: argument"*)        return 0 ;;
            esac
            return 1
        }

        # Try a fallback CA via Worker /api/eab. Returns 0 on success,
        # 1 if the Worker call or the cert issuance failed. Doesn't die —
        # caller decides whether to fall through to the next CA.
        try_eab_ca() {
            local ca_name="$1"
            local eab_url="https://install.${DOMAIN}/api/eab"
            local resp
            resp=$(curl -fsS --ipv4 -X POST -H "Content-Type: application/json" \
                -d "$(jq -nc --arg t "$SYGEN_INSTALL_TOKEN" --arg c "$ca_name" '{install_token:$t,ca:$c}')" \
                "$eab_url" 2>/dev/null) || return 1
            local kid hmac dir email
            kid=$(printf  '%s' "$resp" | jq -r '.eab_kid // empty')
            hmac=$(printf '%s' "$resp" | jq -r '.eab_hmac_key // empty')
            dir=$(printf  '%s' "$resp" | jq -r '.acme_directory_url // empty')
            email=$(printf '%s' "$resp" | jq -r '.acme_account_email // empty')
            if [ -z "$kid" ] || [ -z "$hmac" ] || [ -z "$dir" ]; then
                warn "  $ca_name: /api/eab returned malformed credentials"
                return 1
            fi
            cert_try "$ca_name" \
                --server "$dir" \
                --eab-kid "$kid" \
                --eab-hmac-key "$hmac" \
                --email "$email"
        }

        log "Obtaining TLS cert via Worker-mediated DNS-01"
        if cert_try "letsencrypt" --email "admin@$DOMAIN"; then
            log "  ok: letsencrypt"
        elif cert_was_cli_fail; then
            # Same args go to every CA, so trying ZeroSSL/GTS would fail
            # identically and at the same speed — looks like rate-limit
            # but isn't. Bail with an honest cause.
            _release_and_die "installer_misconfigured" "certbot rejected its own arguments before reaching any CA: ${CERT_STDERR:-unknown}. This is an install.sh bug, not a CA issue — update the installer and retry."
        else
            warn "  letsencrypt failed — trying ZeroSSL"
            STAGE="cert-fallback"
            if try_eab_ca "zerossl"; then
                log "  ok: zerossl (fallback #1)"
            elif cert_was_cli_fail; then
                _release_and_die "installer_misconfigured" "certbot rejected its own arguments: ${CERT_STDERR:-unknown}. Installer bug — retry pointless."
            else
                warn "  zerossl failed — trying Google Trust Services"
                if try_eab_ca "gts"; then
                    log "  ok: gts (fallback #2)"
                elif cert_was_cli_fail; then
                    _release_and_die "installer_misconfigured" "certbot rejected its own arguments: ${CERT_STDERR:-unknown}. Installer bug — retry pointless."
                else
                    _release_and_die "tls_rate_limited" "All three CAs (Let's Encrypt, ZeroSSL, Google Trust Services) refused to issue cert. Most likely rate-limited everywhere; less likely a DNS-01 misconfiguration on our side. Try again in 1 hour."
                fi
            fi
        fi
    else
        log "Obtaining Let's Encrypt cert via Cloudflare DNS-01 (custom mode)"
        # macOS keeps everything inside SYGEN_ROOT (no sudo); Linux uses
        # the standard /etc/letsencrypt path under root.
        CF_INI_DIR="${CERTBOT_LIVE_DIR}/sygen"
        $SUDO mkdir -p "$CF_INI_DIR"
        umask 077
        $SUDO tee "$CF_INI_DIR/cloudflare.ini" >/dev/null <<CF_INI
dns_cloudflare_api_token = $CF_API_TOKEN
CF_INI
        umask 022
        # shellcheck disable=SC2086
        $SUDO "$CERTBOT_BIN" certonly --non-interactive --agree-tos \
            $CERTBOT_DIR_ARGS \
            --email "admin@$DOMAIN" \
            --dns-cloudflare \
            --dns-cloudflare-credentials "$CF_INI_DIR/cloudflare.ini" \
            --dns-cloudflare-propagation-seconds 20 \
            -d "$FQDN" || die "certbot failed"
    fi
fi

# ---------- 4. Data dirs + bootstrap config ----------
STAGE="data"
log "Preparing $SYGEN_ROOT"
mkdir -p "$SYGEN_ROOT"/{data,claude-auth}
mkdir -p "$SYGEN_ROOT/data/config"
# Linux installer runs as root and SYGEN_ROOT lives under /srv/sygen — by
# default mkdir creates 0755, which lets any local user list the directory
# (filenames inside leak: .env, _secrets/, etc — even though the files
# themselves are 0600). Tighten to 0750 on Linux. macOS keeps 0755 because
# SYGEN_ROOT lives under $HOME and the host already restricts $HOME perms.
if [ $LOCAL_MODE -eq 0 ]; then
    chmod 0750 "$SYGEN_ROOT"
fi
# Secrets dir holds .initial_admin_password + future per-install secrets.
# `install -d` is atomic and refuses to follow a pre-existing symlink, so a
# local non-root attacker cannot pre-create _secrets as a symlink to e.g.
# /root/.ssh and ride the later chown -R into a privesc. Mode 0700 set in
# the same syscall — no TOCTOU window where the dir is briefly 0755.
install -d -m 0700 "$SYGEN_ROOT/data/_secrets"

# Native install: services run as the installing user (root on Linux,
# $USER on macOS). No uid remap needed — the previous chown to 1000:1000
# was for the in-container `sygen` user under Docker, which doesn't exist
# anymore. Keep $SYGEN_ROOT readable by the service user and nothing else.

# Pick a sensible default for instance_name. Auto-mode SUB is a meaningful
# subdomain (e.g. yuqp3yqv.sygen.pro → "yuqp3yqv"); for everything else
# (localhost, tailscale, custom) prefer the host's short hostname so each
# client (admin web, iOS, future agents) shows a label that matches what
# the operator already calls the box. Falls back to "sygen" if hostname is
# somehow empty so we never write an empty string.
if [ "$AUTO_MODE" -eq 1 ] && [ -n "${SUB:-}" ]; then
    DEFAULT_INSTANCE_NAME="$SUB"
else
    DEFAULT_INSTANCE_NAME="$(hostname -s 2>/dev/null || true)"
    [ -z "$DEFAULT_INSTANCE_NAME" ] && DEFAULT_INSTANCE_NAME="sygen"
fi

if [ ! -f "$SYGEN_ROOT/data/config/config.json" ]; then
    log "Bootstrapping config.json (api on, host 0.0.0.0, port 8081)"
    # `openssl rand -hex 32` outputs 64 hex chars on one line — no SIGPIPE
    # issues the way `tr -dc ... </dev/urandom | head -c N` has under pipefail.
    API_TOKEN=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 32)
    # Build with `jq -n` so any string value (instance name, CORS_ORIGIN) is
    # JSON-escaped automatically — a heredoc would interpolate raw shell,
    # letting a tampered FQDN inject extra keys (e.g. flip allow_public,
    # override jwt_secret) into the bootstrap config. The inputs are
    # already validated above; this is defence in depth.
    jq -n \
        --arg name "$DEFAULT_INSTANCE_NAME" \
        --arg token "$API_TOKEN" \
        --arg jwt "$JWT_SECRET" \
        --arg cors "$CORS_ORIGIN" \
        '{
            instance_name: $name,
            language: "en",
            log_level: "INFO",
            transport: "api",
            transports: ["api"],
            allowed_user_ids: [],
            api: {
                enabled: true,
                host: "0.0.0.0",
                port: 8081,
                token: $token,
                jwt_secret: $jwt,
                chat_id: 0,
                allow_public: true,
                cors_origins: [$cors]
            }
        }' > "$SYGEN_ROOT/data/config/config.json"
    chmod 600 "$SYGEN_ROOT/data/config/config.json"
else
    # Migrate older installs that pre-date instance_name. Idempotent: only
    # writes when the field is missing OR an empty string. A user-set value
    # (even one that differs from DEFAULT_INSTANCE_NAME) is preserved — admin
    # web / iOS / API are the canonical edit surfaces, install.sh must never
    # stomp them on re-run. Atomic via tmp+mv so a crash mid-write doesn't
    # truncate the live config.
    current_name=$(jq -r '.instance_name // ""' "$SYGEN_ROOT/data/config/config.json" 2>/dev/null || echo "")
    if [ -z "$current_name" ]; then
        log "Seeding instance_name=\"$DEFAULT_INSTANCE_NAME\" in existing config.json"
        tmp_config="$SYGEN_ROOT/data/config/config.json.tmp.$$"
        if jq --arg name "$DEFAULT_INSTANCE_NAME" \
             '. + {instance_name: $name}' \
             "$SYGEN_ROOT/data/config/config.json" > "$tmp_config"; then
            chmod 600 "$tmp_config"
            mv "$tmp_config" "$SYGEN_ROOT/data/config/config.json"
        else
            rm -f "$tmp_config"
            warn "Failed to patch instance_name into config.json (jq error) — leaving as-is"
        fi
    fi
fi

# Preserve user-set values across re-runs of install.sh. Each call to
# get_env reads from the existing .env (if any) and falls back to the
# given default when missing. Avoids stomping on operator edits like
# ANTHROPIC_API_KEY, pinned image tags, or the updater bearer token.
get_env() {
    local key="$1"
    local default="${2:-}"
    if [ -f "$SYGEN_ROOT/.env" ]; then
        local existing
        existing=$(grep -E "^${key}=" "$SYGEN_ROOT/.env" 2>/dev/null \
            | head -n1 | cut -d= -f2- || true)
        # Strip surrounding double or single quotes so `KEY="value"` written
        # by an operator (or by a future writer that quotes for safety) round-
        # trips cleanly. Without this, get_env returns `"value"` literally,
        # the next .env write doubles the quotes (`KEY=""value""`), and every
        # consumer that doesn't strip downstream sees the wrong value.
        existing="${existing%\"}"
        existing="${existing#\"}"
        existing="${existing%\'}"
        existing="${existing#\'}"
        if [ -n "$existing" ]; then
            printf '%s' "$existing"
            return
        fi
    fi
    printf '%s' "$default"
}

# Version pins: env var > existing .env > computed default. Lets an operator
# stay on a specific version across re-runs (and gives the updater a stable
# "currently installed" reference). Stored in .env so launchd/systemd units
# inherit them and the updater can trust them as ground truth.
EFFECTIVE_CORE_VERSION=$(get_env SYGEN_CORE_VERSION "$CORE_VERSION")
EFFECTIVE_ADMIN_VERSION=$(get_env SYGEN_ADMIN_VERSION "$ADMIN_VERSION")
# Secrets: existing wins; otherwise generate or pull from process env.
EFFECTIVE_UPDATER_TOKEN=$(get_env SYGEN_UPDATER_TOKEN "$(openssl rand -hex 32)")
EFFECTIVE_ANTHROPIC_KEY=$(get_env ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY:-}")
EFFECTIVE_OAUTH_TOKEN=$(get_env CLAUDE_CODE_OAUTH_TOKEN "${CLAUDE_CODE_OAUTH_TOKEN:-}")
EFFECTIVE_LOG_LEVEL=$(get_env LOG_LEVEL "INFO")
# Phase 3: subdomain provisioning. Preserve token + heartbeat URL across
# re-runs of install.sh — losing them would orphan the reservation and the
# slot would get reclaimed after the 30-day TTL.
EFFECTIVE_INSTALL_TOKEN=$(get_env SYGEN_INSTALL_TOKEN "${SYGEN_INSTALL_TOKEN:-}")
EFFECTIVE_HEARTBEAT_URL=$(get_env SYGEN_INSTALL_HEARTBEAT_URL "${SYGEN_INSTALL_HEARTBEAT_URL:-}")
EFFECTIVE_DNS_CHALLENGE_URL=$(get_env SYGEN_DNS_CHALLENGE_URL "${SYGEN_DNS_CHALLENGE_URL:-}")
# NEXT_PUBLIC_SYGEN_API_URL: macOS localhost mode forces localhost (no proxy
# layer in front of admin), but tailscale/publicdomain submodes terminate
# TLS in front of both admin (8080) and core (8081) — so admin should hit
# the API same-origin via the proxy, exactly like Linux. Empty string =
# same-origin in the admin runtime.
if [ $LOCAL_MODE -eq 1 ] && [ "$SELF_HOSTED_SUBMODE" = "localhost" ]; then
    EFFECTIVE_PUBLIC_API_URL="http://localhost:8081"
else
    EFFECTIVE_PUBLIC_API_URL=$(get_env NEXT_PUBLIC_SYGEN_API_URL "")
fi

# Host hostname + IANA timezone, surfaced into core via env vars so
# /api/system/status and /api/system/timezone can fall back to host
# metadata before the operator first writes config["instance_name"] /
# config["user_timezone"] via the admin/iOS PUT endpoints.
#
# macOS: prefer the user-friendly ComputerName ("Mac mini (aiagent)");
# fall back to `hostname` if scutil fails. Linux uses `hostname`.
# TZ: macOS reads /etc/localtime symlink target (Apple's source of
# truth — System Settings writes through it); systemsetup is the
# fallback for unusual setups. Linux uses timedatectl, then /etc/timezone.
# Empty string is preserved so core's UI-side fallback can kick in
# rather than mis-claiming a TZ.
if [ $LOCAL_MODE -eq 1 ]; then
    HOST_HOSTNAME_VAL="$(scutil --get ComputerName 2>/dev/null || hostname 2>/dev/null || true)"
    HOST_TZ_VAL="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')"
    [ -z "$HOST_TZ_VAL" ] && HOST_TZ_VAL="$(systemsetup -gettimezone 2>/dev/null | awk -F': ' '{print $2}')"
else
    HOST_HOSTNAME_VAL="$(hostname 2>/dev/null || true)"
    HOST_TZ_VAL="$(timedatectl show --value -p Timezone 2>/dev/null || cat /etc/timezone 2>/dev/null || true)"
fi
[ -z "$HOST_TZ_VAL" ] && HOST_TZ_VAL=""

# Native .env is sourced by launchd plists / systemd units via EnvironmentFile=
# (Linux) or by a small wrapper that exports vars before exec on macOS.
# Multi-line values and quoted strings are unsupported; drop control chars +
# quote/equals chars that could break the parser or smuggle extra vars.
sanitize_env_value() {
    printf '%s' "$1" | tr -d '\n\r\t' | tr -d '"' | tr -d "'"
}
HOST_HOSTNAME_VAL="$(sanitize_env_value "$HOST_HOSTNAME_VAL")"
HOST_TZ_VAL="$(sanitize_env_value "$HOST_TZ_VAL")"

umask 077
{
    echo "SYGEN_CORE_VERSION=$EFFECTIVE_CORE_VERSION"
    echo "SYGEN_ADMIN_VERSION=$EFFECTIVE_ADMIN_VERSION"
    # P0-3: pin the Python interpreter the updater uses to seed new venvs.
    # Without this the updater falls back to `shutil.which("python3")`,
    # which on macOS is /usr/bin/python3 (Apple stub, often 3.9) — not
    # the brew python@3.14 we built the live venv with. The updater
    # logs this on startup so the operator can verify after each restart.
    echo "SYGEN_PYTHON_BIN=$PYTHON_BIN"
    echo "ANTHROPIC_API_KEY=$EFFECTIVE_ANTHROPIC_KEY"
    echo "CLAUDE_CODE_OAUTH_TOKEN=$EFFECTIVE_OAUTH_TOKEN"
    echo "LOG_LEVEL=$EFFECTIVE_LOG_LEVEL"
    # Shared secret for core ↔ updater apply calls. Core authenticates its
    # POST to http://127.0.0.1:8082/apply with this bearer token.
    echo "SYGEN_UPDATER_TOKEN=$EFFECTIVE_UPDATER_TOKEN"
    # GitHub repo coordinates so the updater can poll Releases without
    # rediscovering them at runtime. Override via env to test forks.
    echo "SYGEN_CORE_GITHUB_REPO=$CORE_GITHUB_REPO"
    echo "SYGEN_ADMIN_GITHUB_REPO=$ADMIN_GITHUB_REPO"
    if [ -n "$EFFECTIVE_PUBLIC_API_URL" ]; then
        echo "NEXT_PUBLIC_SYGEN_API_URL=$EFFECTIVE_PUBLIC_API_URL"
    fi
    # Phase 3: only present on auto-provisioned installs. Core reads these
    # at boot and runs a weekly POST to heartbeat_url to keep the slot alive.
    if [ -n "$EFFECTIVE_INSTALL_TOKEN" ]; then
        echo "SYGEN_INSTALL_TOKEN=$EFFECTIVE_INSTALL_TOKEN"
    fi
    if [ -n "$EFFECTIVE_HEARTBEAT_URL" ]; then
        echo "SYGEN_INSTALL_HEARTBEAT_URL=$EFFECTIVE_HEARTBEAT_URL"
    fi
    # Read by /usr/local/sbin/sygen-acme-{auth,cleanup}-hook.sh during cert
    # renewal so the operator can override the endpoint without editing the
    # baked-in default in the hook script itself.
    if [ -n "$EFFECTIVE_DNS_CHALLENGE_URL" ]; then
        echo "SYGEN_DNS_CHALLENGE_URL=$EFFECTIVE_DNS_CHALLENGE_URL"
    fi
    # macOS: pass host CPU/RAM/disk metadata into core. Native processes
    # already see these via psutil, but the SYGEN_HOST_* env vars are the
    # canonical override — kept for parity with the Linux branch.
    if [ -f /tmp/sygen-host-metrics.env ]; then
        cat /tmp/sygen-host-metrics.env
    fi
    echo "SYGEN_HOST_DATA_DIR=$SYGEN_ROOT"
    # Whisper.cpp model location. Native install: same path as before
    # (~/.local/share/whisper-cpp/models). Core reads the model directly
    # from this directory; no bind-mount indirection.
    echo "SYGEN_HOST_WHISPER_MODELS_DIR=$HOME/.local/share/whisper-cpp/models"
    # Host hostname + IANA timezone (resolved above). Read by core's
    # /api/system/status and /api/system/timezone as fallbacks before the
    # operator writes config["instance_name"] / config["user_timezone"].
    # Empty string = no fallback; UI then renders its own default.
    echo "SYGEN_HOST_HOSTNAME=$HOST_HOSTNAME_VAL"
    echo "SYGEN_HOST_TZ=$HOST_TZ_VAL"
} > "$SYGEN_ROOT/.env"
umask 022
chmod 600 "$SYGEN_ROOT/.env"

# ---------- 5. Native install: Python venv + admin tarball ----------
STAGE="install"

VENV_DIR="$SYGEN_ROOT/venv"
ADMIN_DIR="$SYGEN_ROOT/admin"
ADMIN_PREV_DIR="$SYGEN_ROOT/admin-prev"
VENV_PIP="$VENV_DIR/bin/pip"
VENV_SYGEN_BIN="$VENV_DIR/bin/sygen"
VENV_UPDATER_BIN="$VENV_DIR/bin/sygen-updater"

# Helper: GitHub Release artefact URL for a given repo + version + filename.
gh_release_url() {
    # $1=repo (owner/name), $2=version (no leading v), $3=asset filename
    printf 'https://github.com/%s/releases/download/v%s/%s' "$1" "$2" "$3"
}

# Helper: download with HTTP error → die. -L follows redirects (GitHub
# Release assets are 302 → S3-backed URL).
fetch_release_asset() {
    # $1=url, $2=dest
    local url="$1" dest="$2"
    log "  fetching $url"
    curl -fL --retry 3 --retry-delay 5 --max-time 600 -o "$dest" "$url" \
        || die "could not download $url (HTTP error or network failure)"
}

# Helper: pick the sha256 CLI for this host. macOS ships `shasum -a 256`,
# Linux ships `sha256sum`. Both produce `<hex>  <filename>` lines.
sha256_compute() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "no sha256 tool found (need sha256sum or shasum)"
    fi
}

# P0-5 helper: HEAD-probe a Release asset to differentiate "not yet
# published" (404 → caller falls back to source mode or prints guidance)
# from "real network failure" (caller dies).
gh_release_asset_exists() {
    # $1=asset_url. Returns 0 if HEAD says 200, 1 if 404, 2 on other errors.
    local url="$1"
    local code
    code=$(curl -sSI -o /dev/null -w '%{http_code}' --max-time 30 -L "$url" 2>/dev/null || echo "000")
    case "$code" in
        200) return 0 ;;
        404) return 1 ;;
        *)   return 2 ;;
    esac
}

# P0-2 fix: every wheel/tarball pulled from GitHub Releases must be SHA256-
# verified. .sha256 sidecar is REQUIRED (fail closed) — a missing sidecar
# means the release was published without checksums and we refuse to
# install it. Sidecar format: one line "<hex>  <basename>".
# Caller is responsible for pre-checking asset existence with
# gh_release_asset_exists if a 404 fallback is desired.
fetch_release_asset_verified() {
    # $1=asset_url, $2=dest
    local asset_url="$1" dest="$2"
    fetch_release_asset "$asset_url" "$dest"
    local sha_url="${asset_url}.sha256"
    local sha_dest="${dest}.sha256"
    log "  verifying SHA256 against ${sha_url}"
    if ! curl -fL --retry 3 --retry-delay 5 --max-time 60 -o "$sha_dest" "$sha_url"; then
        rm -f "$dest" "$sha_dest" 2>/dev/null || true
        die "missing checksum sidecar at $sha_url — refusing to install unverified asset"
    fi
    local expected
    expected="$(awk '{print $1}' "$sha_dest")"
    local actual
    actual="$(sha256_compute "$dest")"
    rm -f "$sha_dest" 2>/dev/null || true
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        rm -f "$dest" 2>/dev/null || true
        die "SHA256 mismatch for $asset_url — expected ${expected:-<unreadable>}, got ${actual:-<unreadable>}"
    fi
}

# ----- 5a. Core: pip install sygen into the venv -----
log "Creating Python venv at $VENV_DIR (using $PYTHON_BIN)"
# --clear nukes any prior venv contents on a re-run so we never end up
# with a half-upgraded site-packages tree. Cheap on a small venv.
"$PYTHON_BIN" -m venv --clear "$VENV_DIR" \
    || die "python -m venv failed — check that python3-venv (Linux) or python@3.14 (macOS) is fully installed"

log "Upgrading pip + wheel inside the venv"
"$VENV_PIP" install --quiet --upgrade pip wheel \
    || die "pip self-upgrade failed inside venv"

if [ "$RELEASE_SOURCE" = "source" ]; then
    [ -n "$CORE_SOURCE_DIR" ] && [ -d "$CORE_SOURCE_DIR" ] \
        || die "SYGEN_RELEASE_SOURCE=source requires SYGEN_CORE_SOURCE_DIR=<path-to-sygen-checkout>"
    log "Installing sygen from local checkout: $CORE_SOURCE_DIR"
    "$VENV_PIP" install --quiet "$CORE_SOURCE_DIR" \
        || die "pip install $CORE_SOURCE_DIR failed"
else
    CORE_WHEEL="sygen-${EFFECTIVE_CORE_VERSION}-py3-none-any.whl"
    CORE_WHEEL_URL="$(gh_release_url "$CORE_GITHUB_REPO" "$EFFECTIVE_CORE_VERSION" "$CORE_WHEEL")"
    CORE_WHEEL_DEST="/tmp/sygen-${EFFECTIVE_CORE_VERSION}-${$}.whl"
    # P0-5: HEAD-probe before downloading. 404 → release not yet published;
    # surface an actionable error (or auto-switch to source mode if a local
    # checkout is available).
    _probe=0
    gh_release_asset_exists "$CORE_WHEEL_URL" || _probe=$?
    if [ "$_probe" = "1" ]; then
        if [ -n "$CORE_SOURCE_DIR" ] && [ -d "$CORE_SOURCE_DIR" ]; then
            warn "sygen wheel ${EFFECTIVE_CORE_VERSION} not published yet — falling back to local checkout at $CORE_SOURCE_DIR"
            "$VENV_PIP" install --quiet "$CORE_SOURCE_DIR" \
                || die "pip install $CORE_SOURCE_DIR failed (fallback after missing release)"
        else
            die "sygen wheel not yet published at $CORE_WHEEL_URL. Either wait for the release, set SYGEN_CORE_VERSION=<existing-tag>, or re-run with SYGEN_RELEASE_SOURCE=source SYGEN_CORE_SOURCE_DIR=<path-to-sygen-checkout>"
        fi
    else
        log "Downloading sygen wheel ${EFFECTIVE_CORE_VERSION} from GitHub Releases"
        fetch_release_asset_verified "$CORE_WHEEL_URL" "$CORE_WHEEL_DEST"
        log "Installing sygen wheel into venv"
        "$VENV_PIP" install --quiet "$CORE_WHEEL_DEST" \
            || die "pip install of sygen wheel failed"
        rm -f "$CORE_WHEEL_DEST"
    fi
fi
[ -x "$VENV_SYGEN_BIN" ] \
    || die "sygen entry point missing at $VENV_SYGEN_BIN after install"

# Updater shares the same venv. Installed from a separate wheel/tarball
# but uses the same Python so we don't pay for two interpreters.
if [ "$RELEASE_SOURCE" = "source" ]; then
    UPDATER_SOURCE_DIR="${SYGEN_UPDATER_SOURCE_DIR:-${CORE_SOURCE_DIR%/sygen}/sygen-updater}"
    if [ -d "$UPDATER_SOURCE_DIR" ]; then
        log "Installing sygen-updater from local checkout: $UPDATER_SOURCE_DIR"
        "$VENV_PIP" install --quiet "$UPDATER_SOURCE_DIR" \
            || warn "pip install $UPDATER_SOURCE_DIR failed — updater service will be inactive"
    else
        warn "sygen-updater checkout not found at $UPDATER_SOURCE_DIR — set SYGEN_UPDATER_SOURCE_DIR to enable the updater"
    fi
else
    # The updater is versioned alongside core for now — same git tag.
    UPDATER_WHEEL="sygen_updater-${EFFECTIVE_CORE_VERSION}-py3-none-any.whl"
    UPDATER_WHEEL_URL="$(gh_release_url "$CORE_GITHUB_REPO" "$EFFECTIVE_CORE_VERSION" "$UPDATER_WHEEL")"
    UPDATER_WHEEL_DEST="/tmp/sygen-updater-${EFFECTIVE_CORE_VERSION}-${$}.whl"
    # P0-2 + P0-5: verify SHA256 if asset exists, else best-effort skip
    # (updater is non-critical for first install; admin still works
    # without it). Skip path is unchanged from previous behaviour.
    _probe=0
    gh_release_asset_exists "$UPDATER_WHEEL_URL" || _probe=$?
    if [ "$_probe" = "0" ]; then
        log "Downloading + verifying sygen-updater wheel ${EFFECTIVE_CORE_VERSION}"
        fetch_release_asset_verified "$UPDATER_WHEEL_URL" "$UPDATER_WHEEL_DEST"
        log "Installing sygen-updater wheel into venv"
        "$VENV_PIP" install --quiet "$UPDATER_WHEEL_DEST" \
            || warn "pip install sygen-updater failed — updater service inactive"
        rm -f "$UPDATER_WHEEL_DEST"
    else
        warn "sygen-updater wheel not yet published at $UPDATER_WHEEL_URL — updater service will be inactive until next release"
        rm -f "$UPDATER_WHEEL_DEST" 2>/dev/null || true
    fi
fi

# ----- 5b. Admin: download tarball, extract Next.js standalone build -----
log "Installing sygen-admin to $ADMIN_DIR"
# Admin tarball ships the Next.js standalone output (server.js,
# minimal node_modules, .next/static, public/) — runtime only, no build
# step on the host.
mkdir -p "$ADMIN_DIR" "$ADMIN_PREV_DIR"

# Atomic swap: extract the new tarball into admin-staging, then mv-rename.
# Keeps the previous admin around at admin-prev/ for one-step rollback.
ADMIN_STAGING_DIR="$SYGEN_ROOT/admin-staging-$$"
mkdir -p "$ADMIN_STAGING_DIR"
# P0-1 fix: stack the staging cleanup *and* on_exit so a die() between
# here and the post-swap trap reset still flushes the manifest. Without
# the on_exit call the partial install would orphan brew packages on
# the next re-run (see manifest_load classification logic).
trap 'rm -rf "$ADMIN_STAGING_DIR" 2>/dev/null || true; on_exit' EXIT

if [ "$RELEASE_SOURCE" = "source" ]; then
    [ -n "$ADMIN_SOURCE_DIR" ] && [ -d "$ADMIN_SOURCE_DIR" ] \
        || die "SYGEN_RELEASE_SOURCE=source requires SYGEN_ADMIN_SOURCE_DIR=<path-to-sygen-admin-checkout>"
    log "Building sygen-admin from local checkout: $ADMIN_SOURCE_DIR (npm ci + npm run build)"
    pushd "$ADMIN_SOURCE_DIR" >/dev/null \
        || die "could not enter $ADMIN_SOURCE_DIR"
    NEXT_PUBLIC_APP_VERSION="$EFFECTIVE_ADMIN_VERSION" \
        "$NODE_BIN" "$(dirname "$NODE_BIN")/npm" ci --no-audit --no-fund \
        || die "npm ci failed in $ADMIN_SOURCE_DIR"
    NEXT_PUBLIC_APP_VERSION="$EFFECTIVE_ADMIN_VERSION" \
        "$NODE_BIN" "$(dirname "$NODE_BIN")/npm" run build \
        || die "npm run build failed in $ADMIN_SOURCE_DIR"
    # Reproduce the tarball layout: standalone bundle + static + public.
    mkdir -p "$ADMIN_STAGING_DIR/.next"
    cp -R .next/standalone/. "$ADMIN_STAGING_DIR/"
    cp -R .next/static "$ADMIN_STAGING_DIR/.next/static"
    if [ -d public ]; then
        cp -R public "$ADMIN_STAGING_DIR/public"
    fi
    popd >/dev/null
else
    ADMIN_TARBALL="sygen-admin-${EFFECTIVE_ADMIN_VERSION}.tar.gz"
    ADMIN_TARBALL_URL="$(gh_release_url "$ADMIN_GITHUB_REPO" "$EFFECTIVE_ADMIN_VERSION" "$ADMIN_TARBALL")"
    ADMIN_TARBALL_DEST="/tmp/sygen-admin-${EFFECTIVE_ADMIN_VERSION}-${$}.tar.gz"
    # P0-5: probe before download so a missing release surfaces a
    # clear message (or auto-falls-back to source build).
    _probe=0
    gh_release_asset_exists "$ADMIN_TARBALL_URL" || _probe=$?
    if [ "$_probe" = "1" ]; then
        if [ -n "$ADMIN_SOURCE_DIR" ] && [ -d "$ADMIN_SOURCE_DIR" ]; then
            warn "sygen-admin tarball ${EFFECTIVE_ADMIN_VERSION} not published yet — falling back to local checkout at $ADMIN_SOURCE_DIR"
            pushd "$ADMIN_SOURCE_DIR" >/dev/null \
                || die "could not enter $ADMIN_SOURCE_DIR"
            NEXT_PUBLIC_APP_VERSION="$EFFECTIVE_ADMIN_VERSION" \
                "$NODE_BIN" "$(dirname "$NODE_BIN")/npm" ci --no-audit --no-fund \
                || die "npm ci failed in $ADMIN_SOURCE_DIR (fallback after missing release)"
            NEXT_PUBLIC_APP_VERSION="$EFFECTIVE_ADMIN_VERSION" \
                "$NODE_BIN" "$(dirname "$NODE_BIN")/npm" run build \
                || die "npm run build failed in $ADMIN_SOURCE_DIR (fallback after missing release)"
            mkdir -p "$ADMIN_STAGING_DIR/.next"
            cp -R .next/standalone/. "$ADMIN_STAGING_DIR/"
            cp -R .next/static "$ADMIN_STAGING_DIR/.next/static"
            if [ -d public ]; then
                cp -R public "$ADMIN_STAGING_DIR/public"
            fi
            popd >/dev/null
        else
            die "sygen-admin tarball not yet published at $ADMIN_TARBALL_URL. Either wait for the release, set SYGEN_ADMIN_VERSION=<existing-tag>, or re-run with SYGEN_RELEASE_SOURCE=source SYGEN_ADMIN_SOURCE_DIR=<path-to-sygen-admin-checkout>"
        fi
    else
        log "Downloading sygen-admin tarball ${EFFECTIVE_ADMIN_VERSION} from GitHub Releases"
        fetch_release_asset_verified "$ADMIN_TARBALL_URL" "$ADMIN_TARBALL_DEST"
        log "Extracting admin tarball into staging dir"
        tar -xzf "$ADMIN_TARBALL_DEST" -C "$ADMIN_STAGING_DIR" \
            || die "tar -xzf failed for admin tarball"
        rm -f "$ADMIN_TARBALL_DEST"
    fi
fi

# Sanity-check: server.js must exist; otherwise the launchd/systemd
# unit will fail-loop with no clear cause.
[ -f "$ADMIN_STAGING_DIR/server.js" ] \
    || die "admin tarball/build missing server.js — check release artefact layout"

# P1-6 fix: stop-before-swap so launchd's KeepAlive doesn't respawn into
# the empty $ADMIN_DIR window between the two `mv` calls. Best-effort —
# on a fresh install the service isn't running yet, so unload/disable
# silently no-ops. Linux uses systemctl; macOS uses launchctl.
if [ -d "$ADMIN_DIR" ] && [ -n "$(ls -A "$ADMIN_DIR" 2>/dev/null)" ]; then
    if [ $LOCAL_MODE -eq 1 ]; then
        launchctl unload "$HOME/Library/LaunchAgents/pro.sygen.admin.plist" >/dev/null 2>&1 || true
    else
        systemctl stop sygen-admin.service >/dev/null 2>&1 || true
    fi
    rm -rf "$ADMIN_PREV_DIR"
    mv "$ADMIN_DIR" "$ADMIN_PREV_DIR"
fi
mv "$ADMIN_STAGING_DIR" "$ADMIN_DIR"
trap on_exit EXIT  # restore the install-wide trap (the post-swap
                   # service-install block re-loads/re-starts the unit)

manifest_set_native_paths "$VENV_DIR" "$ADMIN_DIR" \
    "$EFFECTIVE_CORE_VERSION" "$EFFECTIVE_ADMIN_VERSION"

# ---------- 5b. Host metrics daemon (macOS + Linux) ----------
# Writes live host CPU/RAM/disk usage to $SYGEN_ROOT/host_metrics/state.json
# every 10 s. The PARENT DIRECTORY is bind-mounted into sygen-core read-only
# at /data/host_metrics so the dashboard reports host-true USED values
# (psutil inside Colima only sees the VM; on bare-metal Linux the daemon
# agrees with /proc). Directory bind (not file bind) is required because
# Colima freezes the container inode of a single-file mount at start time,
# so the daemon's atomic-rename writes leave the container reading an
# orphan inode (v1.6.32 fix).
STAGE="host-metrics"
log "Installing host_metrics_daemon → $SYGEN_ROOT/host_metrics/state.json"

mkdir -p "$SYGEN_ROOT/bin" "$SYGEN_ROOT/logs" "$SYGEN_ROOT/host_metrics"

curl -fsSL -o "$SYGEN_ROOT/bin/host_metrics_daemon.py" \
    "$BASE_URL/scripts/host_metrics_daemon.py" \
    || die "could not fetch host_metrics_daemon.py"
chmod 0755 "$SYGEN_ROOT/bin/host_metrics_daemon.py"

# Touch state.json inside the bind-mounted directory so docker-compose has a
# real target on first up (the directory itself is enough but keeping a
# placeholder makes /api/system/status return supported:false-with-stale
# instead of file-missing during the few seconds before the daemon writes).
touch "$SYGEN_ROOT/host_metrics/state.json"
chmod 0644 "$SYGEN_ROOT/host_metrics/state.json"

# Migrate any pre-v1.6.32 single-file artifact left from an older install.
# Without this the old `host_metrics.json` lingers on disk forever and
# confuses operators who grep for it. Safe: the path is no longer read.
if [ -f "$SYGEN_ROOT/host_metrics.json" ]; then
    rm -f "$SYGEN_ROOT/host_metrics.json"
fi

# P1-8 fix: don't reassign $PYTHON_BIN here — that would clobber the
# brew python@3.14 path resolved during deps stage and stamp the
# launchd/systemd unit with /usr/bin/python3 (Apple stub) instead. Use
# a separate variable so host_metrics has its own preference (brew
# python first via $PYTHON_BIN, system python3 only as a fallback).
HOST_METRICS_PYTHON="${PYTHON_BIN:-}"
if [ -z "$HOST_METRICS_PYTHON" ]; then
    HOST_METRICS_PYTHON="$(command -v python3 || true)"
fi
[ -n "$HOST_METRICS_PYTHON" ] || die "python3 not found — required for host_metrics_daemon"

if [ $LOCAL_MODE -eq 1 ]; then
    # macOS — launchd LaunchAgent (per-user, runs in user session).
    PLIST_DST="$HOME/Library/LaunchAgents/com.sygen.host-metrics.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    curl -fsSL -o /tmp/sygen.host-metrics.plist.tmpl \
        "$BASE_URL/scripts/com.sygen.host-metrics.plist" \
        || die "could not fetch com.sygen.host-metrics.plist"
    sed \
        -e "s|__PYTHON__|$HOST_METRICS_PYTHON|g" \
        -e "s|__SCRIPT__|$SYGEN_ROOT/bin/host_metrics_daemon.py|g" \
        -e "s|__SYGEN_ROOT__|$SYGEN_ROOT|g" \
        /tmp/sygen.host-metrics.plist.tmpl > "$PLIST_DST"
    rm -f /tmp/sygen.host-metrics.plist.tmpl
    # Defensive: if umask was 077 from an earlier section the redirect
    # creates the plist 0600, which launchd silently refuses to load
    # ("file is owned by you but not readable"). Force 0644.
    chmod 0644 "$PLIST_DST"

    # Idempotent reload: unload an old copy if present, then load fresh.
    launchctl unload "$PLIST_DST" >/dev/null 2>&1 || true
    launchctl load -w "$PLIST_DST" \
        || warn "launchctl load failed — host metrics daemon inactive"
    manifest_record_plist "com.sygen.host-metrics"
else
    # Linux — systemd unit, system-wide.
    UNIT_DST="/etc/systemd/system/sygen-host-metrics.service"
    curl -fsSL -o /tmp/sygen-host-metrics.service.tmpl \
        "$BASE_URL/scripts/sygen-host-metrics.service" \
        || die "could not fetch sygen-host-metrics.service"
    sed \
        -e "s|__PYTHON__|$HOST_METRICS_PYTHON|g" \
        -e "s|__SCRIPT__|$SYGEN_ROOT/bin/host_metrics_daemon.py|g" \
        -e "s|__SYGEN_ROOT__|$SYGEN_ROOT|g" \
        /tmp/sygen-host-metrics.service.tmpl > "$UNIT_DST"
    rm -f /tmp/sygen-host-metrics.service.tmpl

    systemctl daemon-reload
    systemctl enable --now sygen-host-metrics.service \
        || warn "systemd enable failed — host metrics will fall back to /proc"
fi

# ---------- 5c. Keychain → file sync — OPT-IN, NOT installed by default ----------
# Sub-agents run on the host CLI by default (`docker.enabled: false` in
# every per-agent config), so the host's Keychain is read natively and
# the sync daemon is unnecessary. The daemon ships in scripts/ for users
# who explicitly want Docker-isolated sub-agents (`docker.enabled: true`)
# — they can install it on demand:
#
#   bash scripts/deploy_keychain_sync.sh
#
# See scripts/keychain_sync_daemon.py + com.sygen.keychain-sync.plist.

# ---------- 5d. Host updates check + apply runner (macOS only) ----------
# Two daemons that together implement the "host-level updates" banner:
#
#   - host_updates_check.sh runs at load + weekly (Sun 04:30) and writes
#     $SYGEN_ROOT/host_updates/state.json describing which allow-listed
#     Homebrew packages (colima/nginx/certbot/docker/jq/openssl/tailscale)
#     are outdated.
#   - host_update_runner.sh sits in a 5-second poll loop watching for
#     $SYGEN_ROOT/host_updates/requested. Core writes that file when
#     admin POSTs /api/system/host-updates/apply; the runner validates
#     against the same allowlist, runs `brew upgrade <pkgs>`, and on
#     Colima upgrade restarts the VM cleanly.
#
# Linux is skipped — apt-get/dnf-driven update flows are out of scope
# for this iteration (Linux installs are server-class and operators
# manage `unattended-upgrades` themselves).
if [ $LOCAL_MODE -eq 1 ]; then
    STAGE="host-updates"
    log "Installing host_updates check + apply runner"

    mkdir -p "$SYGEN_ROOT/bin" "$SYGEN_ROOT/logs" "$SYGEN_ROOT/host_updates"

    curl -fsSL -o "$SYGEN_ROOT/bin/host_updates_check.sh" \
        "$BASE_URL/scripts/host_updates_check.sh" \
        || die "could not fetch host_updates_check.sh"
    chmod 0755 "$SYGEN_ROOT/bin/host_updates_check.sh"

    curl -fsSL -o "$SYGEN_ROOT/bin/host_update_runner.sh" \
        "$BASE_URL/scripts/host_update_runner.sh" \
        || die "could not fetch host_update_runner.sh"
    chmod 0755 "$SYGEN_ROOT/bin/host_update_runner.sh"

    # Stub out state.json so docker-compose doesn't race the first check.
    if [ ! -f "$SYGEN_ROOT/host_updates/state.json" ]; then
        printf '{"supported":false,"reason":"initial install"}\n' \
            > "$SYGEN_ROOT/host_updates/state.json"
    fi
    chmod 0644 "$SYGEN_ROOT/host_updates/state.json"

    # One-shot check before the daemon takes over so the dashboard's
    # very first GET sees real data.
    SYGEN_ROOT="$SYGEN_ROOT" "$SYGEN_ROOT/bin/host_updates_check.sh" \
        --output "$SYGEN_ROOT/host_updates/state.json" \
        || warn "initial host_updates check failed — daemon will retry"

    # Install both plists.
    install_host_update_plist() {
        local label="$1"
        local script="$2"
        local plist_dst="$HOME/Library/LaunchAgents/$label.plist"
        local tmpl="/tmp/$label.plist.tmpl"

        mkdir -p "$HOME/Library/LaunchAgents"
        curl -fsSL -o "$tmpl" "$BASE_URL/scripts/$label.plist" \
            || die "could not fetch $label.plist"
        sed \
            -e "s|__SCRIPT__|$script|g" \
            -e "s|__SYGEN_ROOT__|$SYGEN_ROOT|g" \
            -e "s|__HOME__|$HOME|g" \
            "$tmpl" > "$plist_dst"
        rm -f "$tmpl"
        # Defensive: see host-metrics block — 0600 plists won't load.
        chmod 0644 "$plist_dst"

        launchctl unload "$plist_dst" >/dev/null 2>&1 || true
        launchctl load -w "$plist_dst" \
            || warn "launchctl load failed for $label — host updates surface unchanged"
        manifest_record_plist "$label"
    }
    install_host_update_plist "com.sygen.host-updates-check" \
        "$SYGEN_ROOT/bin/host_updates_check.sh"
    install_host_update_plist "com.sygen.host-update-runner" \
        "$SYGEN_ROOT/bin/host_update_runner.sh"

    # --- Self-uninstall runner (v1.6.45+) ---
    # Pairs with /api/system/uninstall on core. Drops a local copy of
    # uninstall.sh into $SYGEN_ROOT (so the runner can find it after
    # network goes down or the install dir is partially torn down) and
    # installs the runner under the same launchd pattern.
    log "Installing self-uninstall runner"

    curl -fsSL -o "$SYGEN_ROOT/uninstall.sh" \
        "$BASE_URL/uninstall.sh" \
        || warn "could not fetch uninstall.sh — admin/iOS Delete Server will fail until you re-run install.sh"
    chmod 0755 "$SYGEN_ROOT/uninstall.sh" 2>/dev/null || true

    curl -fsSL -o "$SYGEN_ROOT/bin/host_uninstall_runner.sh" \
        "$BASE_URL/scripts/host_uninstall_runner.sh" \
        || die "could not fetch host_uninstall_runner.sh"
    chmod 0755 "$SYGEN_ROOT/bin/host_uninstall_runner.sh"

    install_host_update_plist "com.sygen.host-uninstall-runner" \
        "$SYGEN_ROOT/bin/host_uninstall_runner.sh"
fi

# ---------- 5e. Whisper.cpp (out-of-box voice transcription) ----------
# Bundled so a fresh install can transcribe voice messages without any
# additional setup. macOS uses brew (which carries upgrades through the
# host_updates allowlist); Linux falls back to apt where available and
# warns otherwise — operators can install manually later.
#
# The ggml-small model (~466 MB) is the sweet spot for quality / size /
# RAM on the boxes Sygen actually ships on. Advanced users can swap to a
# different model via config.json `transcription.model`.
#
# Both OSes write the model under $HOME/.local/share/whisper-cpp/models —
# transcription.py reads from the same path regardless of platform, so a
# Linux SYGEN_ROOT-relative dir would be invisible to the runtime.
#
# Set SKIP_WHISPER=1 to skip this section entirely (e.g. CI, hosts that
# already shipped a model, or operators who want to defer the download).
STAGE="whisper"
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
WHISPER_MODEL_SHA256="1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
WHISPER_MODEL_DIR="$HOME/.local/share/whisper-cpp/models"
WHISPER_MODEL_PATH="$WHISPER_MODEL_DIR/ggml-small.bin"
WHISPER_ERROR_FILE="$HOME/.local/share/whisper-cpp/.last_install_error"

# Helpers — keep failures discoverable via /api/system/voice/config.
_whisper_record_error() {
    mkdir -p "$(dirname "$WHISPER_ERROR_FILE")" 2>/dev/null || true
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
        > "$WHISPER_ERROR_FILE" 2>/dev/null || true
}
_whisper_clear_error() {
    rm -f "$WHISPER_ERROR_FILE" 2>/dev/null || true
}

if [ "${SKIP_WHISPER:-0}" = "1" ]; then
    log "SKIP_WHISPER=1 → skipping whisper.cpp install"
elif [ "$OS" = "Darwin" ]; then
    log "Installing whisper.cpp (out-of-box voice transcription)"
    WHISPER_BIN_OK=0
    if brew list whisper-cpp >/dev/null 2>&1; then
        log "whisper-cpp already installed"
        manifest_record_pkg_preexisting whisper-cpp
        WHISPER_BIN_OK=1
    else
        if brew install whisper-cpp; then
            manifest_record_pkg_installed whisper-cpp
            WHISPER_BIN_OK=1
        else
            _whisper_record_error "brew install whisper-cpp failed"
            warn "brew install whisper-cpp failed — voice transcription will not work until installed"
        fi
    fi

    if [ "$WHISPER_BIN_OK" -eq 1 ]; then
        if [ -f "$WHISPER_MODEL_PATH" ]; then
            log "ggml-small model already present"
            _whisper_clear_error
        else
            log "Downloading whisper.cpp model (~466 MB, 2-5 min on broadband)…"
            log "→ $WHISPER_MODEL_PATH"
            mkdir -p "$WHISPER_MODEL_DIR"
            if curl -fL --progress-bar -o "$WHISPER_MODEL_PATH.tmp" "$WHISPER_MODEL_URL"; then
                ACTUAL_SHA="$(shasum -a 256 "$WHISPER_MODEL_PATH.tmp" 2>/dev/null | awk '{print $1}')"
                if [ "$ACTUAL_SHA" != "$WHISPER_MODEL_SHA256" ]; then
                    rm -f "$WHISPER_MODEL_PATH.tmp" 2>/dev/null || true
                    _whisper_record_error "SHA-256 mismatch (expected $WHISPER_MODEL_SHA256, got ${ACTUAL_SHA:-<unreadable>})"
                    warn "ggml-small SHA-256 mismatch — file deleted, re-run installer"
                else
                    mv "$WHISPER_MODEL_PATH.tmp" "$WHISPER_MODEL_PATH"
                    _whisper_clear_error
                    # Record AFTER the rename so a SHA-mismatch file (which
                    # we delete) never lands in the manifest. On uninstall
                    # this entry is what tells uninstall.sh to remove the
                    # ~466 MB model from $HOME/.local/share/whisper-cpp.
                    manifest_record_downloaded "$WHISPER_MODEL_PATH" "whisper_small_model"
                fi
            else
                rm -f "$WHISPER_MODEL_PATH.tmp" 2>/dev/null || true
                _whisper_record_error "curl download failed: $WHISPER_MODEL_URL"
                warn "ggml-small download failed — re-run: curl -fL -o $WHISPER_MODEL_PATH $WHISPER_MODEL_URL"
            fi
        fi
    fi
elif [ "$OS" = "Linux" ]; then
    # Since v1.6.48 the sygen-core container ships its own whisper-cli
    # (built from source in the Dockerfile), so a successful host apt-install
    # is no longer required for voice transcription to work — the model is
    # bind-mounted into the container regardless. We still try apt as a
    # best-effort so host-side tools (scripts/deploy_whisper.sh, ad-hoc
    # admin SSH sessions) keep working where the package is available.
    log "Installing whisper.cpp model (container ships whisper-cli; host package is best-effort)"
    if command -v whisper-cli >/dev/null 2>&1 || command -v whisper-cpp >/dev/null 2>&1; then
        log "whisper.cpp already installed on host"
    elif command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu: package is `whisper.cpp` in trixie+/24.10+ universe.
        # Older releases (incl. Bookworm) don't carry it — that's fine,
        # the container build covers the runtime path.
        if apt-get install -y -qq whisper-cpp 2>/dev/null \
                || apt-get install -y -qq whisper.cpp 2>/dev/null; then
            log "whisper.cpp installed on host via apt"
        else
            log "whisper.cpp not in this apt release — skipping host install (container has it)"
        fi
    fi

    # Always download the model. The container's whisper-cli reads it via
    # the SYGEN_HOST_WHISPER_MODELS_DIR bind-mount (docker-compose.yml), so
    # apt-install state on the host no longer gates voice support.
    mkdir -p "$WHISPER_MODEL_DIR"
    if [ -f "$WHISPER_MODEL_PATH" ]; then
        log "ggml-small model already present"
        _whisper_clear_error
    else
        log "Downloading whisper.cpp model (~466 MB, 2-5 min on broadband)…"
        log "→ $WHISPER_MODEL_PATH"
        if curl -fL --progress-bar -o "$WHISPER_MODEL_PATH.tmp" "$WHISPER_MODEL_URL"; then
            ACTUAL_SHA="$(sha256sum "$WHISPER_MODEL_PATH.tmp" 2>/dev/null | awk '{print $1}')"
            if [ "$ACTUAL_SHA" != "$WHISPER_MODEL_SHA256" ]; then
                rm -f "$WHISPER_MODEL_PATH.tmp" 2>/dev/null || true
                _whisper_record_error "SHA-256 mismatch (expected $WHISPER_MODEL_SHA256, got ${ACTUAL_SHA:-<unreadable>})"
                warn "ggml-small SHA-256 mismatch — file deleted, re-run installer"
            else
                mv "$WHISPER_MODEL_PATH.tmp" "$WHISPER_MODEL_PATH"
                _whisper_clear_error
                # See macOS branch for rationale — record only after the
                # file passes SHA verify and is renamed into place.
                manifest_record_downloaded "$WHISPER_MODEL_PATH" "whisper_small_model"
            fi
        else
            rm -f "$WHISPER_MODEL_PATH.tmp" 2>/dev/null || true
            _whisper_record_error "curl download failed: $WHISPER_MODEL_URL"
            warn "ggml-small download failed — re-run: curl -fL -o $WHISPER_MODEL_PATH $WHISPER_MODEL_URL"
        fi
    fi
fi

# ---------- 6. Install + start native services ----------
STAGE="services"
log "Installing native services (core/admin/updater) and starting them"

# Resolve the system-wide python (needed for the launchd PYTHON_BIN spot
# in plists, etc) — already done in deps stage.
[ -x "$VENV_SYGEN_BIN" ] || die "internal: venv sygen binary missing — install stage failed silently"

if [ $LOCAL_MODE -eq 1 ]; then
    # ----- macOS: per-user LaunchAgents in $HOME/Library/LaunchAgents -----
    mkdir -p "$HOME/Library/LaunchAgents"

    install_native_plist() {
        # $1=label (without .plist)  $2=template basename in scripts/
        local label="$1"
        local tmpl_name="$2"
        local plist_dst="$HOME/Library/LaunchAgents/${label}.plist"
        local tmpl="/tmp/${label}.plist.tmpl"
        curl -fsSL -o "$tmpl" "$BASE_URL/scripts/${tmpl_name}" \
            || die "could not fetch $tmpl_name template from $BASE_URL/scripts/"
        sed \
            -e "s|__SYGEN_ROOT__|$SYGEN_ROOT|g" \
            -e "s|__VENV_DIR__|$VENV_DIR|g" \
            -e "s|__ADMIN_DIR__|$ADMIN_DIR|g" \
            -e "s|__NODE_BIN__|$NODE_BIN|g" \
            -e "s|__SYGEN_ADMIN_PORT__|$SYGEN_ADMIN_PORT|g" \
            -e "s|__HOME__|$HOME|g" \
            "$tmpl" > "$plist_dst"
        rm -f "$tmpl"
        # 0644 — launchd silently refuses 0600 plists (umask 077 from .env
        # write would otherwise clip to 0600).
        chmod 0644 "$plist_dst"
        # Idempotent reload: unload prior copy, load+RunAtLoad fires the job.
        launchctl unload "$plist_dst" >/dev/null 2>&1 || true
        launchctl load -w "$plist_dst" \
            || warn "launchctl load failed for $label — service inactive (re-run install.sh after fixing)"
        manifest_record_autostart_plist "$label"
    }

    install_native_plist "pro.sygen.core"    "pro.sygen.core.plist"
    install_native_plist "pro.sygen.admin"   "pro.sygen.admin.plist"
    # Updater is best-effort — it may not be installed yet (wheel not
    # published). Skip the plist if its binary is missing.
    if [ -x "$VENV_UPDATER_BIN" ]; then
        install_native_plist "pro.sygen.updater" "pro.sygen.updater.plist"
    else
        log "  skipping pro.sygen.updater plist — updater binary not installed yet"
    fi
else
    # ----- Linux: systemd units, system-wide -----
    install_native_unit() {
        # $1=unit filename (e.g. sygen-core.service)
        local unit="$1"
        local unit_dst="/etc/systemd/system/$unit"
        local tmpl="/tmp/$unit.tmpl"
        curl -fsSL -o "$tmpl" "$BASE_URL/scripts/$unit" \
            || die "could not fetch $unit template from $BASE_URL/scripts/"
        sed \
            -e "s|__SYGEN_ROOT__|$SYGEN_ROOT|g" \
            -e "s|__VENV_DIR__|$VENV_DIR|g" \
            -e "s|__ADMIN_DIR__|$ADMIN_DIR|g" \
            -e "s|__NODE_BIN__|$NODE_BIN|g" \
            -e "s|__SYGEN_ADMIN_PORT__|$SYGEN_ADMIN_PORT|g" \
            "$tmpl" > "$unit_dst"
        rm -f "$tmpl"
        chmod 0644 "$unit_dst"
        manifest_record_autostart_linux_unit "$unit_dst"
    }

    install_native_unit "sygen-core.service"
    install_native_unit "sygen-admin.service"
    if [ -x "$VENV_UPDATER_BIN" ]; then
        install_native_unit "sygen-updater.service"
    else
        log "  skipping sygen-updater.service — updater binary not installed yet"
    fi

    systemctl daemon-reload
    systemctl enable --now sygen-core.service \
        || warn "systemctl enable sygen-core failed — see: journalctl -u sygen-core -n 50"
    systemctl enable --now sygen-admin.service \
        || warn "systemctl enable sygen-admin failed — see: journalctl -u sygen-admin -n 50"
    if [ -x "$VENV_UPDATER_BIN" ]; then
        systemctl enable --now sygen-updater.service \
            || warn "systemctl enable sygen-updater failed (non-fatal)"
    fi
fi

# ---------- 6b. macOS smoke-test (Linux uses nginx + Let's Encrypt to verify) ----------
if [ $LOCAL_MODE -eq 1 ]; then
    STAGE="smoke"
    log "macOS: smoke-testing endpoints (admin :${SYGEN_ADMIN_PORT}, core :8081)"
    smoke_ok=0
    # NOTE: -f turns 4xx/5xx into curl-exit-1, which then triggers the
    # `|| echo 000` branch — and curl has ALREADY printed the status code
    # to stdout via -w, so the captured value becomes "401000" / "404000".
    # That broke the case-match on perfectly healthy services. Drop -f
    # so HTTP statuses go through unchanged; the OR-fallback only fires
    # on actual connect failures (where -w produces nothing).
    for i in $(seq 1 30); do
        admin_ok=0
        core_ok=0
        # Admin Next server returns 200 on /, but during boot it may 404
        # /_next assets — accept any non-5xx as "alive".
        admin_code=$(curl -sS -o /dev/null -w '%{http_code}' \
            "http://localhost:${SYGEN_ADMIN_PORT}" 2>/dev/null || echo "000")
        case "$admin_code" in 200|301|302|404) admin_ok=1 ;; esac
        # Core /api/system/status is unauthenticated-discoverable: returns
        # 200 if you have a token, 401 otherwise. Both prove the server
        # is up and routing — only a connect failure is a smoke-test fail.
        core_code=$(curl -sS -o /dev/null -w '%{http_code}' \
            "http://localhost:8081/api/system/status" 2>/dev/null || echo "000")
        case "$core_code" in 200|401|403) core_ok=1 ;; esac
        if [ "$admin_ok" -eq 1 ] && [ "$core_ok" -eq 1 ]; then
            log "  endpoints responding (admin=$admin_code core=$core_code)"
            smoke_ok=1
            break
        fi
        sleep 2
    done
    if [ "$smoke_ok" -ne 1 ]; then
        warn "Smoke test failed after 60s: admin=$admin_code core=$core_code."
        warn "Check: 'launchctl list | grep pro.sygen' and tail $SYGEN_ROOT/logs/{core,admin}.log"
    fi
fi

# ---------- 7. nginx vhost (Linux + macOS publicdomain) ----------
if [ $LOCAL_MODE -eq 0 ] && [ "$SELF_HOSTED_SUBMODE" != "tailscale" ]; then
    # Linux auto-mode + custom-mode: standard apt nginx + Let's Encrypt cert.
    # Linux+tailscale skips this — `tailscale serve` handles TLS termination
    # in the dedicated block below.
    STAGE="nginx"
    log "Configuring nginx vhost for $FQDN"
    curl -fsSL -o /tmp/sygen.nginx.tmpl "$BASE_URL/nginx.conf.tmpl" \
        || die "could not fetch nginx.conf.tmpl"
    sed \
        -e "s/__FQDN__/$FQDN/g" \
        -e "s|__CERT_DIR__|${CERTBOT_LIVE_DIR}|g" \
        /tmp/sygen.nginx.tmpl > "/etc/nginx/sites-available/sygen"
    ln -sf "/etc/nginx/sites-available/sygen" /etc/nginx/sites-enabled/sygen
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl reload nginx
elif [ "$SELF_HOSTED_SUBMODE" = "publicdomain" ]; then
    STAGE="nginx"
    # brew nginx serves vhosts from $(brew --prefix)/etc/nginx/servers/*.conf
    # (loaded by the default nginx.conf via `include servers/*`). The admin
    # container binds to localhost:$SYGEN_ADMIN_PORT (instead of :3000) on
    # macOS, so the proxy_pass needs to reflect that.
    BREW_PREFIX="$(brew --prefix)"
    BREW_NGINX_PREFIX="$(brew --prefix nginx 2>/dev/null || echo "$BREW_PREFIX")"
    NGINX_CONF_DIR="$BREW_NGINX_PREFIX/etc/nginx/servers"
    if [ ! -d "$NGINX_CONF_DIR" ]; then
        NGINX_CONF_DIR="$BREW_PREFIX/etc/nginx/servers"
    fi
    $SUDO mkdir -p "$NGINX_CONF_DIR"

    log "Configuring brew nginx vhost for $FQDN at $NGINX_CONF_DIR/sygen.conf"
    curl -fsSL -o /tmp/sygen.nginx.tmpl "$BASE_URL/nginx.conf.tmpl" \
        || die "could not fetch nginx.conf.tmpl"
    # Substitute __FQDN__, the cert dir (Linux: /etc/letsencrypt;
    # macOS-publicdomain: $SYGEN_ROOT/letsencrypt), and remap the admin
    # upstream from :3000 to the mac-side host port chosen earlier
    # (default 8080). Core stays on :8081.
    sed \
        -e "s/__FQDN__/$FQDN/g" \
        -e "s|__CERT_DIR__|${CERTBOT_LIVE_DIR}|g" \
        -e "s|http://127.0.0.1:3000|http://127.0.0.1:${SYGEN_ADMIN_PORT}|g" \
        /tmp/sygen.nginx.tmpl \
        | $SUDO tee "$NGINX_CONF_DIR/sygen.conf" >/dev/null

    # Validate before (re)starting; sudo nginx -t reads the same conf set
    # as the running service so a syntax error gets caught here, not at boot.
    $SUDO nginx -t || die "nginx -t failed — see error above"

    # Binding 80/443 requires root on macOS. nginx daemonizes by default,
    # so a plain 'sudo nginx' is enough for the install run. We deliberately
    # don't wire up launchd auto-start here — surviving reboots on a self-
    # hosted Mac is an operator concern (and brew-services-as-root has its
    # own warts on Apple Silicon). Document manual restart in the summary.
    #
    # Identify whether the running nginx is OUR brew install. lsof on a
    # listening master pid + path comparison: if we'd `nginx -s reload` an
    # unrelated nginx (Wordpress dev, Pow, MAMP, a system-package nginx
    # from a previous user), we'd silently re-load THEIR config including
    # OUR sygen.conf — possibly conflicting with their server blocks. Bail
    # with diagnostic instead.
    nginx_running_is_ours() {
        local master_pid
        master_pid=$(pgrep -f 'nginx: master' 2>/dev/null | head -n1 || true)
        [ -z "$master_pid" ] && return 2  # no running nginx at all
        local cmd
        cmd=$(/bin/ps -o args= -p "$master_pid" 2>/dev/null || true)
        case "$cmd" in
            *"$BREW_NGINX_PREFIX/"*|*"$BREW_PREFIX/"*) return 0 ;;
            *) return 1 ;;
        esac
    }

    # Pre-flight: someone already on 80/443? nginx will fail with
    # "bind() to 0.0.0.0:80 failed (48: Address already in use)" — surface
    # the actual occupant so the operator knows what to stop. Apple's
    # Web Sharing (System Settings → Sharing → Content Caching/File Sharing)
    # and ControlCenter both bind 80 on a fresh Mac.
    check_port() {
        local port="$1"
        local hits
        hits=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2 || true)
        if [ -n "$hits" ]; then
            local pid_proc
            pid_proc=$(printf '%s\n' "$hits" | awk '{print $2 " ("$1")"}' | head -n1)
            # Allow our own already-running nginx to keep 80/443 — the
            # reload branch below will pick it up.
            if printf '%s' "$hits" | awk '{print $1}' | grep -qi '^nginx$' \
                    && nginx_running_is_ours; then
                return 0
            fi
            die "Port $port is already in use by PID $pid_proc. Stop that process first (e.g. 'sudo kill ${pid_proc%% *}'), or for Apple's built-in Web Sharing: System Settings → General → Sharing → disable Content Caching / File Sharing. Then re-run."
        fi
    }

    if nginx_running_is_ours; then
        log "Reloading running brew nginx"
        $SUDO nginx -s reload || die "nginx reload failed"
    else
        # If a different nginx is running, refuse to touch it — reloading
        # would re-read OUR sygen.conf into THEIR config tree.
        if pgrep -f 'nginx: master' >/dev/null 2>&1; then
            die "An nginx process is running but it does NOT appear to be the brew install at $BREW_NGINX_PREFIX. Refusing to reload someone else's nginx with our sygen.conf. Stop it first (or remove this conflict and re-run): sudo nginx -s stop"
        fi
        check_port 80
        check_port 443
        log "Starting nginx (sudo nginx)"
        $SUDO nginx || die "could not start nginx — check 'sudo nginx -t' for syntax errors and 'lsof -nP -iTCP:80,443 -sTCP:LISTEN' for port conflicts"
    fi
elif [ "$SELF_HOSTED_SUBMODE" = "tailscale" ]; then
    STAGE="nginx"
    # Tailscale terminates TLS itself via `tailscale serve`; no nginx needed.
    log "Configuring 'tailscale serve' for $FQDN (tailnet HTTPS termination)"

    # Use the binary resolved earlier (PATH on Linux / .app bundle on
    # macOS App-Store installs). Falling back to a bare `tailscale` here
    # would re-introduce the App-Store-CLI failure mode we just fixed.
    : "${TAILSCALE_BIN:=tailscale}"

    # macOS Tailscale.app runs tailscaled as root via system extension /
    # launchd; the CLI talks to the daemon over a user-accessible unix
    # socket, so sudo is unnecessary and actively harmful — it would
    # prompt for a password we can't supply over a non-TTY install (the
    # iOS launcher uses `nohup bash -c ...` without -tt). On Linux the
    # apt-installed daemon owns its socket as root, so the CLI does
    # need sudo for any state-mutating call (serve, reset).
    TAILSCALE_SUDO=""
    if [ "$LOCAL_MODE" -eq 0 ]; then
        TAILSCALE_SUDO="sudo"
    fi

    # Helper: run a tailscale subcommand and surface its real stderr to
    # the operator. Replaces the static "is HTTPS enabled?" guess that
    # blamed the wrong thing 90% of the time.
    #
    # Round-5 hardening:
    #  - stdin redirected from /dev/null so a CLI that wants confirmation
    #    (e.g. "Serve is not enabled — visit URL ...") gets EOF and exits
    #    immediately instead of hanging forever.
    #  - "Serve is not enabled" detected explicitly: the CLI prints the
    #    enable URL and the message bypasses normal exit codes. We emit
    #    a structured tailnet_feature_gate error so the iOS app can show
    #    the URL on the failure card.
    _ts_run() {
        local label="$1"; shift
        local fatal="$1"; shift
        local out
        # Note: redirect stdin BEFORE the command so a hung interactive
        # prompt doesn't keep install.sh blocked. Some Tailscale builds
        # write the gate notice to stdout, others to stderr — capture both.
        out="$($TAILSCALE_SUDO "$TAILSCALE_BIN" "$@" </dev/null 2>&1)"
        local rc=$?

        # Tailnet feature gate: succeed-or-die outcome doesn't apply —
        # the CLI may print the gate notice and still return 0. Match on
        # the message itself so both 0 and non-0 exits are caught.
        if printf '%s' "$out" | grep -q "Serve is not enabled"; then
            local enable_url
            enable_url="$(printf '%s' "$out" | grep -oE 'https://login\.tailscale\.com/[^[:space:]]+' | head -n1)"
            local hint="Tailscale Serve is not enabled on your tailnet."
            if [ -n "$enable_url" ]; then
                hint="$hint Open $enable_url to enable it, then re-run the install."
            else
                hint="$hint Enable it at https://login.tailscale.com/admin/dns then re-run the install."
            fi
            die "$hint"
        fi

        # Tailnet HTTPS Certificates feature is a separate gate from Serve:
        # tailnets with MagicDNS but without HTTPS Certificates will fail
        # `tailscale serve` with messages like "your tailnet does not
        # support HTTPS", "TLS not configured", "no certificate". The user
        # must enable HTTPS Certificates in the tailnet admin DNS panel.
        # Match case-insensitively because Tailscale wording shifts between
        # versions.
        if printf '%s' "$out" | grep -qiE 'https.*not.*(supported|configured|enabled)|tls.*not.*(configured|available)|certificate.*not.*(configured|available)|enable.*https.*certificate|ssl.*not.*configured'; then
            die "Tailnet HTTPS Certificates feature is not enabled. Open https://login.tailscale.com/admin/dns and turn on 'HTTPS Certificates' (under MagicDNS), then re-run the install. Raw output: $(printf '%s' "$out" | head -n3 | tr '\n' ' ')"
        fi

        if [ $rc -ne 0 ]; then
            local first
            first="$(printf '%s' "$out" | head -n1)"
            if [ "$fatal" = "1" ]; then
                die "tailscale ${label} failed: ${first}"
            else
                warn "tailscale ${label} failed (non-fatal): ${first}"
                return 1
            fi
        fi
        return 0
    }

    # Wipe any prior config so re-runs end up with the same routes we want.
    # 'reset' is a no-op when no serve config exists.
    $TAILSCALE_SUDO "$TAILSCALE_BIN" serve reset >/dev/null 2>&1 </dev/null || true

    # Mountpoints share port 443; subsequent --bg calls add path handlers
    # to the existing serve config. Order matters: more-specific paths first
    # so they don't get shadowed by the catch-all "/" → admin route.
    #
    # IMPORTANT: backend URLs MUST include the same path as --set-path or
    # Tailscale Serve strips the prefix on the way to the backend. Sygen
    # core expects /api/auth/login etc., not /auth/login, so without the
    # trailing path the proxy returns 404 on every mobile login request.
    # The catch-all "/" mapping has no path to preserve and is fine bare.
    _ts_run "serve /api/"   1 serve --bg --set-path=/api/   "http://127.0.0.1:8081/api/"
    _ts_run "serve /ws/"    1 serve --bg --set-path=/ws/    "http://127.0.0.1:8081/ws/"
    _ts_run "serve /upload" 0 serve --bg --set-path=/upload "http://127.0.0.1:8081/upload"
    _ts_run "serve /"       1 serve --bg "http://127.0.0.1:${SYGEN_ADMIN_PORT}"
fi

# ---------- 8. Wait for admin bootstrap ----------
STAGE="bootstrap"
log "Waiting for core to generate initial admin password..."
PW_FILE="$SYGEN_ROOT/data/_secrets/.initial_admin_password"
ADMIN_PASS=""
for i in $(seq 1 60); do
    if [ -f "$PW_FILE" ]; then
        ADMIN_PASS=$(head -n1 "$PW_FILE")
        break
    fi
    sleep 2
done

# ---------- 9. Cert renewal nginx reload hook (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
    # Sygen update polling runs inside sygen-updater.service (systemd unit
    # we installed in stage 6). It polls GitHub Releases and atomically
    # swaps the venv + admin tarball when an apply is requested.
    #
    # certbot's Debian/Ubuntu package installs certbot.timer (runs twice
    # daily), so cert renewals happen on their own. We just need nginx to
    # reload and pick up the new chain after a successful renew.
    log "Installing cert-renewal nginx reload hook"
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
fi

# ---------- 9b. Cert renewal launchd agent (macOS publicdomain) ----------
# brew certbot ships no timer / launchd agent of its own. macOS in
# publicdomain mode would otherwise serve a stale cert after 90 days
# (LE certs expire) until the operator manually re-runs the installer.
# Install a per-user LaunchAgent that runs `certbot renew` daily at 03:00.
if [ $LOCAL_MODE -eq 1 ] && [ "$SELF_HOSTED_SUBMODE" = "publicdomain" ]; then
    STAGE="cert-renew"
    log "Installing cert-renewal LaunchAgent (daily at 03:00)"

    RENEW_SCRIPT="$SYGEN_ROOT/bin/sygen-cert-renew.sh"
    mkdir -p "$SYGEN_ROOT/bin" "$SYGEN_ROOT/logs"
    cat > "$RENEW_SCRIPT" <<RENEW
#!/usr/bin/env bash
# Sygen cert-renewal driver — invoked by com.sygen.cert-renew.plist.
# Renews via certbot (manual hooks for the Worker DNS-01 flow) and
# reloads brew nginx on success. Idempotent: certbot is a no-op when
# the cert is far from expiry.
set -euo pipefail

LOG="$SYGEN_ROOT/logs/cert-renew.log"
exec >>"\$LOG" 2>&1
echo "--- \$(date -u +%Y-%m-%dT%H:%M:%SZ) starting renewal ---"

# Renew first; if certbot succeeds the cert is on disk regardless of
# whether nginx reload works. nginx -s reload needs root (master pid
# is owned by root from `sudo nginx`); -n keeps sudo from prompting in
# the no-TTY launchd context — it'll exit 1 instead of hanging. If that
# fails, the operator must manually `sudo nginx -s reload` after seeing
# the next-day log entry, but the renewed cert won't be served until
# they do. This is an explicit trade-off vs. wiring up passwordless
# sudo in /etc/sudoers.d/, which is a heavier operator commitment.
"$CERTBOT_BIN" renew \\
    --config-dir "$CERTBOT_CONFIG_DIR" \\
    --work-dir "${CERTBOT_CONFIG_DIR}-work" \\
    --logs-dir "${CERTBOT_CONFIG_DIR}-logs" \\
    --manual-auth-hook    "$ACME_HOOK_DIR/sygen-acme-auth-hook.sh" \\
    --manual-cleanup-hook "$ACME_HOOK_DIR/sygen-acme-cleanup-hook.sh" \\
    --non-interactive
rc=\$?

if [ \$rc -eq 0 ]; then
    if /usr/bin/sudo -n $(brew --prefix nginx 2>/dev/null || brew --prefix)/bin/nginx -s reload 2>/dev/null; then
        echo "nginx reloaded"
    else
        echo "WARN: certbot renewed but nginx reload requires manual 'sudo nginx -s reload'"
    fi
fi
exit \$rc
RENEW
    chmod 0755 "$RENEW_SCRIPT"

    PLIST_DST="$HOME/Library/LaunchAgents/com.sygen.cert-renew.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>           <string>com.sygen.cert-renew</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$RENEW_SCRIPT</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>   <integer>3</integer>
        <key>Minute</key> <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>  <string>$SYGEN_ROOT/logs/cert-renew.stdout.log</string>
    <key>StandardErrorPath</key><string>$SYGEN_ROOT/logs/cert-renew.stderr.log</string>
    <key>RunAtLoad</key>        <false/>
</dict>
</plist>
PLIST
    chmod 0644 "$PLIST_DST"

    launchctl unload "$PLIST_DST" >/dev/null 2>&1 || true
    launchctl load -w "$PLIST_DST" \
        || warn "launchctl load failed — cert will need manual renewal every 90 days"
    manifest_record_plist "com.sygen.cert-renew"
fi

# ---------- 9c. Auto-start on host reboot ----------
# Native services installed in stage 6 ("services") are already wired for
# autostart: macOS LaunchAgents have RunAtLoad+KeepAlive, systemd units
# have WantedBy=multi-user.target. No additional work needed.
log "Auto-start: services already enabled (sygen-core/admin/updater)"

# ---------- 10. Nightly backups (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
    log "Installing nightly backup timer (/var/backups/sygen, 7-day retention)"

    cat > /usr/local/sbin/sygen-backup.sh <<'BACKUP'
#!/usr/bin/env bash
# Sygen nightly backup — managed by install.sh (Phase 2.8).
# Snapshots /srv/sygen/{data,.env,claude-auth} into
# /var/backups/sygen/sygen-YYYY-MM-DD.tar.gz and prunes archives >7d old.
# venv/ and admin/ are NOT backed up — they're reproducible from
# install.sh given the version pins in .env.
set -euo pipefail

SRC=/srv/sygen
DEST=/var/backups/sygen

if [ ! -d "$SRC/data" ]; then
    echo "sygen-backup: $SRC/data missing — refusing to back up" >&2
    exit 1
fi

mkdir -p "$DEST"
chmod 0700 "$DEST"
STAMP=$(date -u +%Y-%m-%d)
OUT="$DEST/sygen-${STAMP}.tar.gz"

tar -czf "$OUT" -C "$SRC" data .env claude-auth 2>/dev/null || true

# Archive contains api token, jwt secret, and Claude OAuth creds.
chmod 600 "$OUT"

find "$DEST" -maxdepth 1 -name 'sygen-*.tar.gz' -type f -mtime +7 -delete
BACKUP
    chmod 0755 /usr/local/sbin/sygen-backup.sh

    cat > /etc/systemd/system/sygen-backup.service <<'UNIT'
[Unit]
Description=Sygen nightly backup

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sygen-backup.sh
UNIT

    cat > /etc/systemd/system/sygen-backup.timer <<'UNIT'
[Unit]
Description=Run sygen-backup daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable --now sygen-backup.timer
    # Take the first snapshot now so a fresh install ships with one backup.
    systemctl start --no-block sygen-backup.service
fi

# ---------- 11. Done ----------
STAGE="done"

# Write the install manifest. SYGEN_ROOT path is the canonical copy used
# by uninstall.sh; the host_updates copy is mirrored from the canonical
# one (single source of truth) so the /api/system/uninstall/preview
# endpoint and uninstall.sh can never disagree on what was recorded.
# manifest_write_all is also wired into the on_exit trap above so a
# partial install still leaves a manifest behind.
manifest_write_all \
    || warn "could not write install manifest — uninstall will fall back to legacy mode"

if [ "$JSON_OUTPUT" = "1" ]; then
    if [ -z "$ADMIN_PASS" ]; then
        if [ $LOCAL_MODE -eq 1 ]; then
            emit_json_error \
                "core did not write initial admin password within 2 min" \
                "see: tail $SYGEN_ROOT/logs/core.log; launchctl list | grep pro.sygen.core"
        else
            emit_json_error \
                "core did not write initial admin password within 2 min" \
                "see: journalctl -u sygen-core -n 100"
        fi
        exit 1
    fi
    JSON_DONE=1
    # install_token is only populated in auto-mode; it's emitted as a JSON
    # null otherwise so the field is always present and parseable. Wizards
    # that need it for follow-up (e.g. iOS storing it alongside provider
    # creds) can rely on the field's presence; otherwise it's harmless.
    if [ -n "$SYGEN_INSTALL_TOKEN" ]; then
        IT_JSON="$(json_escape "$SYGEN_INSTALL_TOKEN")"
    else
        IT_JSON="null"
    fi
    # mode: which install path was taken. Lets the iOS wizard branch on
    # storage/UX without re-deriving from FQDN heuristics. Values match
    # CONTRACT_ios_vps_deploy_wizard.md §16:
    #   auto         — Linux + Worker-provisioned <random>.sygen.pro
    #   custom       — Linux + operator-supplied SYGEN_SUBDOMAIN
    #   localhost    — macOS, http://localhost (Mac-only access)
    #   tailscale    — macOS or Linux, HTTPS via `tailscale serve` (tailnet)
    #   publicdomain — macOS, brew nginx + LE cert (NAT port forward needed)
    if [ "$SELF_HOSTED_SUBMODE" = "tailscale" ]; then
        MODE="tailscale"
    elif [ $LOCAL_MODE -eq 1 ]; then
        MODE="$SELF_HOSTED_SUBMODE"
    elif [ -n "$SYGEN_INSTALL_TOKEN" ]; then
        MODE="auto"
    else
        MODE="custom"
    fi
    printf '{"ok":true,"mode":%s,"install_mode":"native","fqdn":%s,"admin_user":"admin","admin_password":%s,"admin_url":%s,"core_version":%s,"admin_version":%s,"data_dir":%s,"venv_dir":%s,"admin_dir":%s,"install_token":%s}\n' \
        "$(json_escape "$MODE")" \
        "$(json_escape "$FQDN")" \
        "$(json_escape "$ADMIN_PASS")" \
        "$(json_escape "$ADMIN_URL")" \
        "$(json_escape "$EFFECTIVE_CORE_VERSION")" \
        "$(json_escape "$EFFECTIVE_ADMIN_VERSION")" \
        "$(json_escape "$SYGEN_ROOT/data")" \
        "$(json_escape "$VENV_DIR")" \
        "$(json_escape "$ADMIN_DIR")" \
        "$IT_JSON"
    exit 0
fi

cat <<DONE

=====================================================================
 Sygen is up at: $ADMIN_URL
---------------------------------------------------------------------
  Admin user: admin
DONE

if [ -n "$ADMIN_PASS" ]; then
    echo "  Admin pass: $ADMIN_PASS   (one-time, from $PW_FILE)"
    echo "              delete that file after first login"
else
    warn "  Admin pass: core did not write $PW_FILE within 2 min."
    if [ $LOCAL_MODE -eq 1 ]; then
        warn "              Check: tail $SYGEN_ROOT/logs/core.log"
    else
        warn "              Check: journalctl -u sygen-core -n 100"
    fi
    warn "              Then: cat $PW_FILE"
fi

# iOS deeplink — let users add the server to the Sygen iOS app in one tap.
# QR is printed only when `qrencode` is available; otherwise the link alone.
SYGEN_IOS_DEEPLINK="sygen://add?host=$FQDN"
cat <<DONE
---------------------------------------------------------------------
  iOS app — open this link on iPhone (or scan the QR below) to add this server:
    $SYGEN_IOS_DEEPLINK
DONE
if command -v qrencode >/dev/null 2>&1; then
    echo
    qrencode -t UTF8 "$SYGEN_IOS_DEEPLINK" 2>/dev/null || true
fi

cat <<DONE

  Core:        sygen $EFFECTIVE_CORE_VERSION  ($VENV_DIR/bin/sygen)
  Admin:       sygen-admin $EFFECTIVE_ADMIN_VERSION  ($ADMIN_DIR/server.js)
  Data dir:    $SYGEN_ROOT/data
  Env file:    $SYGEN_ROOT/.env
DONE

if [ $LOCAL_MODE -eq 0 ]; then
    cat <<DONE
  Backups:     /var/backups/sygen/sygen-*.tar.gz  (daily, 7-day retention)
  Auto-start:  enabled — systemd units start core/admin/updater on every boot
               Disable: systemctl disable --now sygen-core sygen-admin sygen-updater

  Status:      systemctl status sygen-core sygen-admin sygen-updater
  Logs:        journalctl -u sygen-core -f
  Restart:     systemctl restart sygen-core sygen-admin
  Upgrade:     POST to the updater's /apply endpoint via the admin UI
               (or manually: $VENV_PIP install --upgrade sygen==<new>)
DONE
else
    cat <<DONE
  Mode:        macOS / $SELF_HOSTED_SUBMODE
  Backups:     not configured on macOS (manual tar of $SYGEN_ROOT)

  Auto-start:  enabled — LaunchAgents pro.sygen.{core,admin,updater} start
               at login and stay running (KeepAlive=true).
               Disable: launchctl unload ~/Library/LaunchAgents/pro.sygen.{core,admin,updater}.plist

  Status:      launchctl list | grep pro.sygen
  Logs:        tail -F $SYGEN_ROOT/logs/{core,admin,updater}.log
  Restart:     launchctl kickstart -k gui/\$(id -u)/pro.sygen.core
  Upgrade:     POST to the updater's /apply endpoint via the admin UI
DONE
    case "$SELF_HOSTED_SUBMODE" in
        tailscale)
            cat <<DONE
  Routes:      sudo tailscale serve status         (show current /api,/ws,/ routes)
               sudo tailscale serve reset          (drop all routes, then re-run install.sh)
  iPhone:      install Tailscale (App Store) and join the same tailnet,
               then open $ADMIN_URL in Safari.
DONE
            ;;
        publicdomain)
            cat <<DONE
  Cert:        /etc/letsencrypt/live/$FQDN/  (renew manually:
               sudo $CERTBOT_BIN renew --manual-auth-hook /usr/local/sbin/sygen-acme-auth-hook.sh \\
                                          --manual-cleanup-hook /usr/local/sbin/sygen-acme-cleanup-hook.sh)
  Nginx:       sudo brew services restart nginx    (after cert renewal)
  IMPORTANT:   iPhone access requires NAT port forwarding 80/443 -> this Mac on your router.
DONE
            ;;
        localhost)
            cat <<DONE
  iPhone:      not reachable from iPhone in this mode (App Transport Security blocks plain HTTP).
               Re-run with SELF_HOSTED_MODE=tailscale or =publicdomain for iPhone access.
DONE
            ;;
    esac
    cat <<DONE
  Uninstall:   curl -fsSL https://install.sygen.pro/uninstall.sh | bash
DONE
fi

cat <<DONE

Claude Code CLI auth
---------------------------------------------------------------------
  Option 1 — API key:   add ANTHROPIC_API_KEY to $SYGEN_ROOT/.env, then
                        restart core (macOS: launchctl kickstart -k
                        gui/\$(id -u)/pro.sygen.core; Linux: systemctl
                        restart sygen-core).
  Option 2 — OAuth:     run \`claude auth login\` once as the install user
                        — creds persist in $SYGEN_ROOT/claude-auth.
=====================================================================
DONE
