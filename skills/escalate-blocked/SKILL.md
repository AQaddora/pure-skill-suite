---
name: escalate-blocked
description: When an agent is blocked by a permission gate, an unreachable MCP/node, or a human-only action it cannot perform, hand the task to Ahmed cleanly — notify him on WhatsApp + the AQ Backoffice, AND stage an ATTACHED terminal session pre-loaded with the exact blocked command so he finishes it in one tap. Triggers on "I'm blocked", "permission denied", "needs approval", "can't reach the node", "human-only", or any time a tool call is refused and the task genuinely needs the owner's hands. PRIVATE to Ahmed Qaddoura's AQaddoura OS.
---

# Escalate-blocked — owner handoff (notify + stage terminal)

The sovereign law of the OS: **the phone is the only key.** When an agent hits a wall it
must NOT silently stall (the #1 failure mode — see the board's stalled-loop recaps). It
hands the exact next action to Ahmed with everything pre-staged so he spends one tap, not
ten minutes of archaeology.

Use this the moment any of these happen:
- A tool call is **refused by a permission gate** (e.g. `--dangerously-skip-permissions`
  dispatch, a prod deploy/merge, SSH into the spine).
- An **MCP server / node is unreachable** after a few pings (pause, don't spin).
- A **human-only blocker** (OAuth login, App Store / portal step, keychain unlock, Face ID
  approval, a secret only Ahmed holds).

## What it does (two moves, always both)

1. **Stage an attached terminal** with the blocked command pre-typed (NOT executed — Ahmed
   reviews, then hits Enter). Local Mac or a remote node. He runs it under *his* authority,
   so the gate that blocked the agent is satisfied by his presence.
2. **Notify the owner** — registers a `status:"handoff"` session to the AQ Backoffice
   (surfaces in the Workroom) and sends a WhatsApp with the one-line attach command.

## Usage

```
~/.claude/skills/escalate-blocked/scripts/escalate.sh \
  --task "Dispatch designer-agents-board sprint to fatmac" \
  --cmd  "bash ~/.claude/skills/maestro/scripts/dispatch.sh aqaddoura-os main feat/x /tmp/spec.md \"title\"" \
  --reason "auto-mode blocks launching --dangerously-skip-permissions agents" \
  --node local            # or: fatmac   (where the command must run)
  [--cwd <dir>] [--repo <name>]
```

It prints the **attach command**. That's what Ahmed runs (or taps in the AQ Backoffice
Workroom → the staged session) to finish the task.

## Rules
- **Never fake the work to avoid escalating.** A blocked task is escalated, not pretended-done.
- Pre-type the command; **never auto-run** a gated command on the owner's behalf — staging is
  the point (his Enter = his approval).
- One handoff session per blocked task; reuse the slug so repeats don't pile up.
- If the agent has the `send_whatsapp` MCP tool itself (e.g. a maestro chat session), it may
  send the WhatsApp directly to Ahmed (`+972567693878`) instead of relying on the backend
  fan-out — but it must STILL register the `handoff` session so the board sees it.
- WhatsApp/push fan-out on `status:"handoff"` is owned by the backoffice
  (`server/routes/internal.js`); if that fan-out isn't deployed yet, the registration still
  lands and the maestro sends the WhatsApp directly. See [[status-beacon]] / [[report-back]].
