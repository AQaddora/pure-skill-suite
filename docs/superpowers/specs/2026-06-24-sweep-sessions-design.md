# sweep-sessions — design

**Date:** 2026-06-24
**Repo:** pure-skill-suite (`skills/sweep-sessions/`)
**Status:** approved design, pending implementation plan
**Owner:** Ahmed Qaddoura (AQaddoura OS — PRIVATE)

## Problem

The code-session registry on the spine (`code_sessions` table, surfaced in the Ops
Room and to the WhatsApp owner agent) is the OS's shared view of "what is running
across the fleet." In practice it is flooded with unreadable rows:

- Bare `claude:<uuid>` sessions with `title:null`, `repo:null`,
  `project:"AhmedQaddoura"` (home-dir Claude Code sessions that never got named).
- Rows still marked `status:active` whose heartbeat is hours or days old.
- These sit next to the well-named `maestro-*` / `handoff-*` / `agent:*` rows and
  drown them out.

The owner agent and the Ops Room both read this registry, so the noise degrades
every "what's running on X?" answer and makes the room hard to scan.

**Goal:** a maestro skill that sweeps the whole roster, gives every cluttered row a
readable title + a category tag + a truthful status, and writes the cleanups back —
on demand, auto-applied, with a single notify digest. Never clobbers a good name.

## Non-goals

- No schema migration. Works entirely through the existing API and columns.
- Not a scheduled cron (on-demand only for v1; cron can wrap it later).
- Not a roster/dispatch tool — it does not decide what work runs, only how the
  registry reads. Complements `maestro-sync`, does not replace it.

## Data path (no schema change)

- **Read:** `GET /api/internal/sessions` (all rows, not just `active=1`), header
  `x-internal-secret` from `~/.aqos/secret`, API `https://api.aqaddoura.com`.
- **Write:** `POST /api/internal/session` with the row's existing `session_key`
  plus the new `title` / `summary` / `status`. The server's upsert
  (`registerSession` in `server/lib/codeSessions.js`) overwrites **only non-null
  fields** (`COALESCE(?, col)`), so a write touches exactly the fields sent and
  preserves the rest. Renames are therefore safe and idempotent.
- **Auth/transport:** reuse the curl pattern from `aqos-register-session.sh`
  (or call that script directly with `--key/--title/--summary/--status`).

### Metadata encoding (no tag column exists)

Available columns: `machine, project, repo, cwd, branch, status, title, summary,
links_json`. Tags ride along without a migration:

- **Category** → emoji prefix on `title`.
- **Secondary tags** → a `tags: …` line appended to `summary` (NOT `links_json`,
  which the Ops Room renders as clickable links — abusing it would pollute the UI).

Example swept row:

```
title:   🛠 taqat-academy · SEO OG metadata
summary: feat/seo-og-metadata on staging
         tags: build · brightgaza · frontend
status:  active
```

## Category taxonomy

Emoji prefix on title, one per row:

| Emoji | Category    | Heuristic |
|-------|-------------|-----------|
| 🛠    | build       | `feat/*`, active dev with a repo |
| 🚀    | deploy      | `deploy/*`, `release/*`, deploy/ops branches |
| 🔎    | research    | research/investigation cwd or transcript intent |
| 🎨    | design      | design/UX repos or branches |
| 🧹    | chore       | `fix/*`, `chore/*`, maintenance |
| 🤝    | handoff     | `handoff-*` rows (already named — usually skipped) |
| 💤    | idle-noise  | bare null-title row, stale, no inferable intent |

Secondary `tags:` come from a repo→project map (brightgaza, radx, otlobli, aqaddoura,
…), the `machine`, and the branch kind.

## Classify → act (per row)

1. **Already clean** — `title` is non-null and human-meaningful (`maestro-*`,
   `handoff-*`, `agent:*`, or any title that isn't the raw `session_key`).
   → **Skip.** Guarantees idempotency and never overwrites a good name.

2. **Structured row** — has `repo` and/or `branch`. → **Cheap derive** (no token
   spend): title from `<repo> · <branch-intent>` where branch-intent is the branch
   slug de-kebabed and prefix-stripped (`feat/seo-og-metadata` → "SEO OG metadata").
   Category + tags from repo map and branch kind.

3. **Bare null-title row** — `repo:null`, home cwd, `title:null`:
   - **Fresh** (heartbeat within 20 min — matching the registry's own
     `liveContext` freshness window) → **deep-peek**: locate the
     session transcript and read a slice to infer real intent, then name it.
     - Transcript location: `<uuid>` comes from `session_key` (`claude:<uuid>`);
       the file is `<uuid>.jsonl` under the Claude projects dir for that `cwd`
       (`machine:here` → local; `fatmac`/`droplet` → over SSH via the `mydroplet`
       ProxyJump). Glob for `**/<uuid>.jsonl` if the exact encoded path is unknown.
     - Best-effort: if the transcript is unreachable, fall back to step 3-stale.
   - **Stale** → don't spend tokens: tag 💤 `idle-noise`, set `status:idle`.

4. **Status hygiene** (applies to all kept rows): a row marked `active` whose
   `last_seen` is **older than 2h** → `idle`. (Much older rows can be left `idle`;
   v1 does not auto-`done` to avoid hiding history — revisit if needed.)

## Cost guard

- Exactly one list call, then N writes (cheap path).
- Deep transcript-peek runs **only** for fresh null-title rows (bounded count).
- The transcript reading is delegated to a **subagent** (it is noisy file-trawling);
  the subagent returns only `{session_key → {title, category, tags}}`, keeping the
  maestro context clean. If many fresh null rows exist, the subagent batches them.

## Output / notify

- Returns and pushes a one-line digest:
  `swept N: X renamed · Y tagged idle · Z already clean · W deep-peeked`.
- Notify channel: WhatsApp + AQ Backoffice via the owner notify path
  (`send_whatsapp` MCP tool / the OS notify hook), per the notify-don't-gate rule.
- No approval gate — auto-applies, then reports.

## Skill shape

```
skills/sweep-sessions/
  SKILL.md                 # trigger + protocol (this design, operationalized)
  scripts/
    sweep.sh               # orchestrator: list → classify → write → digest
    derive.py              # pure title/tag/category derivation from a row (cheap path)
    peek-transcript.sh     # locate + slice a transcript by uuid+cwd+machine
```

`sweep.sh` is the entrypoint. `derive.py` is pure and unit-testable (row in →
`{title, summary, status}` out) so the heuristics can be tested without the API.
`peek-transcript.sh` is the only piece that touches other machines.

Add `sweep-sessions` to `skills/install.sh` so it propagates across the fleet
(gated push, same as `maestro-sync`).

## Triggers (SKILL.md description)

"sweep sessions", "rename the sessions", "clean up the ops room", "tidy the
roster", "the ops room is messy / unreadable", and as a maestro housekeeping step.

## Testing

- `derive.py` unit tests: representative rows (structured `feat/*`, `fix/*`,
  `deploy/*`; bare null row; already-clean `maestro-*` → skip) → expected
  title/category/tags/status.
- Idempotency test: feed a derive output back in → classifies as "already clean",
  no write.
- Dry-run mode (`sweep.sh --dry-run`) prints the diff table without writing —
  used to validate against the live roster before the first real sweep.
- Safety check: a `maestro-*` / `handoff-*` row is never rewritten.

## Open items folded in (resolved)

- Tags live in the `summary` line, not `links_json`. ✓
- Stale `active`→`idle` cutoff = 2h. ✓
