#!/usr/bin/env bash
# dispatch-fix.sh — dispatch a safe-fix finding as a draft PR sprint
#
# Usage:
#   dispatch-fix.sh '<finding-json>' [--dry-run]
#
# finding-json fields used:
#   repo           GitHub repo name (without org prefix)
#   topic          short slug identifying the fix (for dedup + tmux session name)
#   title          human-readable title (used in sprint prompt)
#   dispatch_prompt full Claude prompt for the fix
#
# Dispatch path (on fatmac, headless):
#   1. Dedup: GET /api/internal/sessions?active=1 — skip if a session with
#      matching repo+topic already exists.
#   2. Create a named tmux session: fix-<repo>-<topic>-<date>
#   3. Run aqos-agent in that session:
#      ~/.aqos/aqos-agent.sh --dangerously-skip-permissions -p "<prompt>"
#   4. Register the session: POST /api/internal/session
#
# The sprint prompt is always framed as:
#   "Create a DRAFT PR in AQaddora/<repo> for: <dispatch_prompt>"
#
# Never merges, never deploys. Draft PR only.
#
# Exit codes:
#   0  dispatched (or dry-run would dispatch)
#   1  skipped (already active session for this repo+topic)
#   2  error

set -uo pipefail

FINDING_JSON="${1:-}"
DRY_RUN=0
for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && DRY_RUN=1
done

if [ -z "$FINDING_JSON" ] || [ "$FINDING_JSON" = "--dry-run" ]; then
  echo "[dispatch-fix] ERROR: finding JSON required as first argument" >&2
  exit 2
fi

# ── Parse finding ──────────────────────────────────────────────────────────
REPO="$(echo "$FINDING_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("repo",""))' 2>/dev/null || echo "")"
TOPIC="$(echo "$FINDING_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("topic",""))' 2>/dev/null || echo "")"
TITLE="$(echo "$FINDING_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("title",""))' 2>/dev/null || echo "")"
PROMPT="$(echo "$FINDING_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("dispatch_prompt",""))' 2>/dev/null || echo "")"

if [ -z "$REPO" ] || [ -z "$PROMPT" ]; then
  echo "[dispatch-fix] ERROR: finding JSON missing 'repo' or 'dispatch_prompt'" >&2
  exit 2
fi

# Sanitise topic for use in tmux session name
TOPIC_SLUG="$(echo "${TOPIC:-fix}" | tr -cs 'a-zA-Z0-9-' '-' | tr -s '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
DATE="$(date +%Y-%m-%d)"
SESSION_NAME="fix-${REPO}-${TOPIC_SLUG}-${DATE}"

# ── Config ──────────────────────────────────────────────────────────────────
API="${AQOS_API:-https://api.aqaddoura.com}"
SECRET="${AQOS_INTERNAL_SECRET:-}"
[ -z "$SECRET" ] && [ -f "${HOME}/.aqos/secret" ] && SECRET="$(tr -d '\n\r' < "${HOME}/.aqos/secret")"
AQOS_AGENT="${HOME}/.aqos/aqos-agent.sh"
WORK_DIR="${HOME}/Work"

# ── Verify org before any dispatch ──────────────────────────────────────────
# Safety check: only dispatch to AQaddora org repos
GH_ORG="$(gh repo view "AQaddora/${REPO}" --json owner --jq '.owner.login' 2>/dev/null || echo "")"
if [ "$GH_ORG" != "AQaddora" ]; then
  echo "[dispatch-fix] SAFETY: repo AQaddora/${REPO} not found or org mismatch (got '${GH_ORG}') — skipping dispatch" >&2
  exit 2
fi

# ── Dedup: check for an active session matching this repo+topic ──────────────
if [ -n "$SECRET" ]; then
  ACTIVE_SESSIONS="$(curl -s --max-time 8 \
    "${API}/api/internal/sessions?active=1&limit=100" \
    -H "x-internal-secret: ${SECRET}" 2>/dev/null || echo '{"sessions":[]}')"

  ALREADY_ACTIVE="$(echo "$ACTIVE_SESSIONS" | python3 -c '
import json,sys
data=json.load(sys.stdin)
sessions=data.get("sessions",[])
repo=sys.argv[1]; topic=sys.argv[2]
for s in sessions:
    title=s.get("title","") or ""
    r=s.get("repo","") or ""
    if repo in r or repo in title:
        if not topic or topic in title or topic in (s.get("summary","") or ""):
            print("yes"); sys.exit(0)
