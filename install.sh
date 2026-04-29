#!/usr/bin/env bash
# Sygen install script — Docker + (Linux: nginx + Let's Encrypt / macOS: Colima + localhost/Tailscale/public domain).
#
# Linux  (Debian 12+/Ubuntu 22+ VPS): apt, systemd, public DNS via Cloudflare,
#        nginx vhost + cert via certbot DNS-01.
# macOS  (Darwin): Homebrew-installed Colima as a headless Docker runtime.
#        Three sub-modes (selected via SELF_HOSTED_MODE):
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
#   ANTHROPIC_API_KEY         injected into core container as env var
#   SYGEN_INSTALL_BASE_URL    default: https://install.sygen.pro
#                             (source of docker-compose.yml + nginx.conf.tmpl)
#   SYGEN_CORE_IMAGE          pin a specific core image tag
#   SYGEN_ADMIN_IMAGE         pin a specific admin image tag
#   SYGEN_CORE_TAG            default: latest (used when *_IMAGE unset)
#   SYGEN_ADMIN_TAG           default: latest
#   SYGEN_ADMIN_PORT          (macOS) host port for admin, default 8080
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
# The admin panel bootstraps its own "admin" user on first boot and writes the
# one-time password to $SYGEN_ROOT/data/_secrets/.initial_admin_password. The
# installer prints it at the end. $SYGEN_ROOT is /srv/sygen on Linux and
# $HOME/.sygen-local on macOS.
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
on_exit() {
    local code=$?
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
# fetches the current docker-compose.yml + nginx.conf.tmpl. The GitHub
# Pages CDN at install.sygen.pro caches for ~10 min, which causes
# operators to silently install yesterday's compose file. Override
# SYGEN_INSTALL_BASE_URL when testing a fork.
BASE_URL="${SYGEN_INSTALL_BASE_URL:-https://raw.githubusercontent.com/alexeymorozua/sygen-install/main}"
CORE_TAG="${SYGEN_CORE_TAG:-latest}"
ADMIN_TAG="${SYGEN_ADMIN_TAG:-latest}"
CORE_IMAGE="${SYGEN_CORE_IMAGE:-ghcr.io/alexeymorozua/sygen-core:${CORE_TAG}}"
ADMIN_IMAGE="${SYGEN_ADMIN_IMAGE:-ghcr.io/alexeymorozua/sygen-admin:${ADMIN_TAG}}"

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

# ---------- 1. System packages ----------
STAGE="deps"
if [ $LOCAL_MODE -eq 0 ]; then
    log "Installing system packages"
    export DEBIAN_FRONTEND=noninteractive
    apt_retry update -qq
    # Base packages always needed. nginx + certbot ONLY for paths that
    # terminate TLS themselves (auto-mode + custom-mode). Tailscale-mode
    # delegates TLS to `tailscale serve` so nginx + certbot are skipped.
    # openssl: not in Debian-slim minimal images by default; we need
    # `openssl rand -hex 32` later to generate API + JWT secrets.
    if [ "$SELF_HOSTED_SUBMODE" = "tailscale" ]; then
        apt_retry install -y -qq ca-certificates curl jq gnupg openssl
    else
        apt_retry install -y -qq \
            ca-certificates curl jq gnupg openssl nginx \
            certbot python3-certbot-dns-cloudflare
    fi

    # Docker (official convenience script, idempotent).
    if ! command -v docker >/dev/null 2>&1; then
        log "Installing Docker via get.docker.com"
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker

    # docker compose v2 plugin is bundled with docker-ce on Debian/Ubuntu; verify.
    if ! docker compose version >/dev/null 2>&1; then
        die "docker compose plugin missing — install manually and re-run"
    fi
else
    # ---------- 1-macos. Brew deps + Colima ----------
    log "macOS: checking Homebrew"
    if ! command -v brew >/dev/null 2>&1; then
        die "Homebrew required on macOS. Install from https://brew.sh then re-run."
    fi

    log "macOS: installing Colima + docker CLI + jq (if missing)"
    # jq is needed by the same code paths as on Linux (provision response
    # parsing, .env edits) — install once up front so later sections can
    # rely on it. nginx+certbot are publicdomain-only — adding them to a
    # plain localhost install would be wasteful churn.
    macos_pkgs=(colima docker docker-compose jq)
    if [ "$SELF_HOSTED_SUBMODE" = "publicdomain" ]; then
        # certbot deliberately NOT in this list — installing it via brew
        # pulls cryptography/cffi/pycparser as Python deps, and on a Mac
        # that already has a different version of those packages from a
        # prior `pip install` (e.g. a developer running other Python
        # projects in the brew prefix), brew's link step fails or the
        # imports go to the wrong site-packages. We isolate certbot via
        # pipx below — its own venv, zero conflicts with system pip.
        macos_pkgs+=(nginx pipx)
    fi
    for pkg in "${macos_pkgs[@]}"; do
        if ! brew list "$pkg" >/dev/null 2>&1; then
            brew install "$pkg"
        fi
    done

    # certbot in an isolated pipx venv — first run creates it, re-runs are
    # a no-op via `pipx list | grep`. inject pulls in the manual-DNS
    # plugin we use for Worker-mediated DNS-01 (no provider key needed
    # at install time; the auth-hook script POSTs to install.sygen.pro).
    if [ "$SELF_HOSTED_SUBMODE" = "publicdomain" ]; then
        # pipx ensures its bin dir (~/.local/bin) is on PATH for THIS shell,
        # so the certbot-bin resolution below sees it without re-login.
        pipx ensurepath >/dev/null 2>&1 || true
        export PATH="$HOME/.local/bin:$PATH"
        if ! pipx list 2>/dev/null | grep -q "package certbot "; then
            log "macOS: installing certbot in isolated pipx venv"
            pipx install certbot >/dev/null \
                || die "pipx install certbot failed — see error above"
        fi
        # Custom-mode juser provides their own CF token and we use the
        # dns-cloudflare plugin; auto-mode goes through Worker-mediated
        # manual hooks and doesn't need a plugin. Inject the plugin into
        # the same venv so certbot can find it. Idempotent — pipx no-ops
        # if the package is already injected.
        if [ -n "${CF_API_TOKEN:-}" ]; then
            pipx inject certbot certbot-dns-cloudflare >/dev/null 2>&1 \
                || warn "pipx inject certbot-dns-cloudflare failed — custom-mode cert may fail"
        fi
    fi

    # Homebrew installs the docker-compose binary into
    # $(brew --prefix)/lib/docker/cli-plugins/, but Docker CLI only autodiscovers
    # plugins from ~/.docker/cli-plugins/ or /usr/local/lib/docker/cli-plugins/.
    # Without this symlink, `docker compose <verb>` fails with "unknown command"
    # immediately after a fresh brew install, which used to make the next
    # `docker compose version` check kill the install. Idempotent — `ln -sf`
    # is fine on re-runs.
    BREW_COMPOSE_PLUGIN="$(brew --prefix 2>/dev/null)/lib/docker/cli-plugins/docker-compose"
    if [ -x "$BREW_COMPOSE_PLUGIN" ]; then
        mkdir -p "$HOME/.docker/cli-plugins"
        ln -sf "$BREW_COMPOSE_PLUGIN" "$HOME/.docker/cli-plugins/docker-compose"
    fi

    # Detect host CPU/RAM/disk so Colima can size itself to the box and
    # so the core agent can report host-true metrics on the dashboard
    # (psutil inside a container otherwise reports VM resources, e.g.
    # "4 cores · aarch64 · 8 GB" on an M4 with 32 GB).
    HOST_CPU="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    HOST_RAM_BYTES="$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0)"
    HOST_RAM_GB=$(( HOST_RAM_BYTES / 1024 / 1024 / 1024 ))
    HOST_CPU_MODEL="$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    # df -k returns 1024-byte blocks; convert to bytes via *1024.
    HOST_DISK_TOTAL_KB="$(df -k / 2>/dev/null | awk 'NR==2 {print $2}')"
    HOST_DISK_TOTAL_BYTES=$(( ${HOST_DISK_TOTAL_KB:-0} * 1024 ))
    HOST_DISK_TOTAL_GB=$(( HOST_DISK_TOTAL_BYTES / 1024 / 1024 / 1024 ))

    # Colima sizing — give the VM ~85% of host RAM (operator wants "all
    # resources"; we leave a small reserve so macOS itself doesn't swap)
    # and a generous disk cap that's bounded by what the host actually
    # has free. Falls back to install.sh's old defaults on detection
    # failure so a weird host doesn't brick the install.
    COLIMA_CPU="${HOST_CPU}"
    if [ "$HOST_RAM_GB" -gt 0 ]; then
        COLIMA_RAM=$(( HOST_RAM_GB * 85 / 100 ))
        [ "$COLIMA_RAM" -lt 4 ] && COLIMA_RAM=4
    else
        COLIMA_RAM=8
    fi
    if [ "$HOST_DISK_TOTAL_GB" -gt 0 ]; then
        # Cap at half the host disk so we don't fill the SSD; minimum 50 GB.
        COLIMA_DISK=$(( HOST_DISK_TOTAL_GB / 2 ))
        [ "$COLIMA_DISK" -lt 50 ] && COLIMA_DISK=50
        [ "$COLIMA_DISK" -gt 500 ] && COLIMA_DISK=500
    else
        COLIMA_DISK=50
    fi

    # Apple Silicon + macOS Ventura (13) or newer → use Apple's Virtualization
    # framework instead of Colima's qemu default. Reasons:
    #   - qemu has known startup failures on macOS 15.0–15.3 (Sequoia) that
    #     surface as "VM did not start" with no clear remediation.
    #   - vz boots ~5× faster and gets virtiofs for the host bind mounts,
    #     which is significantly snappier than qemu's 9p shares.
    # Intel macs / older macOS keep qemu (vz isn't available there).
    COLIMA_EXTRA_ARGS=()
    if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
        macos_major="$(/usr/bin/sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo 0)"
        if [ "${macos_major:-0}" -ge 13 ]; then
            COLIMA_EXTRA_ARGS+=(--vm-type=vz --mount-type=virtiofs)
        fi
    fi

    if ! colima status >/dev/null 2>&1; then
        log "macOS: starting Colima (${COLIMA_CPU} CPU / ${COLIMA_RAM} GB RAM / ${COLIMA_DISK} GB disk; host: ${HOST_CPU_MODEL}, ${HOST_RAM_GB} GB, ${HOST_DISK_TOTAL_GB} GB)"
        colima start --cpu "$COLIMA_CPU" --memory "$COLIMA_RAM" --disk "$COLIMA_DISK" "${COLIMA_EXTRA_ARGS[@]}"
    else
        log "macOS: Colima already running"
    fi

    # Persist host-true metrics in .env so docker-compose can pass them
    # to sygen-core as env vars. Core's _get_cpu_count/_get_cpu_model/
    # _get_*_bytes helpers prefer the SYGEN_HOST_* env vars over psutil
    # so the dashboard shows "Apple M4 · 10 cores · 32 GB" (host) instead
    # of "aarch64 · 10 cores · 27 GB" (VM after the colima sizing above).
    {
        printf 'SYGEN_HOST_CPU_COUNT=%s\n' "$HOST_CPU"
        printf 'SYGEN_HOST_CPU_MODEL=%s\n' "$HOST_CPU_MODEL"
        printf 'SYGEN_HOST_RAM_TOTAL_BYTES=%s\n' "$HOST_RAM_BYTES"
        printf 'SYGEN_HOST_DISK_TOTAL_BYTES=%s\n' "$HOST_DISK_TOTAL_BYTES"
    } > /tmp/sygen-host-metrics.env

    if ! docker compose version >/dev/null 2>&1; then
        die "docker compose plugin missing after brew install — try: ln -sf $(brew --prefix)/lib/docker/cli-plugins/docker-compose ~/.docker/cli-plugins/docker-compose"
    fi
