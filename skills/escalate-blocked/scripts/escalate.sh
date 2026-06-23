#!/usr/bin/env bash
# escalate-blocked — owner handoff: notify Ahmed (WhatsApp + AQ Backoffice) and
# stage an ATTACHED terminal pre-loaded with the exact blocked command so he can
# finish it in one tap. The agent never auto-runs the gated command on his behalf.
#
#   escalate.sh --task "<short>" --cmd "<blocked command>" \
#               [--node local|fatmac] [--cwd <dir>] [--reason "<why>"] [--repo <name>]
#
# Prints the attach command on the last line.
set -euo pipefail

API="${AQOS_API:-https://api.aqaddoura.com}"
TASK="" ; CMD="" ; NODE="local" ; CWD="$PWD" ; REASON="permission gate" ; REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)   TASK="$2";   shift 2;;
    --cmd)    CMD="$2";    shift 2;;
    --node)   NODE="$2";   shift 2;;
    --cwd)    CWD="$2";    shift 2;;
    --reason) REASON="$2"; shift 2;;
    --repo)   REPO="$2";   shift 2;;
    *) shift;;
  esac
done
[[ -n "$TASK" && -n "$CMD" ]] || { echo "usage: escalate.sh --task <t> --cmd <c> [--node local|fatmac] [--cwd dir] [--reason r] [--repo name]" >&2; exit 2; }

slug=$(printf '%s' "$TASK" | tr -cs 'A-Za-z0-9' '-' | tr 'A-Z' 'a-z' | cut -c1-28 | sed 's/-\{1,\}$//')
SESSION="handoff-$slug"

stage_local() {
  command -v tmux >/dev/null || { echo "(tmux not installed — run manually) $CMD" >&2; echo "MANUAL"; return; }
  tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"
  tmux new-session -d -s "$SESSION" -c "$CWD"
  tmux send-keys -t "$SESSION" "clear; printf '\n  ── HANDOFF ─────────────────────────────\n  task   : %s\n  reason : %s\n  cwd    : %s\n  → review the staged command below, then press Enter to run it.\n  ────────────────────────────────────────\n\n' \"$TASK\" \"$REASON\" \"$CWD\"" Enter
  # Pre-type the blocked command WITHOUT a trailing Enter — Ahmed reviews then runs it.
  tmux send-keys -t "$SESSION" "$CMD"
  echo "tmux attach -t $SESSION"
}

stage_node() {
  # shellcheck disable=SC1090
  source "$HOME/.aqos/node.env" 2>/dev/null || { echo "(no node.env — staging locally instead)" >&2; stage_local; return; }
  local host="${NODE_HOST:-fatmac}" user="${NODE_USER:-aseel}" rcwd="${CWD:-$NODE_WORK}"
  ssh -o ConnectTimeout=10 "$user@$host" \
    "tmux has-session -t '$SESSION' 2>/dev/null && tmux kill-session -t '$SESSION'; tmux new-session -d -s '$SESSION' -c '$rcwd'; tmux send-keys -t '$SESSION' \"$CMD\"" \
    >/dev/null 2>&1 || { echo "(could not reach $host — staging locally)" >&2; stage_local; return; }
  echo "ssh -t $user@$host tmux attach -t $SESSION"
}

case "$NODE" in
  fatmac|node|compute) ATTACH=$(stage_node);;
  *)                   ATTACH=$(stage_local);;
esac

MSG="🔐 BLOCKED — needs you: ${TASK}
reason: ${REASON}
finish it → ${ATTACH}"

# Register a handoff session so the AQ Backoffice / Workroom surfaces it (and the
# backend fan-out, once deployed, pushes WhatsApp + AQ Backoffice notification).
SECRET="$(cat "$HOME/.aqos/secret" 2>/dev/null || true)"
if [[ -n "$SECRET" ]]; then
  payload=$(MSG="$MSG" TASK="$TASK" REPO="$REPO" SESSION="$SESSION" HOST="$(hostname)" python3 - <<'PY'
import json,os
print(json.dumps({
  "session_key": "handoff-"+os.environ["SESSION"],
  "machine": os.environ.get("HOST",""),
  "repo": os.environ.get("REPO",""),
  "status": "handoff",
  "title": "HANDOFF: "+os.environ["TASK"],
  "summary": os.environ["MSG"],
}))
PY
)
  curl -s -m 12 -X POST "$API/api/internal/session" \
    -H "x-internal-secret: $SECRET" -H 'content-type: application/json' \
    -d "$payload" >/dev/null 2>&1 \
    && echo "[escalate] handoff registered to AQ Backoffice" >&2 \
    || echo "[escalate] backoffice notify failed (surfaced locally only)" >&2
else
  echo "[escalate] no ~/.aqos/secret — skipping backoffice register" >&2
fi

printf '%s\n' "$MSG" >&2
# Last line = the attach command (machine-readable for callers / the maestro).
printf '%s\n' "$ATTACH"
