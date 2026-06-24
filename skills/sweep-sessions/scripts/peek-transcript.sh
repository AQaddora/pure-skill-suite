#!/usr/bin/env bash
# peek-transcript.sh — locate a Claude Code transcript by uuid and print a short
# text slice of its user/assistant messages, so the maestro can infer what a
# bare null-title session is actually doing. Best-effort: prints nothing if the
# transcript isn't found locally. Remote machines are handled by the caller (ssh).
set -u

UUID="" MAX=1500
ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --uuid) UUID="$2"; shift 2;;
    --root) ROOTS+=("$2"); shift 2;;
    --max)  MAX="$2"; shift 2;;
    *) shift;;
  esac
done
[ -z "$UUID" ] && { echo "usage: peek-transcript.sh --uuid <uuid> [--root DIR] [--max N]" >&2; exit 2; }

# Default search roots: both known Claude homes.
if [ "${#ROOTS[@]}" -eq 0 ]; then
  ROOTS=("$HOME/.claude/projects" "$HOME/.claude-roza/projects")
fi

FILE=""
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  found="$(find "$root" -name "${UUID}.jsonl" -type f 2>/dev/null | head -1)"
  [ -n "$found" ] && { FILE="$found"; break; }
done
[ -z "$FILE" ] && exit 0  # best-effort: nothing to peek

# Extract message text: content is either a string or an array of {type,text} parts.
jq -r '
  select(.message.content != null)
  | if (.message.content | type) == "string"
    then .message.content
    else (.message.content[]? | select(.type == "text") | .text)
    end
' "$FILE" 2>/dev/null | head -c "$MAX"
