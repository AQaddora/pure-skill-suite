# daily-sweeper

A fleet-cron "routine maestro" that runs every morning across all of Ahmed's
active projects. It sweeps five surfaces per project, writes a per-project
digest, auto-dispatches *safe* fixes as draft PRs, and escalates everything
that's blocked on Ahmed as a WhatsApp message.

## Purpose

Instead of manually sweeping each project's PRs, CI, WhatsApp threads, staging
health, and board every morning, daily-sweeper does it automatically and tells
you only what needs a human decision.

## Structure

```
skills/daily-sweeper/
├── SKILL.md                   ← you are here
├── config/
│   └── projects.json          ← roster of projects to sweep
├── scripts/
│   ├── sweep.sh               ← orchestrator (entry point)
│   ├── dispatch-fix.sh        ← safe-fix → draft PR dispatcher
│   └── dimensions/
│       ├── prs.sh             ← PRs / CI / deploy status
│       ├── prod-logs.sh       ← live prod call-quality probes
│       ├── wa-threads.sh      ← WhatsApp client + dev threads
│       ├── todos-health.sh    ← WIP / handoffs / staging health
│       └── board.sh           ← AQ Backoffice board cleanup
└── daily-sweeper.plist        ← launchd job (staged; load manually)
```

## Run Protocol

### Full daily run (launchd triggers this)

```bash
~/.claude/skills/daily-sweeper/scripts/sweep.sh
```

### Manual debug run (dry-run, single project)

```bash
~/.claude/skills/daily-sweeper/scripts/sweep.sh --dry-run --only radx
```

`--dry-run`: prints the digest + would-write sweep file; no WA send, no board
writes, no dispatches.

`--only <name>`: limits to a single project from `config/projects.json`.

### Loading the launchd job (Ahmed does this after reviewing the PR)

```bash
cp ~/Work/pure-skill-suite/skills/daily-sweeper/daily-sweeper.plist \
   ~/Library/LaunchAgents/com.aqaddoura.daily-sweeper.plist
launchctl load ~/Library/LaunchAgents/com.aqaddoura.daily-sweeper.plist
```

## Autonomy Rules

These rules are enforced by `dispatch-fix.sh`. They are not adjustable at
runtime — change the rule here and the script picks it up on the next run.

**AUTO-DISPATCH (safe)** — creates a feature branch + draft PR with no human
approval needed. Criteria: single repo, additive-only change, no deploy step,
no product decision required, bounded scope (< 1 day of work).

Examples of safe-dispatch findings:
- A PR targeting the wrong base branch (re-route to `dev`)
- A missing enum value in a tools.py function
- A known-place match logic gap with a clear geofence approach
- A stale Live Activity close path on clean disconnect

**BLOCKED ON YOU** — escalated to Ahmed's WA, never dispatched. Criteria:
- Needs a deploy / prod-box SSH access
- Cross-repo or cross-team coordination
- Product decision (UX, feature scoping)
- Needs device QA before merge (iOS path changes)
- Risky / destructive (force-push, migration, schema change)

**FLAGGED (info only)** — noted in the digest; neither dispatched nor escalated
as blocking. Examples: call-quality regressions with no clear fix yet, WA
threads that are already being handled.

## Headless Reality

The launchd cron has NO interactive claude.ai MCP. All API calls use:

- **Internal HTTP API**: `https://api.aqaddoura.com` with header
  `x-internal-secret` (read from `~/.aqos/secret`)
- Available internal endpoints:
  - `POST /api/internal/session` — register the sweep session
  - `GET /api/internal/sessions?project=X&active=1` — dedup active dispatches
  - `POST /api/internal/notify-owner` — send WA digest to Ahmed
- **WA archive** (`wa_chats`/`wa_messages`): only via MCP in interactive sessions.
  The `wa-threads.sh` dimension SKIPS and flags this in headless mode.
- **AQ Backoffice board** (`lead_tasks`): only via MCP OAuth or admin JWT.
  The `board.sh` dimension SKIPS and flags this in headless mode.

If an endpoint is unavailable, the dimension prints a single `SKIPPED` finding
and continues — it never crashes the whole sweep.

## Dispatch Path (headless, on fatmac)

`dispatch-fix.sh` runs `aqos-agent` directly inside a named tmux session:

```
tmux new-session -d -s "fix-<repo>-<slug>-<date>"
~/.aqos/aqos-agent.sh --dangerously-skip-permissions -p "<prompt>"
```

Dedup: before dispatching, checks `/api/internal/sessions?active=1` for an
existing session whose title matches `<repo>/<topic>`. If one exists, skips.

## Adding a Project

1. Open `config/projects.json`
2. Add a new object to the array:

```json
{
  "name": "my-project",
  "repos": ["repo-name"],
  "staging_url": "https://staging.example.com",
  "prod_url": "https://example.com",
  "prod_box": null,
  "wa_contacts": {
    "client": [],
    "devs": []
  },
  "board_id": null
}
```

3. Fill `prod_box` with the SSH host alias (from `~/.ssh/config`) if prod logs
   should be fetched live. Leave `null` to skip prod-log dimension.
4. No restart needed — `sweep.sh` reads the JSON on every run.

## Output

### Per-project sweep file

Written to `~/.daily-sweeper/sweeps/<project-name>/<date>.md` after each run.

### WhatsApp digest

Sent to Ahmed via `/api/internal/notify-owner`. Format:

```
*Daily Sweep — 2026-06-25*

— radx —
✅ Auto-dispatched (2):
  • radx-agent: re-route PR #62 to dev + livekit pin test
  • radx-agent: add bicycle travel_mode to navigate()

🚫 Blocked on you (1):
  • radx-admin: staging deploy red (missing dev ref on box)

⚠️ Flagged (1):
  • radx-agent: agent spoke the clock in call abc123

🧹 Board: SKIPPED (no internal endpoint — needs MCP)
```
