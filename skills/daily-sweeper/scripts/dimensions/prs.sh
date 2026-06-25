#!/usr/bin/env bash
# dimensions/prs.sh — PR / CI / deploy status probe
#
# Receives: $1 = project JSON blob (from projects.json entry)
# Outputs:  JSON lines to stdout — one finding per line:
#   {"dimension":"prs","severity":"safe_fix|blocked|flagged|info",
#    "title":"...","detail":"...","repo":"...","topic":"...","dispatch_prompt":"..."}
#
# Severity guide:
#   safe_fix  → auto-dispatch candidate (additive, single-repo, no deploy)
#   blocked   → needs Ahmed (deploy, coordination, product decision)
#   flagged   → informational, no action needed now
#   info      → clean / all-good

set -uo pipefail

PROJECT_JSON="${1:-}"
if [ -z "$PROJECT_JSON" ]; then
  echo '{"dimension":"prs","severity":"blocked","title":"prs.sh: no project JSON","detail":"called without argument","repo":"","topic":"prs-error","dispatch_prompt":""}' >&2
  exit 0
fi

WORK_DIR="${HOME}/Work"

emit() {
  # emit <severity> <repo> <topic> <title> <detail> <dispatch_prompt>
  local sev="$1" repo="$2" topic="$3" title="$4" detail="$5" dprompt="$6"
  python3 -c '
import json, sys
d={"dimension":"prs","severity":sys.argv[1],"repo":sys.argv[2],"topic":sys.argv[3],
   "title":sys.argv[4],"detail":sys.argv[5],"dispatch_prompt":sys.argv[6]}
print(json.dumps(d))
' "$sev" "$repo" "$topic" "$title" "$detail" "$dprompt"
}

# Parse repos from project JSON
REPOS="$(echo "$PROJECT_JSON" | python3 -c 'import json,sys; p=json.load(sys.stdin); [print(r) for r in p.get("repos",[])]' 2>/dev/null)"
if [ -z "$REPOS" ]; then
  emit "info" "" "prs-no-repos" "No repos configured" "Add repos[] to projects.json" ""
  exit 0
fi

# Check gh is available
if ! command -v gh >/dev/null 2>&1; then
  emit "blocked" "" "prs-no-gh" "gh CLI not found" "Install GitHub CLI to enable PR dimension" ""
  exit 0
fi

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  REPO_DIR="${WORK_DIR}/${repo}"

  if [ ! -d "$REPO_DIR" ]; then
    emit "flagged" "$repo" "prs-no-local" "Repo not cloned locally: ${repo}" "Clone ${repo} to ${WORK_DIR}/${repo} to enable PR scanning" ""
    continue
  fi

  # ── Open PRs ──────────────────────────────────────────────────────────────
  PR_JSON="$(gh pr list --repo "AQaddora/${repo}" --json number,title,baseRefName,headRefName,author,isDraft,reviewDecision,statusCheckRollup --limit 30 2>/dev/null || echo "[]")"

  if [ "$PR_JSON" = "[]" ] || [ -z "$PR_JSON" ]; then
    emit "info" "$repo" "prs-clean" "No open PRs in ${repo}" "" ""
    continue
  fi

  # ── GitFlow violation: PRs targeting main (should target dev) ─────────────
  MAIN_TARGETS="$(echo "$PR_JSON" | python3 -c '
import json,sys
prs=json.load(sys.stdin)
bad=[p for p in prs if p.get("baseRefName","")=="main" and not p.get("isDraft",False)]
for p in bad:
    print(f"{p[\"number\"]}|{p[\"title\"]}|{p[\"headRefName\"]}")
' 2>/dev/null || echo "")"

  if [ -n "$MAIN_TARGETS" ]; then
    while IFS='|' read -r pr_num pr_title head_ref; do
      [ -z "$pr_num" ] && continue
      emit "safe_fix" "$repo" "gitflow-violation-pr${pr_num}" \
        "PR #${pr_num} targets main (GitFlow violation): ${pr_title}" \
        "Head: ${head_ref} → base: main. Should target dev. Carries work that is NOT on dev/staging yet." \
        "In repo AQaddora/${repo}: PR #${pr_num} ('${pr_title}') has base=main, violating GitFlow. Change its base to 'dev'. Also verify the work is on the dev branch or cherry-pick it. Create a draft PR for this re-route. Do NOT merge — just re-target the base and leave it as a draft for Ahmed to review."
    done <<< "$MAIN_TARGETS"
  fi

  # ── PRs merged to dev but not yet on main (built, not deployed) ───────────
  DEV_SHA="$(cd "$REPO_DIR" && git rev-parse origin/dev 2>/dev/null || echo "")"
  MAIN_SHA="$(cd "$REPO_DIR" && git rev-parse origin/main 2>/dev/null || echo "")"

  if [ -n "$DEV_SHA" ] && [ -n "$MAIN_SHA" ]; then
    UNDEPLOYED="$(cd "$REPO_DIR" && git log --oneline "origin/main..origin/dev" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${UNDEPLOYED:-0}" -gt 0 ]; then
      COMMITS_PREVIEW="$(cd "$REPO_DIR" && git log --oneline "origin/main..origin/dev" 2>/dev/null | head -5)"
      emit "flagged" "$repo" "dev-ahead-of-main" \
        "${repo}: ${UNDEPLOYED} commit(s) on dev not yet on main (not deployed)" \
        "$(echo "$COMMITS_PREVIEW")" ""
    fi
  fi

  # ── Red CI / failing deploy runs ──────────────────────────────────────────
  FAILING_RUNS="$(gh run list --repo "AQaddora/${repo}" --status failure --limit 5 --json databaseId,name,headBranch,displayTitle,conclusion,createdAt 2>/dev/null || echo "[]")"
  FAIL_COUNT="$(echo "$FAILING_RUNS" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(len(r))' 2>/dev/null || echo "0")"

  if [ "${FAIL_COUNT:-0}" -gt 0 ]; then
    FAIL_DETAILS="$(echo "$FAILING_RUNS" | python3 -c '
import json,sys
runs=json.load(sys.stdin)
for r in runs[:3]:
    print(f"[{r[\"headBranch\"]}] {r[\"displayTitle\"]} ({r[\"conclusion\"]})")
' 2>/dev/null || echo "see CI")"
    emit "blocked" "$repo" "ci-red" \
      "${repo}: ${FAIL_COUNT} failing CI/deploy run(s)" \
      "$FAIL_DETAILS" ""
  fi

  # ── PRs waiting for review (no review decision, author != Ahmed) ──────────
  WAITING="$(echo "$PR_JSON" | python3 -c '
import json,sys
prs=json.load(sys.stdin)
waiting=[p for p in prs
  if not p.get("isDraft",False)
  and p.get("reviewDecision","") in ("","REVIEW_REQUIRED")
  and p.get("author",{}).get("login","").lower() not in ("aqaddora","ahmedqaddoura")]
for p in waiting:
    print(f"#{p[\"number\"]} {p[\"title\"]} — by {p[\"author\"].get(\"login\",\"?\")}")
' 2>/dev/null || echo "")"

  if [ -n "$WAITING" ]; then
    emit "blocked" "$repo" "pr-needs-review" \
      "${repo}: PR(s) waiting for your review" \
      "$WAITING" ""
  fi

done <<< "$REPOS"