fi

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

# Container runs as uid 1000 (sygen) — see core Dockerfile. Bind-mounted
# host directories don't inherit the chown done inside the image, so without
# this the container can't create /data/logs etc and crashes on first start
# with PermissionError. Linux only — macOS Colima maps host user uid into
# the VM transparently. `find ... -exec chown` with the default action does
# not follow symlinks (POSIX find traverses without dereferencing for -exec
# by default); we also pass `-h` to chown so even a symlink whose target is
# outside the tree only has its own metadata changed, never the target's.
if [ $LOCAL_MODE -eq 0 ]; then
    find "$SYGEN_ROOT/data" "$SYGEN_ROOT/claude-auth" \
        -xdev -exec chown -h 1000:1000 {} +
fi

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

# Image refs: env var > existing .env > computed default. Lets an operator
# pin a tag in .env (or via SYGEN_*_IMAGE) and have it survive re-runs.
EFFECTIVE_CORE_IMAGE=$(get_env SYGEN_CORE_IMAGE "$CORE_IMAGE")
EFFECTIVE_ADMIN_IMAGE=$(get_env SYGEN_ADMIN_IMAGE "$ADMIN_IMAGE")
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

# docker-compose .env is auto-sourced by `docker compose`.
umask 077
{
    echo "SYGEN_CORE_IMAGE=$EFFECTIVE_CORE_IMAGE"
    echo "SYGEN_ADMIN_IMAGE=$EFFECTIVE_ADMIN_IMAGE"
    echo "ANTHROPIC_API_KEY=$EFFECTIVE_ANTHROPIC_KEY"
    echo "CLAUDE_CODE_OAUTH_TOKEN=$EFFECTIVE_OAUTH_TOKEN"
    echo "LOG_LEVEL=$EFFECTIVE_LOG_LEVEL"
    # Shared secret for core ↔ updater-sidecar apply calls. Core authenticates
    # its POST to http://sygen-updater:8082/apply with this bearer token.
    echo "SYGEN_UPDATER_TOKEN=$EFFECTIVE_UPDATER_TOKEN"
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
    # macOS: pass host CPU/RAM/disk metadata into core so the dashboard
    # reports host-true values instead of Colima VM resources. File was
    # generated up in the Colima section. No-op on Linux (file absent
    # because that branch never runs).
    if [ -f /tmp/sygen-host-metrics.env ]; then
        cat /tmp/sygen-host-metrics.env
    fi
} > "$SYGEN_ROOT/.env"
umask 022
chmod 600 "$SYGEN_ROOT/.env"

