---
name: report-back
description: The mandatory completion-report skill. When an agent finishes (or is blocked on) a handoff bundle or delegated task, it MUST write the outcome to files — never only into chat. Triggers on "I'm done", "this is shipped", "wrap up", "close out this task", "I'm blocked", or automatically at the end of any `handoff-receiver` / `execute` run. Writes a `<bundle>-shipped/handoff.md` report with a fixed schema (commit SHA, what shipped, files touched, test/smoke results, deferred items, new open questions) and sets the source bundle's `manifest.json` status to `shipped · <SHA>` or `blocked · <reason>`. This is the file-based feedback loop that lets a control plane track every agent across tools.
license: MIT
---

# Report-back

Files in, files out. A delegated agent that reports only in chat is invisible the moment the chat closes. This skill makes the report a durable artifact the orchestrator can read.

## When to Use This Skill

Trigger when the agent:

- Finishes a handoff bundle or delegated task ("done", "shipped", "wrap up", "close out")
- Hits a hard block it can't resolve ("I'm blocked", "stopping here")
- Reaches the end of a `handoff-receiver` or `execute` run (automatic)

## How It Works (3-Step Protocol)

### Step 1 — Write the completion report
Create `<original-bundle>-shipped/handoff.md` next to the source bundle (e.g. `~/Work/AgentHandoffs/2026-05-30-foo-shipped/handoff.md`). Fixed schema:

```markdown
# Shipped — <bundle name>
- Date / agent / tool:
- Commit SHA(s):
- What shipped: (bullet list of concrete changes)
- Files touched: (paths)
- Smoke / test results: (what you ran, what passed)
- Deferred / not done: (with reason)
- New open questions: (for the orchestrator/Ahmed)
- Deploy status: (prepared commands handed to Ahmed / deployed / N/A)
```

### Step 2 — Update the source manifest
Set the source bundle's `manifest.json` `status` to `shipped · <SHA>` or `blocked · <reason>`. This is the single field an orchestrator polls to know state.

### Step 3 — One-line chat summary + pointer
In chat, write one line: what shipped + the report path. Nothing more — the file is the record.

## Operational Rules

1. **Report is mandatory, not optional.** No "done" without a written report.
2. **Status field is the contract.** Always update `manifest.json` status — orchestrators read it, not prose.
3. **Honest blocked > fake shipped.** If tests fail or work is partial, write `blocked` with the reason. Never mark shipped on partial work.
4. **No secrets in reports.** SHAs, paths, results — never tokens, keys, or other-client data.
5. **Don't deploy to report.** If deploy is the user's step, record "commands handed to Ahmed", don't push.

## Position in the PURE Loop

The terminal step after `execute` / `handoff-receiver`. Pairs with `organize-agents`: report-back writes the per-task record; organize-agents indexes runs across tools.

---

*Part of the [Vibe Coding Mastery](https://github.com/AQaddora/vibe-coding-mastery) skill suite. MIT licensed.*
