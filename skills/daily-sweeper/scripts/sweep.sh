#!/usr/bin/env bash
# sweep.sh — daily-sweeper orchestrator
#
# Usage:
#   sweep.sh [--dry-run] [--only <project-name>]
#
# --dry-run    : prints the digest + would-write sweep files; no WA send,
#                no board writes, no dispatches.
# --only <name>: process only the named project from projects.json.
#
# Processing: 2 projects in parallel (BATCH_SIZE).
# Each project runs all 5 dimension scripts in parallel, collects findings,
# classifies them, dispatches safe fixes, and writes a per-project digest.
# After all projects, sends one WA digest to Ahmed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIM_DIR="${SCRIPT_DIR}/dimensions"
DISPATCH_SCRIPT="${SCRIPT_DIR}/dispatch-fix.sh"
PROJECTS_JSON="${SKILL_DIR}/config/projects.json"

DRY_RUN=0
ONLY_PROJECT=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

# Handle --only with its value
i=1
for arg in "$@"; do
  if [ "$arg" = "--only" ]; then
    ARGS=("$@")
    ONLY_PROJECT="${ARGS[$i]:-}"
  fi
  i=$((i + 1))
done

# ── Config ──────────────────────────────────────────────────────────────────
API="${AQOS_API:-https://api.aqaddoura.com}"
SECRET="${AQOS_INTERNAL_SECRET:-}"
[ -z "$SECRET" ] && [ -f "${HOME}/.aqos/secret" ] && SECRET="$(tr -d '\n\r' < "${HOME}/.aqos/secret")"

DATE="$(date +%Y-%m-%d)"
SWEEPS_ROOT="${HOME}/.daily-sweeper/sweeps"
BATCH_SIZE=2
LOG_PREFIX="[daily-sweeper ${DATE}]"

log() { echo "${LOG_PREFIX} $*" >&2; }

# ── Helpers ──────────────────────────────────────────────────────────────────

# Run one project: all 5 dimensions in parallel, collect findings JSON array
sweep_project() {
  local project_json="$1"
  local project_name findings_file tmp_dir

  project_name="$(echo "$project_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name","unknown"))' 2>/dev/null || echo "unknown")"
  tmp_dir="$(mktemp -d "/tmp/sweep-${project_name}-XXXXXX")"
  findings_file="${tmp_dir}/findings.jsonl"
  touch "$findings_file"

  log "→ ${project_name}: running dimensions in parallel"

  # Run each dimension script in background, collect output
  local pids=()
  local dim_scripts=("prs" "prod-logs" "wa-threads" "todos-health" "board")

  for dim in "${dim_scripts[@]}"; do
    local dim_script="${DIM_DIR}/${dim}.sh"
    if [ ! -x "$dim_script" ]; then
      echo "{\"dimension\":\"${dim}\",\"severity\":\"flagged\",\"repo\":\"\",\"topic\":\"dim-missing\",\"title\":\"${dim}.sh not executable\",\"detail\":\"chmod +x ${dim_script}\",\"dispatch_prompt\":\"\"}" \
        >> "$findings_file"
      continue
    fi

    # board.sh gets existing findings too (for task creation) — but in parallel
    # we can't provide them yet; pass empty array for now. Board gets called
    # again in a second pass if needed. For now: parallel first pass.
    (
      if [ "$dim" = "board" ]; then
        "$dim_script" "$project_json" "[]" >> "$findings_file" 2>/dev/null || true
      else
        "$dim_script" "$project_json" >> "$findings_file" 2>/dev/null || true
      fi
    ) &
    pids+=("$!")
  done

  # Wait for all dimensions
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  log "← ${project_name}: dimensions complete"

  # ── Parse findings ─────────────────────────────────────────────────────────
  local findings_json
  findings_json="$(python3 -c '
import json,sys
lines=[]
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: lines.append(json.loads(line))
    except json.JSONDecodeError: pass
print(json.dumps(lines))
' < "$findings_file" 2>/dev/null || echo "[]")"

  # ── Write per-project sweep file ───────────────────────────────────────────
  local sweep_dir="${SWEEPS_ROOT}/${project_name}"
  local sweep_file="${sweep_dir}/${DATE}.md"

  write_sweep_md() {
    local pname="$1"
    local fjson="$2"
    local sfile="$3"
    python3 -c '
import json,sys,os

pname=sys.argv[1]
findings=json.loads(sys.argv[2])
sfile=sys.argv[3]

dims=["prs","prod-logs","wa-threads","todos-health","board"]
dim_labels={"prs":"PRs / CI","prod-logs":"Prod Call Quality","wa-threads":"WhatsApp Threads","todos-health":"TODOs / Staging Health","board":"AQ Backoffice Board"}

os.makedirs(os.path.dirname(sfile), exist_ok=True)

lines=[f"# {pname} — Sweep {sys.argv[4]}", ""]
for dim in dims:
    lines.append(f"## {dim_labels.get(dim,dim)}")
    dfindings=[f for f in findings if f.get("dimension")==dim]
    if not dfindings:
        lines.append("*No findings.*")
    else:
        for f in dfindings:
            sev=f.get("severity","info")
            icon={"safe_fix":"✅","blocked":"🚫","flagged":"⚠️","info":"ℹ️"}.get(sev,"•")
            title=f.get("title","")
            detail=f.get("detail","")
            repo=f.get("repo","")
            lines.append(f"{icon} **[{repo}]** {title}")
            if detail:
                lines.append(f"   > {detail}")
    lines.append("")

with open(sfile,"w") as fp:
    fp.write("\n".join(lines))
print(sfile)
' "$pname" "$fjson" "$sfile" "$DATE" 2>/dev/null
  }

  if [ "$DRY_RUN" -eq 1 ]; then
    log "${project_name}: DRY-RUN sweep file would be written to ${sweep_file}"
    python3 -c '
import json,sys
findings=json.loads(sys.argv[1])
print("\n--- %s findings (%d total) ---" % (sys.argv[2], len(findings)))
for f in findings:
    icon={"safe_fix":"AUTO","blocked":"BLOCK","flagged":"FLAG","info":"INFO"}.get(f.get("severity",""),"    ")
    dim=f.get("dimension","?")
    title=f.get("title","")
    print("  [%s] [%s] %s" % (icon, dim, title))
' "$findings_json" "$project_name" 2>/dev/null || true
  else
    mkdir -p "$sweep_dir"
    write_sweep_md "$project_name" "$findings_json" "$sweep_file" || true
    log "${project_name}: sweep file written: ${sweep_file}"
  fi

  # ── Auto-dispatch safe fixes ───────────────────────────────────────────────
  local dispatched_count=0
  local dispatched_titles=()
  local safe_fixes
  safe_fixes="$(echo "$findings_json" | python3 -c '
import json,sys
findings=json.loads(sys.stdin.read())
for f in findings:
    if f.get("severity")=="safe_fix" and f.get("dispatch_prompt"):
        print(json.dumps(f))
' 2>/dev/null || echo "")"

  while IFS= read -r fix_json; do
    [ -z "$fix_json" ] && continue
    fix_title="$(echo "$fix_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("title",""))' 2>/dev/null || echo "unknown")"

    if [ "$DRY_RUN" -eq 1 ]; then
      log "${project_name}: DRY-RUN would dispatch: ${fix_title}"
      dispatched_titles+=("${fix_title}")
      dispatched_count=$((dispatched_count + 1))
    else
      if bash "$DISPATCH_SCRIPT" "$fix_json" 2>&1 | grep -q "dispatched\|DRY-RUN"; then
        dispatched_titles+=("${fix_title}")
        dispatched_count=$((dispatched_count + 1))
      fi
    fi
  done <<< "$safe_fixes"

  # ── Build project digest section ──────────────────────────────────────────
  python3 -c '