print("no")
' "$REPO" "$TOPIC_SLUG" 2>/dev/null || echo "no")"

  if [ "$ALREADY_ACTIVE" = "yes" ]; then
    echo "[dispatch-fix] SKIP: active session already exists for ${REPO}/${TOPIC_SLUG}" >&2
    exit 1
  fi
fi

# ── Dry-run ─────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dispatch-fix] DRY-RUN: would dispatch"
  echo "  tmux session: ${SESSION_NAME}"
  echo "  repo: AQaddora/${REPO}"
  echo "  prompt: $(echo "$PROMPT" | head -c 200)..."
  exit 0
fi

# ── Verify aqos-agent exists ─────────────────────────────────────────────────
if [ ! -x "$AQOS_AGENT" ]; then
  echo "[dispatch-fix] ERROR: aqos-agent not found/executable at ${AQOS_AGENT}" >&2
  exit 2
fi

# ── Verify tmux is available ─────────────────────────────────────────────────
if ! command -v tmux >/dev/null 2>&1; then
  echo "[dispatch-fix] ERROR: tmux not found" >&2
  exit 2
fi

# ── Build the sprint prompt ──────────────────────────────────────────────────
SPRINT_PROMPT="You are running as an autonomous fix agent on fatmac.

TASK: ${TITLE}

REPO: AQaddora/${REPO}

INSTRUCTIONS:
${PROMPT}

RULES (non-negotiable):
- Work in repo ~/Work/${REPO}
- Create a feature branch off dev (NOT main): fix/${TOPIC_SLUG}-$(date +%Y%m%d)
- Make ONLY the minimal additive change described above
- Run existing tests if present; do not break them
- Open a DRAFT PR into dev (NOT main) with a clear description of the change
- NEVER deploy, NEVER merge, NEVER push to main directly
- If anything is ambiguous or risky, create the PR with a detailed description and mark it as 'needs-review'

When done, output a one-line summary: PR_URL=<url>"

# ── Launch tmux session ───────────────────────────────────────────────────────
REPO_DIR="${WORK_DIR}/${REPO}"
if [ ! -d "$REPO_DIR" ]; then
  echo "[dispatch-fix] ERROR: repo dir not found: ${REPO_DIR}" >&2
  exit 2
fi

# Kill any old session with the same name (shouldn't exist after dedup, but just in case)
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

# Create session, run aqos-agent, pipe output to a log file
LOG_DIR="${HOME}/.daily-sweeper/dispatches/${DATE}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/${SESSION_NAME}.log"

tmux new-session -d -s "$SESSION_NAME" -c "$REPO_DIR" \
  "AQOS_TASK_TIER=build ${AQOS_AGENT} --dangerously-skip-permissions -p $(printf '%q' "$SPRINT_PROMPT") 2>&1 | tee $(printf '%q' "$LOG_FILE"); echo '[dispatch-fix] done' >> $(printf '%q' "$LOG_FILE")"

echo "[dispatch-fix] dispatched: tmux session '${SESSION_NAME}' for AQaddora/${REPO}" >&2

# ── Register session with spine ───────────────────────────────────────────────
if [ -n "$SECRET" ]; then
  SESSION_KEY="fatmac:dispatch:${SESSION_NAME}"
  REGISTER_BODY="$(python3 -c '
import json,sys
print(json.dumps({
  "session_key": sys.argv[1],
  "machine": "fatmac",
  "project": sys.argv[2],
  "repo": sys.argv[3],
  "branch": "fix/'${TOPIC_SLUG}'-$(date +%Y%m%d)",
  "status": "active",
  "title": sys.argv[4],
  "summary": "Auto-dispatched by daily-sweeper: " + sys.argv[4],
  "cwd": sys.argv[5]
}))
' "$SESSION_KEY" "daily-sweeper-dispatch" "$REPO" "$TITLE" "$REPO_DIR" 2>/dev/null || echo "{}")"

  curl -fsS --max-time 8 -X POST "${API}/api/internal/session" \
    -H "Content-Type: application/json" \
    -H "x-internal-secret: ${SECRET}" \
    -d "$REGISTER_BODY" >/dev/null 2>&1 || true
fi

echo "$SESSION_NAME"
exit 0
