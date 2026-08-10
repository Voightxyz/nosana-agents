#!/usr/bin/env bash
# Boot sequence for the Voight GPU agent container.
# bash (not sh): `wait -n` below needs it.
#
# Environment contract (all optional unless noted):
#   MODEL              model tag Ollama serves (default: qwen3:8b)
#   API_SERVER_KEY     gateway auth key — REQUIRED: the service URL is public
#   HERMES_CONFIG_B64  base64 config.yaml (omit for the built-in local-model config)
#   SOUL_B64           base64 SOUL.md persona
#   VOIGHT_MEMORY_URL  memory sync endpoint (see memory-sync)
#   VOIGHT_AGENT_KEY   bearer token for the memory endpoint
#   MEMORY_SYNC_INTERVAL  seconds between periodic pushes (default: 120)
set -u

export HOME=/opt/data HERMES_HOME=/opt/data
mkdir -p /opt/data/memories
cd /opt/data

if [ -z "${API_SERVER_KEY:-}" ]; then
  echo "[boot] FATAL: API_SERVER_KEY is required — the gateway URL is publicly reachable" >&2
  exit 1
fi

# 1. Restore curated memory from the platform (best-effort, never blocks boot).
memory-sync restore || echo "[boot] memory restore skipped/failed (continuing)"

# 2. Materialize config + persona. Base64 transport keeps user-supplied content
#    injection-safe: decoded to files, never interpolated into the shell.
SEARCH_BACKEND=ddgs
[ -n "${TAVILY_API_KEY:-}" ] && SEARCH_BACKEND=tavily
if [ -n "${HERMES_CONFIG_B64:-}" ]; then
  echo "${HERMES_CONFIG_B64}" | base64 -d > /opt/data/config.yaml
else
  cat > /opt/data/config.yaml <<EOF
model:
  default: "${MODEL}"
  provider: openai-api
  base_url: http://127.0.0.1:11434/v1
  # Hermes requires >= 64K context; Ollama is launched with a matching
  # OLLAMA_CONTEXT_LENGTH so the served window actually backs this value.
  context_length: 65536

web:
  search_backend: ${SEARCH_BACKEND}

platform_toolsets:
  api_server: [terminal, file, web, todo, skills, memory]

# Deployed agents are autonomous — nobody is at the gateway to approve
# commands, and the container is a disposable sandbox.
approvals:
  mode: "off"

delegation:
  child_timeout_seconds: 120

skills:
  creation_nudge_interval: 0
EOF
fi
[ -n "${SOUL_B64:-}" ] && echo "${SOUL_B64}" | base64 -d > /opt/data/SOUL.md

# Hermes' openai-api provider requires a key to be present; the local endpoint
# ignores its value. No real inference credential exists in this container.
export OPENAI_API_KEY="${OPENAI_API_KEY:-local}"
export OPENAI_BASE_URL="http://127.0.0.1:11434/v1"

# 3. Local model server (loopback only — never exposed by the job definition).
OLLAMA_HOST=127.0.0.1:11434 ollama serve &

echo "[boot] waiting for ollama…"
i=0
until curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && echo "[boot] FATAL: ollama never came up" >&2 && exit 1
  sleep 1
done

# Ensure the model is present — a no-op when weights are baked into the image.
ollama pull "${MODEL}" || echo "[boot] pull failed — relying on baked weights"

# 4. Agent gateway (the exposed service).
/opt/hermes/.venv/bin/hermes gateway run --no-supervise &

# 5. Periodic memory push, plus a final push on shutdown.
(
  while :; do
    sleep "${MEMORY_SYNC_INTERVAL:-120}"
    memory-sync push || true
  done
) &

# Mirror the first process to exit (ollama or hermes) after a last memory push.
wait -n
code=$?
echo "[boot] child exited (${code}) — final memory push"
memory-sync push || true
exit "$code"