# ---------- 5. docker-compose.yml ----------
STAGE="compose"
log "Fetching docker-compose.yml from $BASE_URL"
curl -fsSL -o "$SYGEN_ROOT/docker-compose.yml" "$BASE_URL/docker-compose.yml" \
    || die "could not fetch docker-compose.yml"

if [ $LOCAL_MODE -eq 1 ]; then
    # Rewrite hardcoded /srv/sygen paths to $SYGEN_ROOT (user-writable, no sudo)
    # and remap the admin container's host port from 3000 to $SYGEN_ADMIN_PORT
    # so it doesn't collide with typical local dev servers.
    # `sed -i.bak` is the portable form that works on BSD (macOS) and GNU sed.
    sed -i.bak \
        -e "s|/srv/sygen|$SYGEN_ROOT|g" \
        -e "s|127.0.0.1:3000:3000|127.0.0.1:${SYGEN_ADMIN_PORT}:3000|g" \
        "$SYGEN_ROOT/docker-compose.yml"
    rm -f "$SYGEN_ROOT/docker-compose.yml.bak"
elif [ "$SELF_HOSTED_SUBMODE" = "tailscale" ]; then
    # Linux+tailscale: no nginx, admin reached via `tailscale serve` →
    # localhost:$SYGEN_ADMIN_PORT. Same port remap as macOS so the
    # tailscale serve mountpoint matches.
    sed -i.bak \
        -e "s|127.0.0.1:3000:3000|127.0.0.1:${SYGEN_ADMIN_PORT}:3000|g" \
        "$SYGEN_ROOT/docker-compose.yml"
    rm -f "$SYGEN_ROOT/docker-compose.yml.bak"
