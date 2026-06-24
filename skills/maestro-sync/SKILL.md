---
name: maestro-sync
description: Makes EVERY Claude session on any device a maestro that knows all current sessions across the fleet before it acts. Use at session start AND before dispatching any sprint, deploy, or build — to detect that the same work may already be running elsewhere (a repeated WhatsApp nag, two people asking the same thing), and route the request to the EXISTING session (tail + manage it) instead of dispatching a duplicate. Also classifies an incoming instruction as NEW vs FOLLOW-UP / FEATURE-ADD / RESCOPE of a live sprint and routes it accordingly. Keeps sprint memory and announces state to the fleet via the shared board. Triggers on: "dispatch", "build", "deploy", "run a sprint", "onboard", any owner instruction that could spawn work, or session start. PRIVATE to Ahmed Qaddoura's AQaddoura OS.
---

# maestro-sync — every session is a fleet-aware maestro

The OS has many brains (this Mac, fatmac, mydroplet, maestro, chickchack) and many entry
points (Claude Code on any device, the WhatsApp Digital-Ahmen bot, the Ops Room). Ahmed
**nags** — he'll ask for the same thing twice, from WhatsApp and from a terminal, or
re-scope something already in flight. Without shared awareness, each session naively
dispatches a fresh sprint → duplicate work, conflicting branches, wasted compute.

**This skill makes every session check the fleet before it acts**, so the OS behaves like
ONE maestro with many hands instead of N strangers.

## The two moments you MUST run this

1. **Session start** — pull the roster so you know what's already live.
2. **Before ANY dispatch/build/deploy** — run the pre-dispatch protocol below. No exceptions.
   A blocked-by-permission action still runs the protocol first (so the handoff you stage to
   Ahmed is deduplicated too).

## Pre-dispatch protocol (the core loop)

```
1. ROSTER   → scripts/roster.sh
              lists live code sessions (all devices) + recent sprints from os_sprints,
              with repo / branch / title / status / tmux name / last activity.

2. MATCH    → does the incoming instruction touch a repo/topic that already has a
              live or recent (< 24h) session or sprint? Compare on: repo, branch,
              the noun being acted on (e.g. "talabat-Gaza footer", "Taqat academy PRs").

3. CLASSIFY the instruction against the matched work:
   • NEW          → no match. Dispatch a fresh NAMED tmux session (see dispatch-in-tmux rule).
   • DUPLICATE    → same ask, already running. DO NOT dispatch. Attach the existing
                    session, confirm it's really doing this, report status to Ahmed.
   • FOLLOW-UP    → "any update? / go / status?" on live work. Tail + summarize, don't respawn.
   • FEATURE-ADD  → new requirement that EXTENDS a live sprint's scope. Route the addition
                    INTO the existing session (tmux send-keys / append to its SPRINT.md),
                    don't fork a parallel sprint on the same repo.
   • RESCOPE      → changes the direction of a live sprint ("actually merge into staging,
                    not main" / "reject that PR"). Steer the existing session; if it already
                    shipped the wrong thing, open a correction in the SAME session.

4. ACT      → dispatch (NEW) or steer-existing (the other four). Either way:
5. ANNOUNCE → scripts/announce.sh records the decision to sprint memory + the shared board,
              so the NEXT session (or device) sees it and the chain stays deduplicated.
```

**"Manage under surveillance":** when you route to an existing session, you become its
supervisor for this instruction — attach it, push the new input, watch it land, and report
back to Ahmed. You are not starting new work; you are conducting work already in motion.

## Attaching / steering an existing session

- **Local Mac:** `tmux attach -t <name>` to watch; `tmux send-keys -t <name> "<input>" Enter`
  to inject a follow-up / feature-add / rescope.
- **On a node (fatmac etc.):** `ssh <node> "tmux send-keys -t <name> '<input>' Enter"` and
  `ssh -t <node> tmux attach -t <name>` to watch. fatmac is reachable via the `mydroplet`
  ProxyJump (already in ~/.ssh/config); it runs bypassPermissions, so injected work proceeds.
- Never spawn a second session for the same repo+topic while one is live — that's the bug
  this skill exists to kill.

## Sprint memory

The durable record lives in three places, all read by `roster.sh`:
- **`os_sprints`** (control-plane DB on mydroplet) — WhatsApp/Ops-Room dispatched builds.
- **registered code sessions** — `POST/GET /api/internal/sessions` (any Claude Code session
  that registered itself; status active|idle|done|handoff).
- **the shared board** — `AgentHandoffs/SPRINTS.md`, a human-readable ledger every node reads.

`announce.sh` writes the board entry + heartbeats the session API, so memory survives the
session that created it. This is how the OS "keeps memory of sprints and detects follow-ups."

## Rules
- **Roster before dispatch. Always.** The whole point is to not duplicate Ahmed's nags.
- **One live session per repo+topic.** Route additions in; don't fork parallels.
- **Every dispatch goes into a NAMED tmux session** (see the dispatch-in-tmux doctrine /
  [[escalate-blocked]] for the staging pattern) so it can be attached & supervised.
- **Mirror Ahmed's language** when you report back (Arabic ↔ English as he wrote).
- If the roster is unreachable (API/MCP down), do NOT blind-dispatch — pause and escalate
  via [[escalate-blocked]]; a duplicate sprint is worse than a short wait.
- Report routing decisions back to Ahmed (WhatsApp + AQ Backoffice) so he sees the OS chose
  "steered existing" vs "dispatched new" under his surveillance.
