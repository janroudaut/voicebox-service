#!/usr/bin/env bash
# ============================================================
# run.sh — Build & run Voicebox TTS service via docker compose
# Automatically selects CPU or GPU mode based on availability.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
PORT="${VOICEBOX_PORT:-17493}"
DEFAULT_TTS_MODEL="${VOICEBOX_TTS_MODEL:-qwen-tts-1.7B}"
DEFAULT_STT_MODEL="${VOICEBOX_STT_MODEL:-whisper-turbo}"

# Parse --no-color flag
for arg in "$@"; do
    case "$arg" in
        --no-color|--no-colors) NO_COLOR=1 ;;
        --enable-flash-attn) export FLASH_ATTN=1 ;;
    esac
done

# Disable colors when NO_COLOR is set (https://no-color.org/) or stdout is not a terminal
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
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

# ── Flash-attn handling ──────────────────────────────────────
if [[ "${FLASH_ATTN:-0}" == "1" ]]; then
    if ! $USE_GPU; then
        info "flash-attn requested — forcing GPU (CUDA) mode."
        USE_GPU=true
        COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.gpu.yml)
    fi
    warn "flash-attn enabled — first build will take ~15-20 min to compile CUDA kernels."
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

# ── Download default models ───────────────────────────────────
download_model() {
    local model_name="$1"
    if [ -z "$model_name" ]; then return; fi

    # Check if model is already downloaded and loaded via /models/status
    local status
    status=$(curl -sf "http://localhost:${PORT}/models/status" 2>/dev/null) || true
    if echo "$status" | grep -q "\"model_name\":\"${model_name}\".*\"loaded\":true"; then
        ok "Model '${model_name}' already loaded"
        return 0
    fi

    info "Downloading/loading '${model_name}'..."
    local resp
    resp=$(curl -sf -X POST "http://localhost:${PORT}/models/download" \
        -H 'Content-Type: application/json' \
        -d "{\"model_name\":\"${model_name}\"}" 2>&1) || true

    if echo "$resp" | grep -qi "error"; then
        warn "Model request failed: ${resp}"
        return 1
    else
        ok "Model '${model_name}' loading started"
        return 0
    fi
}

wait_for_model() {
    local model_name="$1"
    local max_wait="${2:-300}"
    local waited=0
    info "Waiting for '${model_name}' to be ready..."
    while [ $waited -lt $max_wait ]; do
        local status
        status=$(curl -sf "http://localhost:${PORT}/models/status" 2>/dev/null) || true
        if echo "$status" | grep -q "\"model_name\":\"${model_name}\".*\"loaded\":true"; then
            ok "Model '${model_name}' is ready"
            return 0
        fi
        if echo "$status" | grep -q "\"model_name\":\"${model_name}\".*\"error\""; then
            warn "Model '${model_name}' failed to load"
            return 1
        fi
        sleep 3
        waited=$((waited + 3))
    done
    warn "Timed out waiting for '${model_name}'"
    return 1
}

if [ -n "$DEFAULT_STT_MODEL" ]; then
    if [[ "$DEFAULT_STT_MODEL" == whisper-* && "$DEFAULT_STT_MODEL" != "whisper-base" ]]; then
        download_model "whisper-base"
        wait_for_model "whisper-base" 120
    fi
    download_model "$DEFAULT_STT_MODEL"
fi
if [ -n "$DEFAULT_TTS_MODEL" ]; then
    download_model "$DEFAULT_TTS_MODEL"
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
COMPOSE_CMD="docker compose ${COMPOSE_FILES[*]}"

echo ""
if [[ -n "$NC" ]]; then
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Voicebox is ready!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
else
    echo "Voicebox is ready!"
fi
echo ""
echo -e "  Mode:   $( $USE_GPU && echo "${GREEN}GPU (CUDA)${NC}" || echo "${BLUE}CPU${NC}" )"
echo -e "  Web UI: ${BLUE}http://localhost:${PORT}${NC}"
echo -e "  API:    ${BLUE}http://localhost:${PORT}/docs${NC}"
echo ""
echo -e "  Useful commands:"
echo -e "    ${COMPOSE_CMD} logs -f    # follow logs"
echo -e "    ${COMPOSE_CMD} down       # stop"
echo -e "    ${COMPOSE_CMD} restart    # restart"
echo ""
