#!/usr/bin/env bash
# Hot-deploy whisper.cpp + the ggml-small model onto an existing Sygen
# install without re-running install.sh.
#
# Mirrors the section 5e block in install.sh:
#   - macOS: brew install whisper-cpp
#   - Debian/Ubuntu: apt install whisper-cpp (or whisper.cpp)
#   - downloads ggml-small.bin to the platform's canonical model dir
#
# Usage:
#   curl -fsSL https://install.sygen.pro/scripts/deploy_whisper.sh | bash
# Or:
#   bash deploy_whisper.sh
set -euo pipefail

WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
# SHA-256 of the upstream ggml-small.bin (whisper.cpp release).
# Hardcoded so a corrupted/poisoned download is caught and removed.
WHISPER_MODEL_SHA256="1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"

# Install errors get pinned here so the admin UI can surface "tried and failed"
# vs "never tried" — see core /api/system/voice/config.
ERROR_FILE="$HOME/.local/share/whisper-cpp/.last_install_error"

OS="$(uname -s)"
log() { printf '[deploy-whisper] %s\n' "$*"; }
warn() { printf '[deploy-whisper] WARN: %s\n' "$*" >&2; }
die() {
    record_error "$*"
    printf '[deploy-whisper] ERROR: %s\n' "$*" >&2
    exit 1
}
record_error() {
    mkdir -p "$(dirname "$ERROR_FILE")" 2>/dev/null || true
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
        > "$ERROR_FILE" 2>/dev/null || true
}
clear_error() {
    rm -f "$ERROR_FILE" 2>/dev/null || true
}

# whisper-cpp model files always live in the per-user XDG data dir on
# both macOS and Linux — that's where transcription.py reads them from.
MODEL_DIR="$HOME/.local/share/whisper-cpp/models"

if [ "$OS" = "Darwin" ]; then
    if ! command -v brew >/dev/null 2>&1; then
        die "Homebrew not found — install brew first then re-run"
    fi
    if brew list whisper-cpp >/dev/null 2>&1; then
        log "whisper-cpp already installed via brew"
    else
        log "Installing whisper-cpp via brew"
        brew install whisper-cpp \
            || die "brew install whisper-cpp failed"
    fi
elif [ "$OS" = "Linux" ]; then
    APT_OK=0
    if command -v whisper-cli >/dev/null 2>&1 || command -v whisper-cpp >/dev/null 2>&1; then
        log "whisper.cpp already installed"
        APT_OK=1
    elif command -v apt-get >/dev/null 2>&1; then
        log "Installing whisper.cpp via apt"
        if sudo apt-get update -qq \
            && (sudo apt-get install -y -qq whisper-cpp 2>/dev/null \
                || sudo apt-get install -y -qq whisper.cpp 2>/dev/null); then
            log "whisper.cpp installed via apt"
            APT_OK=1
        else
            warn "whisper.cpp not available via apt on this release — install manually"
        fi
    else
        warn "Unsupported Linux package manager — install whisper.cpp manually"
    fi
    # Skip the 466 MB download on Linux when the binary isn't on PATH —
    # otherwise we'd ship a model the runtime can't use.
    if [ "$APT_OK" -ne 1 ]; then
        record_error "whisper.cpp binary missing — skipped model download"
        warn "Skipping model download — install whisper.cpp first, then re-run"
        exit 0
    fi
else
    die "Unsupported OS: $OS"
fi

MODEL_PATH="$MODEL_DIR/ggml-small.bin"
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_PATH" ]; then
    log "ggml-small model already present at $MODEL_PATH"
    clear_error
else
    log "Downloading whisper.cpp model (~466 MB, 2-5 min on broadband)…"
    log "→ $MODEL_PATH"
    if curl -fL --progress-bar -o "$MODEL_PATH.tmp" "$WHISPER_MODEL_URL"; then
        if [ "$OS" = "Darwin" ]; then
            ACTUAL_SHA="$(shasum -a 256 "$MODEL_PATH.tmp" 2>/dev/null | awk '{print $1}')"
        else
            ACTUAL_SHA="$(sha256sum "$MODEL_PATH.tmp" 2>/dev/null | awk '{print $1}')"
        fi
        if [ "$ACTUAL_SHA" != "$WHISPER_MODEL_SHA256" ]; then
            rm -f "$MODEL_PATH.tmp" 2>/dev/null || true
            die "SHA-256 mismatch (expected $WHISPER_MODEL_SHA256, got ${ACTUAL_SHA:-<unreadable>}) — file deleted"
        fi
        mv "$MODEL_PATH.tmp" "$MODEL_PATH"
        log "Model downloaded and verified"
        clear_error
    else
        rm -f "$MODEL_PATH.tmp" 2>/dev/null || true
        die "model download failed — re-run: curl -fL -o $MODEL_PATH $WHISPER_MODEL_URL"
    fi
fi

log "Done. Voice transcription is ready — verify in admin Settings → Voice."
