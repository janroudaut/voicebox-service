# Voicebox Service

A ready-to-use Docker service wrapping [Voicebox](https://github.com/jamiepine/voicebox) (open-source voice synthesis studio). Runs on **CPU or NVIDIA GPU**, designed for standalone use or integration into a `docker-compose` stack.

## Requirements

- [Docker](https://docs.docker.com/get-docker/) (with Compose v2)
- *(Optional)* [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) for GPU acceleration

## Quick start

```bash
git clone --recurse-submodules https://github.com/janroudaut/voicebox-service.git
cd voicebox-service

# Auto-detects GPU — falls back to CPU if unavailable
./run.sh
```

The script will:
1. Detect whether an NVIDIA GPU is available
2. Build the Docker image (CPU or CUDA variant)
3. Start the service via `docker compose`
4. Wait for the healthcheck to pass
5. Download the default TTS model (`chatterbox-tts`)
6. Verify GPU access (if applicable)

### Manual docker compose

```bash
# CPU only
docker compose up -d --build

# With GPU
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build
```

## Configuration

Copy `.env.example` to `.env` and edit as needed:

| Variable | Default | Description |
|----------|---------|-------------|
| `VOICEBOX_DEVICE` | `cpu` | `cpu` or `cuda` (auto-detected by `run.sh`) |
| `VOICEBOX_PORT` | `17493` | Exposed port |
| `VOICEBOX_MODEL` | `chatterbox-tts` | Model auto-downloaded at startup (set empty to skip) |
| `NO_COLOR` | _(unset)_ | Disable colored output (also auto-disabled when stdout is not a TTY; `--no-color` flag supported) |

## Integration in another project

Add this repo as a submodule, then reference the service in your own `docker-compose.yml`:

```bash
git submodule add <url> services/voicebox
```

```yaml
# In the parent project's docker-compose.yml:
services:
  voicebox:
    build:
      context: ./services/voicebox
      args:
        DEVICE: ${VOICEBOX_DEVICE:-cpu}
    volumes:
      - voicebox-data:/app/data
    environment:
      HF_HOME: /app/data/hf-cache
      HF_HUB_DISABLE_XET: "1"
      NUMBA_CACHE_DIR: /tmp/numba_cache
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:17493/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    # No exposed ports — accessible via Docker network (http://voicebox:17493)

volumes:
  voicebox-data:
```

For GPU support in the parent project, add the `deploy.resources` block from `docker-compose.gpu.yml`.

## Available models

### TTS (Text-to-Speech)

All TTS models support zero-shot voice cloning from reference audio samples.

| Model | Languages | Size | VRAM (GPU) | CPU | Notes |
|-------|-----------|------|------------|-----|-------|
| **chatterbox-tts** | 23 (en, fr, de, es, …) | ~2-3 GB | ~2 GB | Slow | Best multilingual quality & natural prosody |
| **chatterbox-turbo** | English only | ~1.5 GB | ~1.5 GB | Slow | Fastest Chatterbox; supports paralinguistic tags (`[laugh]`, `[cough]`, …) |
| **qwen-tts-1.7B** | 23 (en, zh, ja, ko, …) | ~4 GB | ~4 GB | Very slow | Instruction-guided generation (`instruct` param) |
| **qwen-tts-0.6B** | Same as 1.7B | ~2 GB | ~2 GB | Slow | Lighter variant — good compromise for CPU |
| **luxtts** | English | ~1 GB | ~1 GB | Fast | Most memory-efficient; 48 kHz output |

> **CPU users**: prefer **luxtts** or **qwen-tts-0.6B** for usable generation speed.
> **GPU users**: **chatterbox-tts** offers the best quality across languages.

### STT (Speech-to-Text)

Whisper models are used for audio transcription via the `/transcribe` endpoint.

| Model | Size | VRAM (GPU) | CPU | Use case |
|-------|------|------------|-----|----------|
| **whisper-base** | ~140 MB | ~1 GB | Fast | Quick transcription, acceptable accuracy |
| **whisper-small** | ~480 MB | ~2 GB | OK | Better accuracy, still reasonably fast |
| **whisper-medium** | ~1.5 GB | ~5 GB | Slow | High accuracy |
| **whisper-large** | ~3 GB | ~10 GB | Impractical | Highest accuracy — GPU required |
| **whisper-turbo** | ~2 GB | ~6 GB | Slow | Near-large accuracy with faster inference |

All Whisper models support 99 languages with automatic language detection.

## Access

| Service | URL |
|---------|-----|
| Web UI | http://localhost:17493 |
| API docs (Swagger) | http://localhost:17493/docs |

## API reference

Interactive documentation is available at `/docs`. Below is an overview of the main endpoints.

### Models

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/models/status` | List all models with download/load status |
| `POST` | `/models/download` | Download a model (`{"model_name": "..."}`) |
| `POST` | `/models/download/cancel` | Cancel an active download |
| `POST` | `/models/load` | Load a downloaded model into memory |
| `POST` | `/models/unload` | Unload the current model |
| `DELETE` | `/models/{model_name}` | Delete a downloaded model from disk |

See [Available models](#available-models) for the full list.

### Speech generation

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/generate` | Generate speech from text |
| `POST` | `/generate/stream` | Stream generated speech |
| `GET` | `/audio/{generation_id}` | Retrieve generated audio file |
| `POST` | `/transcribe` | Transcribe audio to text (requires a Whisper model) |

### Voice profiles

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/profiles` | List all voice profiles |
| `POST` | `/profiles` | Create a new profile |
| `GET` | `/profiles/{profile_id}` | Get profile details |
| `PUT` | `/profiles/{profile_id}` | Update a profile |
| `DELETE` | `/profiles/{profile_id}` | Delete a profile |
| `POST` | `/profiles/{profile_id}/samples` | Upload a voice sample |
| `GET` | `/profiles/{profile_id}/samples` | List voice samples |
| `POST` | `/profiles/import` | Import a profile from file |
| `GET` | `/profiles/{profile_id}/export` | Export a profile |

### Channels

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/channels` | List all channels |
| `POST` | `/channels` | Create a channel |
| `GET` | `/channels/{channel_id}` | Get channel details |
| `PUT` | `/channels/{channel_id}` | Update a channel |
| `DELETE` | `/channels/{channel_id}` | Delete a channel |
| `GET` | `/channels/{channel_id}/voices` | Get voices assigned to a channel |
| `PUT` | `/channels/{channel_id}/voices` | Set voices for a channel |

### Stories

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/stories` | List all stories |
| `POST` | `/stories` | Create a story |
| `GET` | `/stories/{story_id}` | Get story details |
| `PUT` | `/stories/{story_id}` | Update a story |
| `DELETE` | `/stories/{story_id}` | Delete a story |
| `POST` | `/stories/{story_id}/items` | Add an item to a story |
| `DELETE` | `/stories/{story_id}/items/{item_id}` | Remove an item |
| `GET` | `/stories/{story_id}/export-audio` | Export story as audio |

### History

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/history` | List generation history |
| `GET` | `/history/stats` | Get usage statistics |
| `GET` | `/history/{generation_id}` | Get a specific generation |
| `DELETE` | `/history/{generation_id}` | Delete a generation |
| `GET` | `/history/{generation_id}/export-audio` | Export generation audio |

### System

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Server health, GPU status, loaded model |
| `GET` | `/tasks/active` | Active downloads and generations |
| `POST` | `/cache/clear` | Clear internal caches |
| `POST` | `/shutdown` | Gracefully shut down the server |

## Persistent data

Data is stored in Docker named volumes:

| Volume | Contents |
|--------|----------|
| `voicebox-data` | SQLite database, voice profiles, generated audio, HuggingFace model cache |

## Useful commands

```bash
# Follow logs
docker compose logs -f voicebox

# Stop
docker compose down

# Restart
docker compose restart

# Rebuild after changes
docker compose up -d --build

# GPU mode
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build
```
