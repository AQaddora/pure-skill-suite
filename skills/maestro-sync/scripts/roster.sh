#!/usr/bin/env bash
# maestro-sync/roster.sh — the fleet roster: every live session + recent sprint,
# from any device. Run this at session start and BEFORE any dispatch so you never
# duplicate work that's already in motion.
#
#   roster.sh                 # full roster (live sessions + recent sprints + board)
#   roster.sh --json          # raw JSON from the session API (for scripting)
#   roster.sh --match <term>  # highlight rows touching <term> (repo / topic)
#
# Sources (all read-only):
#   GET /api/internal/sessions?active=1   live code sessions (all devices)
#   the shared board AgentHandoffs/SPRINTS.md (sprint ledger)
set -euo pipefail

API="${AQOS_API:-https://api.aqaddoura.com}"
SECRET="$(cat "$HOME/.aqos/secret" 2>/dev/null || true)"
BOARD="${AQOS_SPRINTS_BOARD:-$HOME/Work/AgentHandoffs/SPRINTS.md}"
JSON=0 ; MATCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)  JSON=1; shift;;
    --match) MATCH="${2:-}"; shift 2;;
    *) shift;;
  esac
done

if [[ -z "$SECRET" ]]; then
  echo "⚠️  no ~/.aqos/secret — cannot read the fleet roster. PAUSE; do not blind-dispatch." >&2
  exit 3
fi

raw="$(curl -s -m 12 "$API/api/internal/sessions?active=1&limit=100" \
        -H "x-internal-secret: $SECRET" 2>/dev/null || true)"

if [[ -z "$raw" || "$raw" != \{* ]]; then
  echo "⚠️  roster API unreachable ($API). PAUSE; escalate rather than duplicate-dispatch." >&2
  exit 4
fi

if [[ $JSON -eq 1 ]]; then printf '%s\n' "$raw"; exit 0; fi

echo "── FLEET ROSTER  ($(printf '%s' "$API" | sed 's#https\?://##'))  match='${MATCH:-—}' ──"
MATCH="$MATCH" RAW="$raw" python3 - <<'PY'
import json,os
m=(os.environ.get("MATCH") or "").lower()
try: d=json.loads(os.environ.get("RAW") or "")
except Exception as e:
    print("  (could not parse roster:",e,")"); raise SystemExit(0)
rows=d.get("sessions",[])
if not rows:
    print("  (no live sessions registered)"); raise SystemExit(0)
def hit(r):
    blob=" ".join(str(r.get(k,"")) for k in ("repo","project","branch","title","cwd","machine")).lower()
    return m and m in blob
def is_work(r):
    # a real work session names a repo/branch/title; bare home-dir registrations don't
    return bool(r.get("repo") or r.get("project") or r.get("branch") or r.get("title"))
work=[r for r in rows if is_work(r)]
bare=[r for r in rows if not is_work(r)]
# dedupe work rows on repo+branch (keep freshest), so re-registrations don't spam
seen={}
for r in work:
    k=(str(r.get("repo") or r.get("project")), str(r.get("branch")))
    if k not in seen: seen[k]=r
for r in seen.values():
    flag="‼️ " if hit(r) else "  "
    print(f"{flag}[{r.get('status','?'):<7}] {str(r.get('machine','?')):<12} "
          f"{str(r.get('repo') or r.get('project') or '—'):<24} "
          f"{str(r.get('branch') or '—'):<26} {str(r.get('title') or '')[:46]}")
if bare:
    print(f"  · (+{len(bare)} bare/idle home-dir sessions collapsed)")
hits=[r for r in seen.values() if hit(r)]
if m:
    print()
    if hits: print(f"  ‼️  {len(hits)} live session(s) already touch '{m}'. STEER/ATTACH — do NOT dispatch a duplicate.")
    else:    print(f"  ✓  no live session touches '{m}'. Safe to dispatch a NEW named tmux session.")
PY

# Sprint ledger (human board), if present on this filesystem.
if [[ -f "$BOARD" ]]; then
  echo
  echo "── SPRINT LEDGER (tail)  $BOARD ──"
  tail -n 18 "$BOARD"
fi
