#!/usr/bin/env bash
# dimensions/prod-logs.sh — live prod call-quality probe
#
# Tries to access prod conversation transcripts. Access path priority:
#   1. prod_box SSH (if configured and key is present)
#   2. Internal API transcript endpoint (if one exists — currently none, FLAG)
#   3. SKIP with reason
#
# Scans for known radx failure signatures. Extend SIGNATURES for other projects.
#
# Receives: $1 = project JSON blob
# Outputs:  JSON lines (same schema as prs.sh)

set -uo pipefail

PROJECT_JSON="${1:-}"
if [ -z "$PROJECT_JSON" ]; then
  echo '{"dimension":"prod-logs","severity":"blocked","title":"prod-logs.sh: no project JSON","detail":"called without argument","repo":"","topic":"prod-logs-error","dispatch_prompt":""}' >&2
  exit 0
fi

emit() {
  local sev="$1" repo="$2" topic="$3" title="$4" detail="$5" dprompt="$6"
  python3 -c '
import json, sys
d={"dimension":"prod-logs","severity":sys.argv[1],"repo":sys.argv[2],"topic":sys.argv[3],
   "title":sys.argv[4],"detail":sys.argv[5],"dispatch_prompt":sys.argv[6]}
print(json.dumps(d))
' "$sev" "$repo" "$topic" "$title" "$detail" "$dprompt"
}

PROJECT_NAME="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || echo "")"
PROD_BOX="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; v=json.load(sys.stdin).get("prod_box"); print(v if v else "")' 2>/dev/null || echo "")"
REPOS="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; p=json.load(sys.stdin); [print(r) for r in p.get("repos",[])]' 2>/dev/null || echo "")"
PRIMARY_REPO="$(echo "$REPOS" | head -1)"

# Known failure signatures to grep for. Format: "grep_pattern|human_label"
# Extend this list as new signatures are discovered in production.
SIGNATURES=(
  "spoke.*time\|current time\|what time\|the time is|agent spoke the clock"
  "neighbourhood\|neighborhood|wrong-neighbourhood guess"
  "travel_mode\|bicycle\|route.*fail|route/travel-mode miss"
  "live.activity\|LiveActivity\|stale.*activity|stale Live Activity"
)
SIG_LABELS=(
  "agent spoke the clock/time"
  "wrong-neighbourhood guess"
  "route/travel-mode miss"
  "stale Live Activity not closing"
)

# ── Try prod_box SSH ──────────────────────────────────────────────────────────
if [ -n "$PROD_BOX" ]; then
  # Quick connectivity test (timeout 5s)
  if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
       "$PROD_BOX" "echo ok" >/dev/null 2>&1; then

    # Fetch last 200 lines of the agent log (adapt path per project)
    AGENT_LOG_PATH="/var/log/${PROJECT_NAME}/agent.log"
    LOG_LINES="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$PROD_BOX" \
      "tail -200 ${AGENT_LOG_PATH} 2>/dev/null || echo LOGFILE_NOT_FOUND" 2>/dev/null || echo "SSH_READ_FAILED")"

    if echo "$LOG_LINES" | grep -q "LOGFILE_NOT_FOUND\|SSH_READ_FAILED"; then
      emit "flagged" "$PRIMARY_REPO" "prod-logs-no-logfile" \
        "${PROJECT_NAME}: prod_box reachable but log not found at ${AGENT_LOG_PATH}" \
        "Update prod-logs.sh with the correct log path for ${PROJECT_NAME}" ""
    else
      FOUND_ANY=0
      for i in "${!SIGNATURES[@]}"; do
        SIG="${SIGNATURES[$i]}"
        LABEL="${SIG_LABELS[$i]}"
        MATCH="$(echo "$LOG_LINES" | grep -iE "$SIG" | tail -3 || echo "")"
        if [ -n "$MATCH" ]; then
          FOUND_ANY=1
          EXAMPLE_ID="$(echo "$MATCH" | grep -oE 'call[_-]?id[=: ]+[a-z0-9_-]+|session[=: ]+[a-z0-9_-]+' | head -1 || echo "see log")"
          emit "flagged" "$PRIMARY_REPO" "prod-sig-${i}" \
            "${PROJECT_NAME}: call quality — ${LABEL}" \
            "Example: ${EXAMPLE_ID:-$(echo "$MATCH" | head -1 | cut -c1-120)}" ""
        fi
      done
      if [ "$FOUND_ANY" -eq 0 ]; then
        emit "info" "$PRIMARY_REPO" "prod-logs-clean" \
          "${PROJECT_NAME}: no known failure signatures in last 200 log lines" "" ""
      fi
    fi
  else
    emit "flagged" "$PRIMARY_REPO" "prod-box-unreachable" \
      "${PROJECT_NAME}: prod_box '${PROD_BOX}' unreachable (SSH timeout)" \
      "Check ~/.ssh/config alias '${PROD_BOX}' and SSH key auth" ""
  fi
else
  # No prod_box configured — no other headless transcript access exists
  emit "flagged" "$PRIMARY_REPO" "prod-logs-skipped" \
    "${PROJECT_NAME}: prod-logs SKIPPED — no prod_box configured" \
    "Set prod_box in config/projects.json to an SSH host alias for live log access. Internal API has no transcript endpoint yet (TODO)." ""
fi
