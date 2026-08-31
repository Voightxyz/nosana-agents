# Voight GPU agent image for Nosana — ZeroClaw variant
#
# One container = one autonomous agent with its own local model:
#   - Ollama serves an OpenAI-compatible endpoint on 127.0.0.1:11434 (GPU)
#   - the ZeroClaw runtime (github.com/zeroclaw-labs/zeroclaw, MIT/Apache)
#     drives the agent loop and exposes its gateway on :8642 — the only
#     exposed port (same platform contract as the Hermes variant)
#   - inference never leaves the container: no inference API key exists inside
#
# Build: docker build -t voight-zeroclaw-gpu image-zeroclaw/
#
# The ZeroClaw binary is copied from the upstream image, PINNED BY DIGEST
# (release 0.8.4) — framework upgrades are a deliberate bump of this ref,
# never a floating tag (same lesson as the Hermes pin).

FROM ghcr.io/zeroclaw-labs/zeroclaw:debian@sha256:d2b3ac2e6b6dd3b0d977b3722fea8bc5ba414c2d5c34d48fe42838aac217afa5 AS zeroclaw

# Ollama base PINNED BY DIGEST (0.33.2, GPU path verified live on a market node)
# — a floating :latest here silently changed the runtime under the fleet once.
FROM ollama/ollama@sha256:020e4134285e2ef4d8fd801234176de3b4faadc992a3eb06c8e66a2f9d4c4ba2

COPY --from=zeroclaw /usr/local/bin/zeroclaw /usr/local/bin/zeroclaw

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
RUN chmod +x /start.sh && mkdir -p /zeroclaw-data

# Agent state lives under /zeroclaw-data. Static ZeroClaw config is baked as
# env (the contract validated live on Cloud Run); per-agent values
# (paired token hash, SOUL_B64, MODEL override) arrive via the job definition.
ENV HOME=/zeroclaw-data \
    MODEL=qwen2.5:7b-instruct \
    # Boot-time node speed gate (see start.sh): refuse hosts that generate
    # below this rate, so a degraded GPU never serves an agent. 0 disables.
    MIN_TOKS_PER_SEC=15 \
    # ZeroClaw doesn't require a huge window (its system prompt is a fraction
    # of Hermes'): 32K fits beside an 8B model on a 12GB card with room to
    # spare. Flash attention + 8-bit KV keep the cache small.
    OLLAMA_CONTEXT_LENGTH=32768 \
    OLLAMA_FLASH_ATTENTION=1 \
    OLLAMA_KV_CACHE_TYPE=q8_0 \
    # Gateway contract: pairing FORCED on (per-agent hash arrives per-job),
    # platform port 8642, public bind (the job URL is public; auth = bearer).
    ZEROCLAW_gateway__require_pairing=true \
    ZEROCLAW_gateway__port=8642 \
    ZEROCLAW_gateway__host=0.0.0.0 \
    ZEROCLAW_gateway__allow_public_bind=true \
    # One configured agent; profile refs have NO defaults upstream — pin them.
    ZEROCLAW_agents__main__enabled=true \
    ZEROCLAW_agents__main__model_provider=ollama.default \
    ZEROCLAW_agents__main__risk_profile=default \
    ZEROCLAW_agents__main__runtime_profile=default \
    ZEROCLAW_risk_profiles__default__workspace_only=true \
    ZEROCLAW_risk_profiles__default__excluded_tools=shell \
    ZEROCLAW_runtime_profiles__default__agentic=true \
    ZEROCLAW_providers__models__ollama__default__uri=http://127.0.0.1:11434

# Only the agent gateway is exposed; Ollama stays loopback-only.
EXPOSE 8642

ENTRYPOINT ["/start.sh"]
