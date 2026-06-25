#!/usr/bin/env bash
# launch-wrapper.sh — called by launchd to start the daily sweep inside tmux
# This wrapper exists so the plist stays XML-clean (no shell operators to escape).

set -uo pipefail

DATE="$(date +%Y-%m-%d)"
SESSION="daily-sweeper-${DATE}"
LOG_DIR="${HOME}/.daily-sweeper"
LOG_FILE="${LOG_DIR}/${DATE}.log"
SKILL_DIR="${HOME}/.claude/skills/daily-sweeper"
SWEEP="${SKILL_DIR}/scripts/sweep.sh"

mkdir -p "${LOG_DIR}"

# If tmux session already exists (manual re-run same day), skip
if /opt/homebrew/bin/tmux has-session -t "${SESSION}" 2>/dev/null; then
  echo "[daily-sweeper] session ${SESSION} already running — skipping" >> "${LOG_FILE}"
  exit 0
fi

# Verify sweep script exists
if [ ! -x "${SWEEP}" ]; then
  echo "[daily-sweeper] ERROR: sweep.sh not found/executable at ${SWEEP}" >> "${LOG_FILE}"
  exit 1
fi

# Launch sweep inside a named tmux session
/opt/homebrew/bin/tmux new-session -d -s "${SESSION}" \
  "/bin/bash -l '${SWEEP}' >> '${LOG_FILE}' 2>&1; echo '[daily-sweeper] done ${SESSION}' >> '${LOG_FILE}'"

echo "[daily-sweeper] launched tmux session ${SESSION}" >> "${LOG_FILE}"
