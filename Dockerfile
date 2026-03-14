# ============================================================
# Voicebox — Local TTS Server with Web UI
# Multi-stage build: Frontend → CPU or CUDA Runtime
# Usage: docker build --build-arg DEVICE=cpu|cuda .
# ============================================================

ARG DEVICE=cpu

# === Stage 1: Build frontend ===
FROM oven/bun:1 AS frontend

WORKDIR /build

# Copy workspace config and frontend source
COPY voicebox/package.json voicebox/bun.lock ./
COPY voicebox/app/ ./app/
COPY voicebox/web/ ./web/

# Strip workspaces not needed for web build, and fix trailing comma
RUN sed -i '/"tauri"/d; /"landing"/d' package.json && \
    sed -i -z 's/,\n  ]/\n  ]/' package.json
RUN bun install --no-save
# Externalize Tauri-specific imports (not available in web builds)
RUN sed -i "s|outDir: 'dist',|outDir: 'dist',\n    rollupOptions: { external: [/^@tauri-apps/] },|" web/vite.config.ts
# Build frontend (skip tsc — upstream has pre-existing type errors)
RUN cd web && bunx --bun vite build


# === Stage 2a: CUDA base ===
FROM nvidia/cuda:12.6.3-runtime-ubuntu22.04 AS base-cuda

ENV DEBIAN_FRONTEND=noninteractive

# Install Python 3.11 from deadsnakes PPA + runtime deps
RUN apt-get update && \
    apt-get install -y --no-install-recommends software-properties-common && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.11 python3.11-venv python3.11-dev \
        pip \
        git build-essential \
        ffmpeg curl \
    && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1

ENV PYTORCH_INDEX=https://download.pytorch.org/whl/cu126


# === Stage 2b: CPU base ===
FROM python:3.11-slim AS base-cpu

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git build-essential \
        ffmpeg curl \
    && rm -rf /var/lib/apt/lists/*

ENV PYTORCH_INDEX=https://download.pytorch.org/whl/cpu


# === Stage 3: Final image ===
FROM base-${DEVICE} AS final

ENV PYTHONUNBUFFERED=1
# Redirect numba cache to a writable location (container runs as host UID)
ENV NUMBA_CACHE_DIR=/tmp/numba_cache

WORKDIR /app

# Upgrade pip and install uv (needed as build backend by linacodec)
RUN pip install --no-cache-dir --upgrade pip uv

# Install PyTorch (CUDA or CPU variant based on PYTORCH_INDEX set in base stage)
RUN pip install --no-cache-dir \
    torch torchaudio --index-url ${PYTORCH_INDEX}

# Install remaining Python deps
COPY voicebox/backend/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
RUN pip install --no-cache-dir git+https://github.com/QwenLM/Qwen3-TTS.git
# chatterbox-tts: installed --no-deps to avoid version pin conflicts
RUN pip install --no-cache-dir --no-deps chatterbox-tts

# Create non-root user with UID/GID 1000 (matches typical host user)
RUN groupadd -g 1000 voicebox 2>/dev/null || true && \
    useradd -u 1000 -g 1000 -m -s /bin/bash voicebox 2>/dev/null || true

# Copy backend application code
COPY --chown=voicebox:voicebox voicebox/backend/ /app/backend/

# Copy entrypoint that mounts the web frontend onto FastAPI
COPY --chown=voicebox:voicebox entrypoint.py /app/entrypoint.py

# Copy built frontend from frontend stage
COPY --from=frontend --chown=voicebox:voicebox /build/web/dist /app/frontend/

# Create data directories owned by non-root user (hf-cache lives inside data/)
RUN mkdir -p /app/data/generations /app/data/profiles /app/data/cache /app/data/hf-cache \
    && chown -R voicebox:voicebox /app/data

USER voicebox

EXPOSE 17493

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=120s \
    CMD curl -f http://localhost:17493/health || exit 1

CMD ["python3", "-m", "uvicorn", "entrypoint:app", "--host", "0.0.0.0", "--port", "17493"]
