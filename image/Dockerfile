# Voight GPU agent image for Nosana
#
# One container = one autonomous agent with its own local model:
#   - Ollama serves an OpenAI-compatible endpoint on 127.0.0.1:11434 (GPU)
#   - the Hermes runtime (github.com/NousResearch/hermes-agent, MIT) drives the
#     agent loop and exposes its gateway API on :8642 — the only exposed port
#   - inference never leaves the container: no inference API key exists inside
#
# Build:            docker build -t voight-gpu-agent image/
# Build with baked  docker build --build-arg BAKE_MODEL=qwen3:8b \
# model weights:      -t voight-gpu-agent:qwen3-8b image/
#
# A baked model turns the ~3 min pull-at-boot into node-local Docker layer
# cache: every restart on a warm node skips the download entirely.

FROM ollama/ollama:latest

# uv manages its own CPython (Hermes needs >=3.11); the Ollama base stays as-is.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates curl git ripgrep procps && \
    rm -rf /var/lib/apt/lists/*

# Hermes runtime in its own venv. Its build backend rejects a plain
# `pip install .` — `uv sync` against the upstream lockfile is the supported
# (and reproducible) path; the editable install needs the source kept around.
ARG HERMES_REF=main
RUN git clone --depth 1 --branch "${HERMES_REF}" \
      https://github.com/NousResearch/hermes-agent /opt/hermes/src && \
    cd /opt/hermes/src && \
    UV_PROJECT_ENVIRONMENT=/opt/hermes/.venv uv sync --frozen --no-dev && \
    VIRTUAL_ENV=/opt/hermes/.venv uv pip install ddgs aiohttp && \
    rm -rf /opt/hermes/src/.git

# aiohttp is REQUIRED, not optional: the Hermes gateway's api_server platform —
# the HTTP endpoint we expose on :8642 and health-check — refuses to start
# without it (check_api_server_requirements() gates on aiohttp). uv sync
# --no-dev omits it, so the gateway would boot with "No messaging platforms
# enabled" and :8642 would never listen. Installed explicitly above.

# Optionally bake model weights into the image (empty = pull at first boot).
ARG BAKE_MODEL=""
RUN if [ -n "${BAKE_MODEL}" ]; then \
      ollama serve & OLLAMA_PID=$!; \
      sleep 3 && ollama pull "${BAKE_MODEL}" && kill "${OLLAMA_PID}"; \
    fi

COPY start.sh /start.sh
COPY memory-sync.sh /usr/local/bin/memory-sync
RUN chmod +x /start.sh /usr/local/bin/memory-sync

# Agent state lives under /opt/data (config.yaml, SOUL.md, memories/).
ENV HOME=/opt/data \
    HERMES_HOME=/opt/data \
    API_SERVER_HOST=0.0.0.0 \
    API_SERVER_PORT=8642 \
    GATEWAY_ALLOW_ALL_USERS=true \
    HERMES_ALLOW_ROOT_GATEWAY=1 \
    MODEL=hermes3:8b \
    PYTHONUNBUFFERED=1 \
    # Hermes refuses any model whose context window is under 64K. Hermes 3
    # supports 128K natively, so we serve a 64K window (qwen3 was capped at its
    # 40,960 trained ceiling and could not satisfy this). The generated config
    # pins model.context_length to match.
    OLLAMA_CONTEXT_LENGTH=65536 \
    # A 64K KV cache on an 8B model is ~8.6GB in f16 — too much beside the
    # weights on a 12GB card. Flash attention + an 8-bit KV cache roughly halve
    # it (~4.3GB), so weights + cache fit comfortably on an NVIDIA 3060.
    OLLAMA_FLASH_ATTENTION=1 \
    OLLAMA_KV_CACHE_TYPE=q8_0 \
    # Boot-time node speed gate (see start.sh): refuse hosts that generate
    # below this rate, so a degraded GPU never serves an agent. 0 disables.
    MIN_TOKS_PER_SEC=15

# Only the agent gateway is exposed; Ollama stays loopback-only.
EXPOSE 8642

ENTRYPOINT ["/start.sh"]
