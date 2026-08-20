#!/usr/bin/env bash
# Curated-memory sync between the agent container and the platform.
#
# GPU nodes have no persistent volume: the agent's curated memory
# (/opt/data/memories — MEMORY.md, USER.md) would die with every job
# rotation. This wrapper round-trips each file through the platform's
# per-file endpoint (the same objects other hosting modes mount directly,
# so an agent's memory stays portable across hosts):
#
#   restore   GET $VOIGHT_MEMORY_URL/<file> → {"content": <base64>} → file
#   push      file → {"content": <base64>} → PUT $VOIGHT_MEMORY_URL/<file>
#
# Auth: Authorization: Bearer $VOIGHT_AGENT_KEY (per-agent, revocable).
# Both verbs are best-effort no-ops when VOIGHT_MEMORY_URL is unset, and a
# restore of a brand-new agent (404 per file) is not an error.
set -u

MEM_DIR="${MEMORY_DIR:-/opt/data/memories}"
# The curated whitelist the endpoint accepts — keep in lockstep server-side.
FILES="MEMORY.md USER.md"
CMD="${1:-}"

if [ -z "${VOIGHT_MEMORY_URL:-}" ]; then
  exit 0
fi
AUTH="Authorization: Bearer ${VOIGHT_AGENT_KEY:-}"
# base64/JSON helper — the hermes venv python is always present in the image;
# fall back to a system python for local testing outside the container.
PY="${MEMORY_SYNC_PYTHON:-/opt/hermes/.venv/bin/python}"
command -v "$PY" >/dev/null 2>&1 || PY="$(command -v python3)"

case "$CMD" in
  restore)
    mkdir -p "$MEM_DIR"
    restored=0
    for f in $FILES; do
      tmp="$(mktemp)"
      status=$(curl -sf -o "$tmp" -w '%{http_code}' -m 30 -H "$AUTH" "$VOIGHT_MEMORY_URL/$f" || echo 000)
      if [ "$status" = "200" ] && [ -s "$tmp" ]; then
        if "$PY" -c 'import base64,json,sys; open(sys.argv[1],"wb").write(base64.b64decode(json.load(sys.stdin)["content"]))' \
          "$MEM_DIR/$f" <"$tmp"; then
          restored=$((restored + 1))
        else
          echo "[memory] restore of $f failed to decode" >&2
        fi
      fi
      rm -f "$tmp"
    done
    echo "[memory] restored $restored file(s)"
    ;;
  push)
    [ -d "$MEM_DIR" ] || exit 0
    for f in $FILES; do
      [ -f "$MEM_DIR/$f" ] || continue
      # Skip the upload when this file hasn't changed since its last push.
      sum="$(md5sum "$MEM_DIR/$f" 2>/dev/null | cut -d' ' -f1)"
      last="$(cat "/tmp/.memory-sync-sum-$f" 2>/dev/null || true)"
      [ "$sum" = "$last" ] && continue
      body="$(mktemp)"
      "$PY" -c 'import base64,json,sys; print(json.dumps({"content": base64.b64encode(open(sys.argv[1],"rb").read()).decode()}))' \
        "$MEM_DIR/$f" >"$body"
      status=$(curl -sf -o /dev/null -w '%{http_code}' -m 30 -X PUT -H "$AUTH" \
        -H 'content-type: application/json' --data-binary @"$body" "$VOIGHT_MEMORY_URL/$f" || echo 000)
      rm -f "$body"
      if [ "$status" = "200" ] || [ "$status" = "204" ]; then
        echo "$sum" >"/tmp/.memory-sync-sum-$f"
        echo "[memory] pushed $f"
      else
        echo "[memory] push of $f failed (HTTP $status)" >&2
      fi
    done
    ;;
  *)
    echo "usage: memory-sync restore|push" >&2
    exit 2
    ;;
esac
