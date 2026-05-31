---
name: handoff-receiver
description: The cold-start protocol for an AI agent PICKING UP a handoff bundle (the receiving half of `handoff`). Triggers when a fresh session is pointed at a handoff directory or pasted a handoff block — e.g. "read this handoff", "take over from this bundle", "you're picking up <path>", "continue this work", or when the first message is a handoff block. Boots the agent loaded: reads the bundle README + manifest, runs Prime from it, confirms understanding and locked decisions BEFORE writing code, and refuses to start on a bundle with no manifest/mission. Works in any tool (Claude, Cursor, Copilot, Codex, Gemini, Aider, Windsurf).
license: MIT
---

# Handoff-receiver

The receiving half of `handoff`. `handoff` packs a session; this unpacks one cleanly so a fresh agent starts loaded instead of cold.

## When to Use This Skill

Trigger when the agent is:

- Pointed at a handoff directory: "read `~/Work/AgentHandoffs/<bundle>/`", "take over from this bundle"
- Pasted a handoff block as the first message
- Told "continue this work", "you're picking up X", "finish what the last session started"

## How It Works (4-Step Protocol)

### Step 1 — Load the bundle, in order
Read `README.md` → `manifest.json` → `02-mission.md` → `03-locked-decisions.md` → `06-what-is-done.md` → `07-files-in-scope.md`. Skip sections not present. If there is **no manifest and no mission**, stop and ask the user for one — never improvise scope.

### Step 2 — Prime from the bundle
Treat the bundle as the primer (see `prime`). Load `~/ai-doctrine.md` and any pointers the bundle names. Open only the files in `07-files-in-scope.md`; do not wander the repo.

### Step 3 — Confirm before coding
Echo back, in ≤6 lines: the mission, the locked decisions you will NOT touch, and the open questions you need answered. Get explicit go on the open questions. **Locked decisions are immutable — escalate to change, never silently revise.**

### Step 4 — Work, then hand to `report-back`
Run the PURE phases (`understand` → `refine` → `execute`). On completion or block, invoke `report-back` to write the result to files. A receiver that finishes without reporting has not finished.

## Operational Rules

1. **No manifest, no start.** A bundle without a mission gets a clarifying question, not a guess.
2. **Locked decisions are law.** Escalate; don't re-litigate.
3. **Stay in scope.** Read only `07-files-in-scope.md`. Scope creep → a new bundle.
4. **Confirm understanding before code.** Six lines, then go.
5. **Always end in `report-back`.** Receiving implies reporting.

## Position in the PURE Loop

`handoff` (sender) → **handoff-receiver** (Prime in the new chat) → `understand` → `refine` → `execute` → `report-back`. This closes the cross-session loop that `pure-orchestrator` opens.

---

*Part of the [Vibe Coding Mastery](https://github.com/AQaddora/vibe-coding-mastery) skill suite. MIT licensed.*