fi

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

PYTHON_BIN="$(command -v python3 || true)"
[ -z "$PYTHON_BIN" ] && die "python3 not found — required for host_metrics_daemon"

if [ $LOCAL_MODE -eq 1 ]; then
    # macOS — launchd LaunchAgent (per-user, runs in user session).
    PLIST_DST="$HOME/Library/LaunchAgents/com.sygen.host-metrics.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    curl -fsSL -o /tmp/sygen.host-metrics.plist.tmpl \
        "$BASE_URL/scripts/com.sygen.host-metrics.plist" \
        || die "could not fetch com.sygen.host-metrics.plist"
    sed \
        -e "s|__PYTHON__|$PYTHON_BIN|g" \
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
        || warn "launchctl load failed — host metrics will fall back to Colima view"
else
    # Linux — systemd unit, system-wide.
    UNIT_DST="/etc/systemd/system/sygen-host-metrics.service"
    curl -fsSL -o /tmp/sygen-host-metrics.service.tmpl \
        "$BASE_URL/scripts/sygen-host-metrics.service" \
        || die "could not fetch sygen-host-metrics.service"
    sed \
        -e "s|__PYTHON__|$PYTHON_BIN|g" \
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
    }
    install_host_update_plist "com.sygen.host-updates-check" \
        "$SYGEN_ROOT/bin/host_updates_check.sh"
    install_host_update_plist "com.sygen.host-update-runner" \
        "$SYGEN_ROOT/bin/host_update_runner.sh"
