#!/usr/bin/env bash
# sweep.sh — sweep the fleet code-session roster: derive readable titles + tags +
# truthful status, write the cheap-path cleanups back, and emit a peek queue for
# bare fresh rows the maestro will name from their transcripts. Fail-soft.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
API="${AQOS_API:-https://api.aqaddoura.com}"
SECRET="${AQOS_INTERNAL_SECRET:-}"
[ -z "$SECRET" ] && [ -f "$HOME/.aqos/secret" ] && SECRET="$(tr -d '\n\r' < "$HOME/.aqos/secret")"

post_session() { # $1=json body
  curl -fsS -X POST "$API/api/internal/session" \
    -H "content-type: application/json" \
    -H "x-internal-secret: $SECRET" \
    --data "$1" >/dev/null
}

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

cmd_write() {
  local key="" title="" summary="" status=""
  while [ $# -gt 0 ]; do case "$1" in
    --key) key="$2"; shift 2;; --title) title="$2"; shift 2;;
    --summary) summary="$2"; shift 2;; --status) status="$2"; shift 2;;
    *) shift;; esac; done
  [ -z "$key" ] && { echo "write: --key required" >&2; return 2; }
  [ -z "$SECRET" ] && { echo "write: no secret — skipping" >&2; return 1; }
  local body="{\"session_key\":$(json_str "$key")"
  [ -n "$title" ]   && body="$body,\"title\":$(json_str "$title")"
  [ -n "$summary" ] && body="$body,\"summary\":$(json_str "$summary")"
  [ -n "$status" ]  && body="$body,\"status\":$(json_str "$status")"
  body="$body}"
  post_session "$body"
}

cmd_sweep() {
  local dry="" input="" now=""
  while [ $# -gt 0 ]; do case "$1" in
    --dry-run) dry=1; shift;; --input) input="$2"; shift 2;;
    --now) now="$2"; shift 2;; *) shift;; esac; done

  local roster
  if [ -n "$input" ]; then
    roster="$(cat "$input")"
  else
    [ -z "$SECRET" ] && { echo "sweep: no secret — cannot reach roster" >&2; return 1; }
    roster="$(curl -fsS "$API/api/internal/sessions" -H "x-internal-secret: $SECRET")"
  fi

  local now_arg=()
  [ -n "$now" ] && now_arg=(--now "$now")
  local plans
  plans="$(printf '%s' "$roster" | python3 "$HERE/derive.py" ${now_arg[@]+"${now_arg[@]}"})"

  local peek_out="${SWEEP_PEEK_OUT:-/tmp/sweep-peek.json}"
  local n=0 r=0 i=0 s=0 p=0
  : > "$peek_out.tmp"

  # Walk each plan as a compact JSON line.
  while IFS= read -r plan; do
    [ -z "$plan" ] && continue
    n=$((n+1))
    local action key title summary status
    action="$(printf '%s' "$plan" | jq -r '.action')"
    key="$(printf '%s' "$plan" | jq -r '.session_key')"
    title="$(printf '%s' "$plan" | jq -r '.title // ""')"
    summary="$(printf '%s' "$plan" | jq -r '.summary // ""')"
    status="$(printf '%s' "$plan" | jq -r '.status // ""')"
    case "$action" in
      skip) s=$((s+1));;
      rename)
        r=$((r+1))
        if [ -n "$dry" ]; then
          echo "RENAME $key → $title  [$status]"
        else
          cmd_write --key "$key" --title "$title" --summary "$summary" ${status:+--status "$status"}
        fi;;
      idle)
        i=$((i+1))
        if [ -n "$dry" ]; then
          echo "IDLE   $key → ${title:-<keep>}  [idle]"
        else
          cmd_write --key "$key" ${title:+--title "$title"} ${summary:+--summary "$summary"} --status "${status:-idle}"
        fi;;
      peek)
        p=$((p+1))
        local uuid slice
        uuid="${key#claude:}"
        slice="$(bash "$HERE/peek-transcript.sh" --uuid "$uuid" 2>/dev/null)"
        printf '%s\n' "$(printf '%s' "$plan" | jq --arg sl "$slice" '. + {slice:$sl}')" >> "$peek_out.tmp"
        [ -n "$dry" ] && echo "PEEK   $key (slice ${#slice} chars)";;
    esac
  done < <(printf '%s' "$plans" | jq -c '.plans[]')

  jq -s '{peek: .}' "$peek_out.tmp" > "$peek_out" 2>/dev/null || echo '{"peek":[]}' > "$peek_out"
  rm -f "$peek_out.tmp"

  echo "swept $n: $r renamed · $i tagged idle · $s already clean · $p peek-queued"
}

case "${1:-}" in
  sweep) shift; cmd_sweep "$@";;
  write) shift; cmd_write "$@";;
  *) echo "usage: sweep.sh {sweep|write} [...]" >&2; exit 2;;
esac
