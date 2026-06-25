#!/usr/bin/env bash
# dimensions/wa-threads.sh — WhatsApp client + dev thread probe
#
# Attempts to read WA archive via the internal HTTP API. The WA archive is
# currently only exposed through the MCP server (interactive sessions), not
# via a standalone internal endpoint.
#
# In headless mode: SKIPS with a clear FLAG. Does NOT crash.
# In interactive mode (MCP available): this script is bypassed — use the MCP
# wa_list_chats / wa_read_chat tools directly.
#
# If a /api/internal/wa-archive endpoint is added in the future, wire it here
# and remove the SKIPPED emit.
#
# Receives: $1 = project JSON blob
# Outputs:  JSON lines (same schema as prs.sh)

set -uo pipefail

PROJECT_JSON="${1:-}"
if [ -z "$PROJECT_JSON" ]; then
  echo '{"dimension":"wa-threads","severity":"blocked","title":"wa-threads.sh: no project JSON","detail":"called without argument","repo":"","topic":"wa-error","dispatch_prompt":""}' >&2
  exit 0
fi

emit() {
  local sev="$1" repo="$2" topic="$3" title="$4" detail="$5" dprompt="$6"
  python3 -c '
import json, sys
d={"dimension":"wa-threads","severity":sys.argv[1],"repo":sys.argv[2],"topic":sys.argv[3],
   "title":sys.argv[4],"detail":sys.argv[5],"dispatch_prompt":sys.argv[6]}
print(json.dumps(d))
' "$sev" "$repo" "$topic" "$title" "$detail" "$dprompt"
}

API="${AQOS_API:-https://api.aqaddoura.com}"
SECRET="${AQOS_INTERNAL_SECRET:-}"
[ -z "$SECRET" ] && [ -f "${HOME}/.aqos/secret" ] && SECRET="$(tr -d '\n\r' < "${HOME}/.aqos/secret")"

PROJECT_NAME="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || echo "")"
REPOS="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; p=json.load(sys.stdin); [print(r) for r in p.get("repos",[])]' 2>/dev/null || echo "")"
PRIMARY_REPO="$(echo "$REPOS" | head -1)"

# ── Check if a /api/internal/wa-archive endpoint exists ──────────────────────
# Try a HEAD request with a short timeout. If 404/405, we know it doesn't exist.
# (This avoids hardcoding "it doesn't exist" — auto-discovers when it's added.)
WA_ENDPOINT="${API}/api/internal/wa-archive"
HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  -X HEAD "$WA_ENDPOINT" \
  -H "x-internal-secret: ${SECRET}" 2>/dev/null || echo "000")"

if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "405" ]; then
  # Endpoint exists (405 = method not allowed means it exists but HEAD isn't supported)
  # Future: implement full WA archive query here
  emit "flagged" "$PRIMARY_REPO" "wa-threads-not-impl" \
    "${PROJECT_NAME}: /api/internal/wa-archive endpoint found but wa-threads.sh not yet implemented for it" \
    "Wire the WA archive query in dimensions/wa-threads.sh" ""
elif [ "$HTTP_STATUS" = "401" ]; then
  emit "blocked" "$PRIMARY_REPO" "wa-threads-auth-fail" \
    "${PROJECT_NAME}: wa-archive auth failed (401)" \
    "Check AQOS_INTERNAL_SECRET / ~/.aqos/secret" ""
else
  # 404, 000 (timeout/unreachable), or other — endpoint doesn't exist
  WA_CONTACTS="$(echo "$PROJECT_JSON" | python3 -c '
import json,sys
p=json.load(sys.stdin)
wc=p.get("wa_contacts",{})
clients=wc.get("client",[])
devs=wc.get("dev",[]) or wc.get("devs",[])
all_contacts=clients+devs
print(", ".join(all_contacts) if all_contacts else "(none configured)")
' 2>/dev/null || echo "(unknown)")"

  emit "flagged" "$PRIMARY_REPO" "wa-threads-skipped" \
    "${PROJECT_NAME}: wa-threads SKIPPED — no /api/internal/wa-archive endpoint" \
    "WA archive is only accessible via MCP (interactive sessions). Contacts configured: ${WA_CONTACTS}. TODO: add /api/internal/wa-archive to the spine so this dimension works headlessly." ""
fi