fi

# ---------- 6. Start stack ----------
log "Pulling images"
docker compose -f "$SYGEN_ROOT/docker-compose.yml" --env-file "$SYGEN_ROOT/.env" pull

log "Starting Sygen stack"
# --remove-orphans removes containers from prior compose files that are no
# longer in this one (notably the legacy `sygen-watchtower` service that
# was removed in compose v2 — without this flag, watchtower keeps polling
# and fights with sygen-updater, surfacing as mysterious "image rolled
# back" loops).
docker compose -f "$SYGEN_ROOT/docker-compose.yml" --env-file "$SYGEN_ROOT/.env" up -d --remove-orphans

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
        warn "Check: 'colima status' and 'docker compose -f $SYGEN_ROOT/docker-compose.yml logs'"
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
    BREW_NGINX_PREFIX="$(brew --prefix nginx 2>/dev/null || brew --prefix)"
    NGINX_CONF_DIR="$BREW_NGINX_PREFIX/etc/nginx/servers"
    if [ ! -d "$NGINX_CONF_DIR" ]; then
        # Older brew layouts put the conf dir under the toplevel brew prefix.
        NGINX_CONF_DIR="$(brew --prefix)/etc/nginx/servers"
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
        local exe
        exe=$(/bin/ps -o args= -p "$master_pid" 2>/dev/null | awk '{print $3}' || true)
        # Older `ps` formats put the binary as $1; check both. lsof is the
        # belt-and-braces alternative.
        if [ -z "$exe" ] || [ ! -e "$exe" ]; then
            exe=$(/bin/ps -o args= -p "$master_pid" 2>/dev/null | awk '{print $1}' || true)
        fi
        case "$exe" in
            "$BREW_NGINX_PREFIX/"*|"$(brew --prefix)/"*) return 0 ;;
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

# ---------- 9. Auto-updates & cert renewal (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
    # Container image auto-updates run inside the stack via the Watchtower
    # service defined in docker-compose.yml — it polls GHCR hourly and
    # recreates any container labeled com.centurylinklabs.watchtower.enable.
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
fi

