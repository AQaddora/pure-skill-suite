#!/usr/bin/env bash
# maestro-sync/announce.sh — record a maestro routing decision to sprint memory so
# the NEXT session/device sees it and the chain stays deduplicated. Two writes:
#   1) the shared board AgentHandoffs/SPRINTS.md (human-readable ledger)
#   2) a heartbeat to POST /api/internal/session (machine roster)
#
#   announce.sh --decision new|steer|duplicate|followup|feature-add|rescope \
#               --repo <repo> --topic "<short topic>" \
#               [--session <tmux/session-key>] [--node local|fatmac|...] \
#               [--note "<what you did>"]
set -euo pipefail

API="${AQOS_API:-https://api.aqaddoura.com}"
SECRET="$(cat "$HOME/.aqos/secret" 2>/dev/null || true)"
BOARD="${AQOS_SPRINTS_BOARD:-$HOME/Work/AgentHandoffs/SPRINTS.md}"
HOST="$(hostname)"
DECISION="" REPO="" TOPIC="" SESSION="" NODE="local" NOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --decision) DECISION="$2"; shift 2;;
    --repo)     REPO="$2";     shift 2;;
    --topic)    TOPIC="$2";    shift 2;;
    --session)  SESSION="$2";  shift 2;;
    --node)     NODE="$2";     shift 2;;
    --note)     NOTE="$2";     shift 2;;
    *) shift;;
  esac
done
[[ -n "$DECISION" && -n "$TOPIC" ]] || { echo "usage: announce.sh --decision <d> --repo <r> --topic <t> [--session s] [--node n] [--note ...]" >&2; exit 2; }

STAMP="$(date -u +'%Y-%m-%d %H:%M UTC' 2>/dev/null || echo 'now')"
LINE="- [$STAMP] **$DECISION** · repo=\`${REPO:-—}\` · topic=_${TOPIC}_ · node=$NODE · session=\`${SESSION:-—}\` · @$HOST${NOTE:+ — $NOTE}"

# 1) append to the shared board (create header if missing)
if [[ ! -f "$BOARD" ]]; then
  mkdir -p "$(dirname "$BOARD")"
  cat > "$BOARD" <<HDR
# SPRINTS — maestro-sync routing ledger (AQaddoura OS)

Every maestro session appends its routing decision here BEFORE/AFTER acting, so the next
session on any device dedupes against it. Read by \`maestro-sync/scripts/roster.sh\`.
Decisions: new · steer · duplicate · followup · feature-add · rescope.

---

HDR
fi
printf '%s\n' "$LINE" >> "$BOARD"
echo "[announce] board ← $BOARD" >&2

# 2) heartbeat the machine roster (best-effort)
if [[ -n "$SECRET" ]]; then
  payload=$(DECISION="$DECISION" REPO="$REPO" TOPIC="$TOPIC" SESSION="$SESSION" HOST="$HOST" NOTE="$NOTE" python3 - <<'PY'
import json,os
key=("maestro-"+(os.environ.get("SESSION") or os.environ.get("TOPIC","")))[:60].strip().replace(" ","-").lower()
print(json.dumps({
  "session_key": key or "maestro-sync",
  "machine": os.environ.get("HOST",""),
  "repo": os.environ.get("REPO",""),
  "status": "active",
  "title": f"[{os.environ['DECISION']}] {os.environ['TOPIC']}",
  "summary": (os.environ.get("NOTE") or "")[:500],
}))
PY
)
  curl -s -m 12 -X POST "$API/api/internal/session" \
    -H "x-internal-secret: $SECRET" -H 'content-type: application/json' \
    -d "$payload" >/dev/null 2>&1 \
    && echo "[announce] roster ← /api/internal/session" >&2 \
    || echo "[announce] roster heartbeat failed (board still recorded)" >&2
fi

printf '%s\n' "$LINE"
