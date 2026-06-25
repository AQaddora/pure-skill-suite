#!/usr/bin/env bash
# dimensions/todos-health.sh — WIP / handoffs / staging health probe
#
# Checks:
#   1. Uncommitted WIP per repo (dirty working tree)
#   2. _handoffs/ status drift (open handoffs > 2 days old)
#   3. AGENTS.md rule violations (checks that file exists + is non-empty)
#   4. Staging HTTP health (2xx = ok, else flagged)
#
# Receives: $1 = project JSON blob
# Outputs:  JSON lines (same schema as prs.sh)

set -uo pipefail

PROJECT_JSON="${1:-}"
if [ -z "$PROJECT_JSON" ]; then
  echo '{"dimension":"todos-health","severity":"blocked","title":"todos-health.sh: no project JSON","detail":"called without argument","repo":"","topic":"todos-error","dispatch_prompt":""}' >&2
  exit 0
fi

WORK_DIR="${HOME}/Work"

emit() {
  local sev="$1" repo="$2" topic="$3" title="$4" detail="$5" dprompt="$6"
  python3 -c '
import json, sys
d={"dimension":"todos-health","severity":sys.argv[1],"repo":sys.argv[2],"topic":sys.argv[3],
   "title":sys.argv[4],"detail":sys.argv[5],"dispatch_prompt":sys.argv[6]}
print(json.dumps(d))
' "$sev" "$repo" "$topic" "$title" "$detail" "$dprompt"
}

PROJECT_NAME="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || echo "")"
REPOS="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; p=json.load(sys.stdin); [print(r) for r in p.get("repos",[])]' 2>/dev/null || echo "")"
STAGING_URL="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; v=json.load(sys.stdin).get("staging_url"); print(v if v else "")' 2>/dev/null || echo "")"
PROD_URL="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; v=json.load(sys.stdin).get("prod_url"); print(v if v else "")' 2>/dev/null || echo "")"

NOW_EPOCH="$(date +%s)"

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  REPO_DIR="${WORK_DIR}/${repo}"

  if [ ! -d "$REPO_DIR" ]; then
    continue
  fi

  # ── Uncommitted WIP ────────────────────────────────────────────────────────
  WIP="$(cd "$REPO_DIR" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${WIP:-0}" -gt 0 ]; then
    WIP_FILES="$(cd "$REPO_DIR" && git status --porcelain 2>/dev/null | head -5)"
    emit "flagged" "$repo" "uncommitted-wip" \
      "${repo}: ${WIP} uncommitted file(s) in working tree" \
      "$WIP_FILES" ""
  fi

  # ── Stale handoffs (open > 48h) ────────────────────────────────────────────
  HANDOFF_DIR="${REPO_DIR}/_handoffs"
  if [ -d "$HANDOFF_DIR" ]; then
    # Find handoffs that are NOT marked done (no "## Status: done" or similar)
    while IFS= read -r hf; do
      [ -z "$hf" ] && continue
      # Check file age
      FILE_MTIME="$(stat -f "%m" "$hf" 2>/dev/null || stat -c "%Y" "$hf" 2>/dev/null || echo "0")"
      AGE_HOURS=$(( (NOW_EPOCH - FILE_MTIME) / 3600 ))
      if [ "$AGE_HOURS" -gt 48 ]; then
        # Check if it's marked done
        if ! grep -qi "status.*done\|done.*status\|## done\|DONE" "$hf" 2>/dev/null; then
          HNAME="$(basename "$hf")"
          emit "flagged" "$repo" "stale-handoff-${HNAME}" \
            "${repo}: stale open handoff (${AGE_HOURS}h): ${HNAME}" \
            "$(head -5 "$hf" 2>/dev/null | tr '\n' ' ')" ""
        fi
      fi
    done < <(find "$HANDOFF_DIR" -maxdepth 2 -name "*.md" 2>/dev/null)
  fi

  # ── AGENTS.md check ────────────────────────────────────────────────────────
  AGENTS_FILE="${REPO_DIR}/AGENTS.md"
  if [ ! -f "$AGENTS_FILE" ]; then
    emit "flagged" "$repo" "no-agents-md" \
      "${repo}: AGENTS.md missing" \
      "Add AGENTS.md with coding rules so automated agents respect repo conventions" ""
  elif [ ! -s "$AGENTS_FILE" ]; then
    emit "flagged" "$repo" "empty-agents-md" \
      "${repo}: AGENTS.md is empty" \
      "Populate AGENTS.md with coding rules for this repo" ""
  fi

done <<< "$REPOS"

# ── Staging health probe ────────────────────────────────────────────────────
probe_url() {
  local url="$1" label="$2" primary_repo="$3"
  [ -z "$url" ] && return
  HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")"
  if echo "$HTTP_CODE" | grep -qE '^[23]'; then
    emit "info" "$primary_repo" "staging-ok" \
      "${label}: staging HTTP ${HTTP_CODE} (healthy)" "" ""
  elif [ "$HTTP_CODE" = "000" ]; then
    emit "blocked" "$primary_repo" "staging-unreachable" \
      "${label}: staging UNREACHABLE (timeout/no-route)" \
      "URL: ${url}" ""
  else
    emit "blocked" "$primary_repo" "staging-error" \
      "${label}: staging returned HTTP ${HTTP_CODE}" \
      "URL: ${url}" ""
  fi
}

PRIMARY_REPO="$(echo "$REPOS" | head -1)"

if [ -n "$STAGING_URL" ]; then
  probe_url "$STAGING_URL" "${PROJECT_NAME} staging" "$PRIMARY_REPO"
else
  emit "flagged" "$PRIMARY_REPO" "no-staging-url" \
    "${PROJECT_NAME}: no staging_url configured — skipping health probe" "" ""
fi

# Also probe prod URL to confirm it's alive (not blocked, just info)
if [ -n "$PROD_URL" ]; then
  PROD_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$PROD_URL" 2>/dev/null || echo "000")"
  if ! echo "$PROD_CODE" | grep -qE '^[23]'; then
    emit "blocked" "$PRIMARY_REPO" "prod-health" \
      "${PROJECT_NAME}: prod URL returned HTTP ${PROD_CODE}" \
      "URL: ${PROD_URL}" ""
  fi
fi
