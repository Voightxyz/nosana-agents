#!/usr/bin/env bash
# Curated-memory sync between the agent container and the platform.
#
# GPU nodes have no persistent volume: the agent's curated memory
# (/opt/data/memories — MEMORY.md, USER.md) would die with every job
# rotation. This wrapper round-trips it through a platform endpoint:
#
#   restore   GET  $VOIGHT_MEMORY_URL  → tar.gz → /opt/data/memories
#   push      tar.gz /opt/data/memories → PUT $VOIGHT_MEMORY_URL
#
# Auth: Authorization: Bearer $VOIGHT_AGENT_KEY (per-agent, revocable).
# Both verbs are best-effort no-ops when VOIGHT_MEMORY_URL is unset, and a
# restore of a brand-new agent (404/empty) is not an error.
set -u

MEM_DIR="${MEMORY_DIR:-/opt/data/memories}"
CMD="${1:-}"

if [ -z "${VOIGHT_MEMORY_URL:-}" ]; then
  exit 0
fi
AUTH="Authorization: Bearer ${VOIGHT_AGENT_KEY:-}"

case "$CMD" in
  restore)
    mkdir -p "$MEM_DIR"
    tmp="$(mktemp)"
    status=$(curl -sf -o "$tmp" -w '%{http_code}' -m 30 -H "$AUTH" "$VOIGHT_MEMORY_URL" || echo 000)
    if [ "$status" = "200" ] && [ -s "$tmp" ]; then
      tar xzf "$tmp" -C "$MEM_DIR" && echo "[memory] restored $(ls "$MEM_DIR" | wc -l | tr -d ' ') file(s)"
    else
      echo "[memory] nothing to restore (HTTP $status)"
    fi
    rm -f "$tmp"
    ;;
  push)
    [ -d "$MEM_DIR" ] || exit 0
    # Skip the upload when nothing changed since the last push.
    sum="$(find "$MEM_DIR" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum | cut -d' ' -f1)"
    last="$(cat /tmp/.memory-sync-sum 2>/dev/null || true)"
    [ "$sum" = "$last" ] && exit 0
    tmp="$(mktemp)"
    tar czf "$tmp" -C "$MEM_DIR" .
    status=$(curl -sf -o /dev/null -w '%{http_code}' -m 30 -X PUT -H "$AUTH" \
      -H 'content-type: application/gzip' --data-binary @"$tmp" "$VOIGHT_MEMORY_URL" || echo 000)
    rm -f "$tmp"
    if [ "$status" = "200" ] || [ "$status" = "204" ]; then
      echo "$sum" > /tmp/.memory-sync-sum
      echo "[memory] pushed"
    else
      echo "[memory] push failed (HTTP $status)" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: memory-sync restore|push" >&2
    exit 2
    ;;
esac
