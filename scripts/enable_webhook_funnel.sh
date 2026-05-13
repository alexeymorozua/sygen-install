#!/bin/sh
# Sygen — enable Tailscale Funnel + /webhooks/ serve rule.
#
# For existing Mac+Tailscale installations who upgraded core to 1.6.171+
# but never re-ran install.sh — webhook endpoint exists in core but
# Tailscale Funnel is not configured to expose it publicly.
#
# Usage:
#   curl -fsSL https://install.sygen.pro/scripts/enable_webhook_funnel.sh | bash
#   curl -fsSL https://install.sygen.pro/scripts/enable_webhook_funnel.sh | bash -s -- --yes
#
# What it does:
#   1. Adds `serve --set-path=/webhooks/` rule (idempotent).
#   2. Enables Funnel for /webhooks/ (with confirmation prompt unless --yes
#      or SYGEN_AUTO_FUNNEL=1).
#
# Exit codes:
#   0  success (funnel enabled or already on)
#   1  Tailscale not installed / not reachable
#   2  user cancelled at confirmation prompt

set -eu

# Locate Tailscale binary — App Store install hides the CLI inside .app.
if command -v tailscale >/dev/null 2>&1; then
    TAILSCALE="$(command -v tailscale)"
elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
    echo "Error: Tailscale CLI not found." >&2
    echo "  Install from https://tailscale.com/download or the Mac App Store first." >&2
    exit 1
fi

# macOS Tailscale.app exposes a user-accessible socket; sudo is harmful there
# (prompts for a password and breaks non-TTY use). Linux apt install runs the
# daemon as root and needs sudo for state-mutating calls.
case "$(uname -s)" in
    Darwin) TAILSCALE_SUDO="" ;;
    *)      TAILSCALE_SUDO="sudo" ;;
esac

PORT="${SYGEN_CORE_PORT:-8081}"

echo "Sygen webhook Funnel enabler"
echo "----------------------------"
echo "Tailscale binary: $TAILSCALE"
echo "Core port:        $PORT"
echo ""

# Step 1: serve rule (idempotent — re-adds if missing, no-op if already present).
echo "[1/2] Adding tailscale serve rule for /webhooks/..."
$TAILSCALE_SUDO "$TAILSCALE" serve --bg --set-path=/webhooks/ "http://127.0.0.1:${PORT}/webhooks/" </dev/null

# Step 2: funnel — confirm unless --yes or SYGEN_AUTO_FUNNEL=1.
if [ "${1:-}" = "--yes" ] || [ "${SYGEN_AUTO_FUNNEL:-}" = "1" ]; then
    confirm="y"
else
    echo ""
    echo "[2/2] Enable Tailscale Funnel for /webhooks/?"
    echo "  Funnel exposes /webhooks/ PUBLICLY via Tailscale infrastructure."
    echo "  Needed for external services (Power Automate, GitHub, Stripe) to"
    echo "  reach your Sygen webhook endpoint from the public internet."
    printf "Enable? [Y/n] "
    read -r confirm </dev/tty 2>/dev/null || confirm="y"
fi

case "${confirm:-y}" in
    n|N|no|No|NO)
        echo ""
        echo "Funnel skipped. Webhook accessible только within tailnet."
        echo "To enable later: re-run this script."
        exit 2
        ;;
    *)
        $TAILSCALE_SUDO "$TAILSCALE" funnel --bg --set-path=/webhooks/ "http://127.0.0.1:${PORT}/webhooks/" </dev/null
        echo ""
        echo "Done. Funnel status:"
        "$TAILSCALE" funnel status </dev/null || true
        echo ""
        echo "Your webhook URL: https://<your-tailnet>.ts.net/webhooks/<slug>"
        echo "Find your tailnet name in the funnel status output above."
        ;;
esac
