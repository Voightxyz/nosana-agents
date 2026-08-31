#!/usr/bin/env bash
# Boot sequence for the Voight ZeroClaw GPU agent container.
# bash (not sh): `wait -n` below needs it.
#
# Environment contract (static ZeroClaw config is baked in the Dockerfile):
#   ZEROCLAW_gateway__paired_tokens  REQUIRED — sha256 of the agent's bearer;
#                                    the job URL is publicly reachable
#   SOUL_B64           base64 persona → the agent workspace SOUL.md
#   MODEL              model tag Ollama serves (default: hermes3:8b)
#   MIN_TOKS_PER_SEC   node speed gate threshold (default: 15; 0 disables)
set -u

export HOME=/zeroclaw-data
WORKSPACE=/zeroclaw-data/.zeroclaw/agents/main/workspace
mkdir -p "${WORKSPACE}"
cd /zeroclaw-data

if [ -z "${ZEROCLAW_gateway__paired_tokens:-}" ]; then
  echo "[boot] FATAL: ZEROCLAW_gateway__paired_tokens is required — the gateway URL is publicly reachable" >&2
  exit 1
fi

# Persona → per-agent workspace SOUL.md (same convention as the Hermes image).
# base64 transport keeps user-supplied content injection-safe.
[ -n "${SOUL_B64:-}" ] && echo "${SOUL_B64}" | base64 -d > "${WORKSPACE}/SOUL.md"

# ZeroClaw resolves its model from the providers entry — keep it in lockstep
# with whatever Ollama actually serves.
export ZEROCLAW_providers__models__ollama__default__model="${MODEL}"

# 1. Local model server (loopback only — never exposed by the job definition).
OLLAMA_HOST=127.0.0.1:11434 ollama serve &

echo "[boot] waiting for ollama…"
i=0
until curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && echo "[boot] FATAL: ollama never came up" >&2 && exit 1
  sleep 1
done

# Ensure the model is present — a no-op when weights are baked into the image.
ollama pull "${MODEL}" || echo "[boot] pull failed — relying on baked weights"

# 2. Node speed gate — same contract as the Hermes image: a short timed
# generation against local Ollama; below MIN_TOKS_PER_SEC the boot logs the
# measured rate and exits 86 BEFORE the gateway comes up, so the deploy engine
# re-rolls the deployment onto a fresh node. Pure generation rate
# (eval_count/eval_duration); doubles as a VRAM warm-up. No python in this
# image — parsed with grep/awk.
MIN_TOKS_PER_SEC="${MIN_TOKS_PER_SEC:-15}"
if [ "${MIN_TOKS_PER_SEC}" != "0" ]; then
  # Warm-up pass, DISCARDED: the very first generation after a model load also
  # pays CUDA graph compilation and the card's clock ramp — a healthy GPU
  # measures a fraction of its real rate on that pass (verified live: 2.5 tok/s
  # cold vs 33 tok/s warm on the same card). Only warm generation is measured;
  # measuring the cold pass refuses perfectly good nodes.
  curl -sf --max-time 300 http://127.0.0.1:11434/api/generate \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"Say OK.\",\"stream\":false,\"options\":{\"num_predict\":16}}" >/dev/null 2>&1 || true
  tokps=""
  for attempt in 1 2 3; do
    resp=$(curl -sf --max-time 240 http://127.0.0.1:11434/api/generate \
      -d "{\"model\":\"${MODEL}\",\"prompt\":\"Count from 1 to 30, digits separated by spaces.\",\"stream\":false,\"options\":{\"num_predict\":48}}") || resp=""
    count=$(printf '%s' "$resp" | grep -o '"eval_count":[0-9]*' | head -1 | cut -d: -f2)
    dur=$(printf '%s' "$resp" | grep -o '"eval_duration":[0-9]*' | head -1 | cut -d: -f2)
    if [ -n "${count:-}" ] && [ -n "${dur:-}" ] && [ "$dur" -gt 0 ]; then
      tokps=$(awk "BEGIN{printf \"%.1f\", ${count} / (${dur} / 1000000000)}")
      awk "BEGIN{exit !(${tokps} >= ${MIN_TOKS_PER_SEC})}" && break
      echo "[speed-check] attempt ${attempt}: ${tokps} tok/s below ${MIN_TOKS_PER_SEC} — retrying (card may still be ramping)"
    else
      echo "[speed-check] probe attempt ${attempt} failed — retrying"
    fi
  done
  if [ -z "$tokps" ]; then
    echo "[speed-check] FATAL: node could not complete a 48-token generation" >&2
    exit 86
  fi
  if awk "BEGIN{exit !(${tokps} >= ${MIN_TOKS_PER_SEC})}"; then
    echo "[speed-check] PASS ${tokps} tok/s (min ${MIN_TOKS_PER_SEC})"
  else
    echo "[speed-check] FAIL ${tokps} tok/s < ${MIN_TOKS_PER_SEC} — refusing this node" >&2
    exit 86
  fi
fi

# 3. Agent gateway (the exposed service).
zeroclaw daemon &

# Mirror the first process to exit (ollama or zeroclaw) so a dead model server
# takes the container down instead of leaving a healthy-looking mute gateway.
wait -n
code=$?
echo "[boot] child exited (${code})"
exit "$code"
