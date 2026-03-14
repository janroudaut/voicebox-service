#!/usr/bin/env bash
# ============================================================
# run.sh — Build & run Voicebox TTS service via docker compose
# Automatically selects CPU or GPU mode based on availability.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
PORT="${VOICEBOX_PORT:-17493}"
DEFAULT_MODEL="${VOICEBOX_MODEL:-chatterbox-tts}"

# Colors (respect https://no-color.org/)
if [[ -n "${NO_COLOR:-}" ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR]${NC}   $*" >&2; }

# ── Pre-flight checks ──────────────────────────────────────
info "Checking prerequisites..."

if ! command -v docker &>/dev/null; then
    err "Docker is not installed."; exit 1
fi

if ! docker info &>/dev/null; then
    err "Docker daemon is not running."; exit 1
fi

# ── GPU detection (soft — falls back to CPU) ────────────────
USE_GPU=false
COMPOSE_FILES=(-f docker-compose.yml)

if [[ "${VOICEBOX_DEVICE:-auto}" == "cuda" ]]; then
    USE_GPU=true
elif [[ "${VOICEBOX_DEVICE:-auto}" == "cpu" ]]; then
    USE_GPU=false
else
    # Auto-detect
    if nvidia-smi &>/dev/null; then
        if docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu22.04 nvidia-smi &>/dev/null 2>&1; then
            USE_GPU=true
            ok "NVIDIA GPU detected and accessible from Docker"
        else
            warn "nvidia-smi found but GPU is not accessible from Docker. Falling back to CPU."
            warn "Install nvidia-container-toolkit for GPU support."
        fi
    else
        info "No NVIDIA GPU detected — using CPU mode."
    fi
fi

if $USE_GPU; then
    COMPOSE_FILES+=(-f docker-compose.gpu.yml)
    info "Mode: GPU (CUDA)"
else
    info "Mode: CPU"
fi

# ── Build & start ────────────────────────────────────────────
info "Building and starting Voicebox... this may take a while on first run."
docker compose "${COMPOSE_FILES[@]}" up -d --build

ok "Voicebox container started"

# ── Wait for healthy ────────────────────────────────────────
info "Waiting for server to become healthy (port ${PORT})..."
MAX_WAIT=180
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -sf "http://localhost:${PORT}/health" >/dev/null 2>&1; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    if [ $((WAITED % 10)) -eq 0 ]; then
        info "  ...${WAITED}s elapsed"
    fi
done

if [ $WAITED -ge $MAX_WAIT ]; then
    err "Server did not respond after ${MAX_WAIT}s."
    echo ""
    warn "Last container logs:"
    docker compose "${COMPOSE_FILES[@]}" logs --tail 40 voicebox
    exit 1
fi

ok "Voicebox server is healthy!"

# ── Download default model ────────────────────────────────────
if [ -n "$DEFAULT_MODEL" ]; then
    info "Triggering download of default model '${DEFAULT_MODEL}'..."
    DL_RESP=$(curl -sf -X POST "http://localhost:${PORT}/models/download" \
        -H 'Content-Type: application/json' \
        -d "{\"model_name\":\"${DEFAULT_MODEL}\"}" 2>&1) || true

    if echo "$DL_RESP" | grep -qi "already downloaded"; then
        ok "Model '${DEFAULT_MODEL}' already downloaded"
    elif echo "$DL_RESP" | grep -qi "error"; then
        warn "Model download request failed: ${DL_RESP}"
    else
        ok "Model '${DEFAULT_MODEL}' download started in background"
    fi
fi

# ── Verify GPU inside container ─────────────────────────────
if $USE_GPU; then
    info "Verifying GPU inside container..."
    GPU_CHECK=$(docker compose "${COMPOSE_FILES[@]}" exec voicebox python3 -c \
        "import torch; print(f'CUDA available: {torch.cuda.is_available()}, GPU: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"none\"}')" 2>&1) || true
    echo "  $GPU_CHECK"

    if echo "$GPU_CHECK" | grep -q "CUDA available: True"; then
        ok "GPU successfully detected by PyTorch"
    else
        warn "GPU not detected by PyTorch — server will run on CPU."
    fi
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Voicebox is ready!${NC}"
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo ""
echo -e "  Mode:   $( $USE_GPU && echo "${GREEN}GPU (CUDA)${NC}" || echo "${BLUE}CPU${NC}" )"
echo -e "  Web UI: ${BLUE}http://localhost:${PORT}${NC}"
echo -e "  API:    ${BLUE}http://localhost:${PORT}/docs${NC}"
echo ""
COMPOSE_CMD="docker compose ${COMPOSE_FILES[*]}"
echo -e "  Useful commands:"
echo -e "    ${COMPOSE_CMD} logs -f    # follow logs"
echo -e "    ${COMPOSE_CMD} down       # stop"
echo -e "    ${COMPOSE_CMD} restart    # restart"
echo ""