import json,sys

project_name=sys.argv[1]
findings=json.loads(sys.argv[2])
dispatched=json.loads(sys.argv[3])
dispatched_count=int(sys.argv[4])

blocked=[f for f in findings if f.get("severity")=="blocked"]
flagged=[f for f in findings if f.get("severity")=="flagged"]
board_findings=[f for f in findings if f.get("dimension")=="board" and f.get("severity")=="info"]

lines=[f"— {project_name} —"]

# Dispatched
if dispatched_count > 0:
    lines.append(f"✅ Auto-dispatched ({dispatched_count}):")
    for t in dispatched:
        lines.append(f"  • {t}")
else:
    lines.append("✅ Auto-dispatched (0): nothing safe to dispatch")

# Blocked
if blocked:
    lines.append("🚫 Blocked on you (%d):" % len(blocked))
    for f in blocked:
        repo=f.get("repo","?")
        title=f.get("title","")
        lines.append("  • [%s] %s" % (repo, title))
else:
    lines.append("🚫 Blocked on you (0): clear")

# Flagged
info_flags=[f for f in flagged if "skipped" not in f.get("topic","").lower() and "ok" not in f.get("topic","").lower()]
if info_flags:
    lines.append("⚠️ Flagged (%d):" % len(info_flags))
    for f in info_flags[:5]:
        repo=f.get("repo","?")
        title=f.get("title","")
        lines.append("  • [%s] %s" % (repo, title))
    if len(info_flags) > 5:
        lines.append("  ... and %d more" % (len(info_flags)-5))

# Board
if board_findings:
    lines.append("🧹 %s" % board_findings[0].get("title","Board updated"))
else:
    skipped=[f for f in findings if f.get("dimension")=="board" and "skipped" in f.get("topic","").lower()]
    if skipped:
        lines.append("🧹 Board: SKIPPED (no internal endpoint — needs MCP)")

