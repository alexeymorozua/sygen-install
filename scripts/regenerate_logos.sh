#!/usr/bin/env bash
# Regenerate PNG versions of all SVG logos in providers/logos/.
# Run after adding/replacing any provider SVG so iOS AsyncImage and
# Android Coil/Glide (neither renders SVG natively) keep working.
#
# Usage:
#   bash scripts/regenerate_logos.sh
#
# Requires `rsvg-convert` (librsvg). Install:
#   macOS:  brew install librsvg
#   Debian: apt install librsvg2-bin
#
# Output: 256x256 RGBA PNG with transparent background, one per SVG.
# Skips _default.svg (it's the in-app fallback, never referenced from JSON).
# SVGs are NOT removed — kept for web admin / future vector consumers.

set -e

LOGOS_DIR="$(cd "$(dirname "$0")/.." && pwd)/providers/logos"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "ERROR: rsvg-convert not found." >&2
    echo "  macOS:  brew install librsvg" >&2
    echo "  Debian: apt install librsvg2-bin" >&2
    exit 1
fi

cd "$LOGOS_DIR"
generated=0
skipped=0
for svg in *.svg; do
    base="${svg%.svg}"
    if [ "$base" = "_default" ]; then
        skipped=$((skipped + 1))
        continue
    fi
    rsvg-convert -w 256 -h 256 -o "${base}.png" "$svg"
    generated=$((generated + 1))
done

echo "Generated $generated PNG (skipped $skipped, kept all SVGs)."
echo ""
echo "Next steps:"
echo "  1. Inspect a few PNGs in Preview (transparent bg, brand colors OK?)"
echo "  2. git add providers/logos/*.png providers.json  # if you also bumped logo_url"
echo "  3. git commit + push"