# ---------- 10. Nightly backups (Linux only) ----------
if [ $LOCAL_MODE -eq 0 ]; then
    log "Installing nightly backup timer (/var/backups/sygen, 7-day retention)"

    cat > /usr/local/sbin/sygen-backup.sh <<'BACKUP'
#!/usr/bin/env bash
# Sygen nightly backup — managed by install.sh (Phase 2.8).
# Snapshots /srv/sygen/{data,.env,docker-compose.yml,claude-auth} into
# /var/backups/sygen/sygen-YYYY-MM-DD.tar.gz and prunes archives >7d old.
set -euo pipefail

SRC=/srv/sygen
DEST=/var/backups/sygen

if [ ! -d "$SRC/data" ]; then
    echo "sygen-backup: $SRC/data missing — refusing to back up" >&2
    exit 1
fi

mkdir -p "$DEST"
# 0700 on the backup dir: defence-in-depth against regressions where an archive
# later ends up 0644 — the dir itself should never be world-listable since it
# names tarballs that contain .env + claude-auth + _secrets/.
chmod 0700 "$DEST"
STAMP=$(date -u +%Y-%m-%d)
OUT="$DEST/sygen-${STAMP}.tar.gz"

# .env / docker-compose.yml / claude-auth are optional on a partially
# bootstrapped host — don't fail the run if any are missing.
tar -czf "$OUT" -C "$SRC" data .env docker-compose.yml claude-auth 2>/dev/null || true

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

if [ "$JSON_OUTPUT" = "1" ]; then
    if [ -z "$ADMIN_PASS" ]; then
        emit_json_error \
            "core did not write initial admin password within 2 min" \
            "see: docker compose -f $SYGEN_ROOT/docker-compose.yml logs core"
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
    printf '{"ok":true,"mode":%s,"fqdn":%s,"admin_user":"admin","admin_password":%s,"admin_url":%s,"core_image":%s,"admin_image":%s,"data_dir":%s,"compose_file":%s,"install_token":%s}\n' \
        "$(json_escape "$MODE")" \
        "$(json_escape "$FQDN")" \
        "$(json_escape "$ADMIN_PASS")" \
        "$(json_escape "$ADMIN_URL")" \
        "$(json_escape "$CORE_IMAGE")" \
        "$(json_escape "$ADMIN_IMAGE")" \
        "$(json_escape "$SYGEN_ROOT/data")" \
        "$(json_escape "$SYGEN_ROOT/docker-compose.yml")" \
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
    warn "              Check \`docker compose logs core\` and retry:"
    warn "              cat $PW_FILE"
fi

cat <<DONE

  Core image:  $CORE_IMAGE
  Admin image: $ADMIN_IMAGE
  Data dir:    $SYGEN_ROOT/data
  Compose:     $SYGEN_ROOT/docker-compose.yml  (--env-file $SYGEN_ROOT/.env)
DONE

if [ $LOCAL_MODE -eq 0 ]; then
    cat <<DONE
  Backups:     /var/backups/sygen/sygen-*.tar.gz  (daily, 7-day retention)

  Upgrade:     cd $SYGEN_ROOT && docker compose pull && docker compose up -d
  Logs:        docker compose -f $SYGEN_ROOT/docker-compose.yml logs -f core
DONE
else
    cat <<DONE
  Mode:        macOS / $SELF_HOSTED_SUBMODE
  Backups:     not configured on macOS (manual tar of $SYGEN_ROOT)

  Stop:        colima stop
  Start:       colima start && cd $SYGEN_ROOT && docker compose up -d
  Upgrade:     cd $SYGEN_ROOT && docker compose pull && docker compose up -d
  Logs:        docker compose -f $SYGEN_ROOT/docker-compose.yml logs -f core
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
  Option 1 — API key:   add ANTHROPIC_API_KEY to $SYGEN_ROOT/.env and
                        \`docker compose up -d\`.
  Option 2 — OAuth:     \`docker compose -f $SYGEN_ROOT/docker-compose.yml \\
                          exec core claude auth login\`
                        (creds persist in $SYGEN_ROOT/claude-auth).
=====================================================================
DONE
