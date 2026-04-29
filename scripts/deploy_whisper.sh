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

OS="$(uname -s)"
log() { printf '[deploy-whisper] %s\n' "$*"; }
warn() { printf '[deploy-whisper] WARN: %s\n' "$*" >&2; }
die() { printf '[deploy-whisper] ERROR: %s\n' "$*" >&2; exit 1; }

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
    MODEL_DIR="$HOME/.local/share/whisper-cpp/models"
elif [ "$OS" = "Linux" ]; then
    if command -v whisper-cli >/dev/null 2>&1 || command -v whisper-cpp >/dev/null 2>&1; then
        log "whisper.cpp already installed"
    elif command -v apt-get >/dev/null 2>&1; then
        log "Installing whisper.cpp via apt"
        if sudo apt-get update -qq \
            && (sudo apt-get install -y -qq whisper-cpp 2>/dev/null \
                || sudo apt-get install -y -qq whisper.cpp 2>/dev/null); then
            log "whisper.cpp installed via apt"
        else
            warn "whisper.cpp not available via apt on this release — install manually"
        fi
    else
        warn "Unsupported Linux package manager — install whisper.cpp manually"
    fi
    SYGEN_ROOT="${SYGEN_ROOT:-/srv/sygen}"
    MODEL_DIR="$SYGEN_ROOT/whisper-models"
else
    die "Unsupported OS: $OS"
fi

MODEL_PATH="$MODEL_DIR/ggml-small.bin"
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_PATH" ]; then
    log "ggml-small model already present at $MODEL_PATH"
else
    log "Downloading ggml-small.bin (~466 MB) → $MODEL_PATH"
    if curl -fL --progress-bar -o "$MODEL_PATH.tmp" "$WHISPER_MODEL_URL"; then
        mv "$MODEL_PATH.tmp" "$MODEL_PATH"
        log "Model downloaded"
    else
        rm -f "$MODEL_PATH.tmp" 2>/dev/null || true
        die "model download failed — re-run: curl -fL -o $MODEL_PATH $WHISPER_MODEL_URL"
    fi
fi

log "Done. Voice transcription is ready — verify in admin Settings → Voice."
