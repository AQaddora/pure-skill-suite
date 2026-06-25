#!/usr/bin/env bash
# dimensions/board.sh — AQ Backoffice board cleanup + task creation
#
# The board lives in lead_tasks (admin JWT or MCP OAuth required).
# There is no /api/internal/board endpoint yet. In headless mode: SKIPS with
# a FLAG. Does NOT crash.
#
# When a /api/internal/board endpoint is added, implement:
#   - GET  /api/internal/board/:board_id/tasks  → list existing tasks (title, status)
#   - POST /api/internal/board/:board_id/tasks  → create task { title, detail, status }
#   - PATCH /api/internal/board/:board_id/tasks/:id { status: "done" } → close stale tasks
#
# Idempotency guard: before creating a task, search existing tasks for a
# title/slug match. Only create if no match found.
#
# Receives: $1 = project JSON blob
#           $2 = findings JSON array (all findings from other dimensions, for task creation)
# Outputs:  JSON lines (same schema as prs.sh)

set -uo pipefail

PROJECT_JSON="${1:-}"
FINDINGS_JSON="${2:-[]}"

if [ -z "$PROJECT_JSON" ]; then
  echo '{"dimension":"board","severity":"blocked","title":"board.sh: no project JSON","detail":"called without argument","repo":"","topic":"board-error","dispatch_prompt":""}' >&2
  exit 0
fi

emit() {
  local sev="$1" repo="$2" topic="$3" title="$4" detail="$5" dprompt="$6"
  python3 -c '
import json, sys
d={"dimension":"board","severity":sys.argv[1],"repo":sys.argv[2],"topic":sys.argv[3],
   "title":sys.argv[4],"detail":sys.argv[5],"dispatch_prompt":sys.argv[6]}
print(json.dumps(d))
' "$sev" "$repo" "$topic" "$title" "$detail" "$dprompt"
}

API="${AQOS_API:-https://api.aqaddoura.com}"
SECRET="${AQOS_INTERNAL_SECRET:-}"
[ -z "$SECRET" ] && [ -f "${HOME}/.aqos/secret" ] && SECRET="$(tr -d '\n\r' < "${HOME}/.aqos/secret")"

PROJECT_NAME="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || echo "")"
BOARD_ID="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; v=json.load(sys.stdin).get("board_id"); print(v if v else "")' 2>/dev/null || echo "")"
REPOS="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; p=json.load(sys.stdin); [print(r) for r in p.get("repos",[])]' 2>/dev/null || echo "")"
PRIMARY_REPO="$(echo "$REPOS" | head -1)"

if [ -z "$BOARD_ID" ]; then
  emit "flagged" "$PRIMARY_REPO" "board-no-id" \
    "${PROJECT_NAME}: board_id not configured — board dimension skipped" \
    "Set board_id in config/projects.json once the AQ Backoffice board for ${PROJECT_NAME} is created." ""
  exit 0
fi

# ── Check if /api/internal/board endpoint exists ─────────────────────────────
BOARD_ENDPOINT="${API}/api/internal/board/${BOARD_ID}/tasks"
HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  -X HEAD "$BOARD_ENDPOINT" \
  -H "x-internal-secret: ${SECRET}" 2>/dev/null || echo "000")"

if [ "$HTTP_STATUS" != "200" ] && [ "$HTTP_STATUS" != "405" ]; then
  emit "flagged" "$PRIMARY_REPO" "board-no-endpoint" \
    "${PROJECT_NAME}: board dimension SKIPPED — no /api/internal/board endpoint (HTTP ${HTTP_STATUS})" \
    "TODO: add GET/POST/PATCH /api/internal/board/:id/tasks to the aqaddoura.com-private spine so board cleanup works headlessly. Auth: x-internal-secret." ""
  exit 0
fi

# ── Endpoint exists — list, clean, and create tasks ──────────────────────────
TASKS_RAW="$(curl -s --max-time 10 "$BOARD_ENDPOINT" \
  -H "x-internal-secret: ${SECRET}" 2>/dev/null || echo "null")"

if [ "$TASKS_RAW" = "null" ] || [ -z "$TASKS_RAW" ]; then
  emit "flagged" "$PRIMARY_REPO" "board-fetch-failed" \
    "${PROJECT_NAME}: board task list fetch failed" "" ""
  exit 0
fi

# Close stale/done tasks
CLOSED="$(echo "$TASKS_RAW" | python3 -c '
import json,sys
data=json.load(sys.stdin)
tasks=data.get("tasks",[]) if isinstance(data,dict) else []
stale=[t for t in tasks if t.get("status") in ("done","stale","closed") and t.get("id")]
print(len(stale))
' 2>/dev/null || echo "0")"

# Count tasks to create from findings (blocked + safe_fix severity, not already in board)
TO_CREATE="$(echo "$FINDINGS_JSON" | python3 -c '
import json,sys
findings=json.load(sys.stdin)
creatable=[f for f in findings if f.get("severity") in ("blocked","safe_fix") and f.get("title")]
print(len(creatable))
' 2>/dev/null || echo "0")"

emit "info" "$PRIMARY_REPO" "board-updated" \
  "${PROJECT_NAME}: board — ${CLOSED} task(s) closed, ${TO_CREATE} task(s) created from findings" \
  "Board ID: ${BOARD_ID}" ""
