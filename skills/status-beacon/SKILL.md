---
name: status-beacon
description: Lightweight mid-flight progress logging for long agent runs. Where `report-back` writes the final outcome, status-beacon drops short, timestamped progress notes to a file DURING the work so a human or orchestrator can check in without interrupting. Triggers on long/multi-phase tasks, or when the user says "keep a log", "leave progress notes", "beacon this", "let me track this". Appends to a `progress.md` inside the active bundle/work dir. Honest about uncertainty — notes are signals, not guarantees. Works across Claude, Cursor, Copilot, Codex, Gemini, Aider, Windsurf.
license: MIT
---

# Status-beacon

A long agent run is a black box until it ends. This skill cracks the box open with cheap, append-only progress notes so the orchestrator can watch without stopping the work.

## When to Use This Skill

Trigger when:

- A task spans many phases / long execution (a `report-back` at the end isn't enough visibility)
- The user says "keep a log", "leave progress notes", "beacon this", "let me track this"
- An `execute` run delegates to a coding agent that will run for a while

## How It Works

### Append, don't rewrite
Append one block per milestone to `progress.md` in the active bundle/work dir:

```markdown
## <ISO timestamp> — <phase>
- Did: <one line>
- Next: <one line>
- Blocked: <none | reason>
- Confidence: <high | medium | low> that this is on track
```

### Cadence
One beacon per meaningful milestone (a phase done, a decision made, a block hit) — not per file edit. Aim for signal, not noise: a reader should reconstruct the run from the beacons alone.

### Handoff to report-back
When the run ends, `report-back` reads `progress.md` to seed the final report, then writes the `-shipped/handoff.md`. Beacons are the rough log; the report is the clean record.

## Operational Rules

1. **Append-only.** Never rewrite history — the timeline is the value.
2. **Milestones, not keystrokes.** Beacon on phase/decision/block boundaries.
3. **Be honest about confidence.** "low confidence, exploring" beats false certainty.
4. **No secrets in the log.** Same rule as everywhere.
5. **Beacons feed `report-back`.** Don't duplicate the final report inline.

## Position in the PURE Loop

Runs alongside `execute` for long delegations; its `progress.md` is the raw material `report-back` distills. Together with `organize-agents`, it gives the orchestrator both live (beacon) and final (report) views of every run.

---

*Part of the [Vibe Coding Mastery](https://github.com/AQaddora/vibe-coding-mastery) skill suite. MIT licensed.*