print("\n".join(lines))
' "$project_name" "$findings_json" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${dispatched_titles[@]+"${dispatched_titles[@]}"}" 2>/dev/null || echo "[]")" "$dispatched_count" 2>/dev/null

  # Cleanup
  rm -rf "$tmp_dir"
}

# ── Load projects ────────────────────────────────────────────────────────────
if [ ! -f "$PROJECTS_JSON" ]; then
  log "ERROR: projects.json not found at ${PROJECTS_JSON}"
  exit 1
fi

PROJECTS="$(python3 -c '
import json,sys
projects=json.load(open(sys.argv[1]))
only=sys.argv[2]
if only:
    projects=[p for p in projects if p.get("name")==only]
    if not projects:
        print(f"ERROR: project \"{only}\" not found in projects.json", file=sys.stderr)
        sys.exit(1)
for p in projects:
    print(json.dumps(p))
' "$PROJECTS_JSON" "$ONLY_PROJECT" 2>/dev/null)"

if [ -z "$PROJECTS" ]; then
  log "No projects to sweep (check --only value or projects.json)"
  exit 0
fi

# ── Register sweep session with spine ────────────────────────────────────────
SESSION_KEY="fatmac:daily-sweeper:${DATE}"
if [ -n "$SECRET" ] && [ "$DRY_RUN" -eq 0 ]; then
  TMUX_SESSION="daily-sweeper-${DATE}"
  curl -fsS --max-time 8 -X POST "${API}/api/internal/session" \
    -H "Content-Type: application/json" \
    -H "x-internal-secret: ${SECRET}" \
    -d "{\"session_key\":\"${SESSION_KEY}\",\"machine\":\"fatmac\",\"project\":\"daily-sweeper\",\"status\":\"active\",\"title\":\"Daily Sweep ${DATE}\",\"tmux\":\"${TMUX_SESSION:-}\"}" \
    >/dev/null 2>&1 || log "WARN: could not register session (spine unreachable)"
fi

# ── Process projects in batches of BATCH_SIZE ─────────────────────────────────
log "Starting daily sweep (batch_size=${BATCH_SIZE}, dry_run=${DRY_RUN})"

batch_pids=()
batch_idx=0

process_batch() {
  for i in "${!batch_pids[@]}"; do
    wait "${batch_pids[$i]}" 2>/dev/null || true
  done
  batch_pids=()
  batch_idx=0
}

# Collect digest sections from temp files
DIGEST_TMP="$(mktemp /tmp/sweep-digest-XXXXXX)"

while IFS= read -r project_json; do
  [ -z "$project_json" ] && continue

  # Run project sweep in background, capture its stdout (digest section)
  (
    sweep_project "$project_json"
  ) >> "$DIGEST_TMP" &

  batch_pids+=("$!")
  batch_idx=$((batch_idx + 1))

  if [ "$batch_idx" -ge "$BATCH_SIZE" ]; then
    process_batch
  fi

done <<< "$PROJECTS"

# Wait for any remaining batch
if [ "${#batch_pids[@]}" -gt 0 ]; then
  for pid in "${batch_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
fi

# ── Build and send WA digest ─────────────────────────────────────────────────
DIGEST_BODY="$(cat "$DIGEST_TMP" 2>/dev/null || echo "")"
rm -f "$DIGEST_TMP"

WA_MESSAGE="*Daily Sweep — ${DATE}*

${DIGEST_BODY}"

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: WA digest would be:"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$WA_MESSAGE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "DRY-RUN complete — no sends, no dispatches, no board writes"
else
  # Send WA digest via /api/internal/notify-owner
  if [ -n "$SECRET" ]; then
    WA_PAYLOAD="$(python3 -c '
import json,sys
print(json.dumps({"ok":True,"summary":sys.argv[1],"sha":"sweep"}))
' "$WA_MESSAGE" 2>/dev/null || echo "{}")"

    HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
      -X POST "${API}/api/internal/notify-owner" \
      -H "Content-Type: application/json" \
      -H "x-deploy-secret: ${SECRET}" \
      -d "$WA_PAYLOAD" 2>/dev/null || echo "000")"

    if echo "$HTTP_CODE" | grep -qE '^2'; then
      log "WA digest sent (HTTP ${HTTP_CODE})"
    else
      log "WARN: WA digest send failed (HTTP ${HTTP_CODE}) — digest printed to log instead"
      echo "$WA_MESSAGE"
    fi
  else
    log "WARN: no AQOS_INTERNAL_SECRET — WA digest not sent"
    echo "$WA_MESSAGE"
  fi

  # Mark session done
  if [ -n "$SECRET" ]; then
    curl -fsS --max-time 8 -X POST "${API}/api/internal/session" \
      -H "Content-Type: application/json" \
      -H "x-internal-secret: ${SECRET}" \
      -d "{\"session_key\":\"${SESSION_KEY}\",\"status\":\"done\"}" \
      >/dev/null 2>&1 || true
  fi
fi

log "Sweep complete."
