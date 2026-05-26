# PURE — Skill Suite

> **The operating doctrine for AI engineering, as Claude / Cursor / Copilot / Codex / Gemini / Windsurf skills.**
>
> By [Ahmed Qaddoura](https://aqaddoura.com) · Palestine · MIT licensed.

[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE) [![Made in Palestine](https://img.shields.io/badge/made%20in-Palestine-success)](https://aqaddoura.com)

---

## What this is

PURE is a four-phase loop — **P**rime → **U**nderstand → **R**efine → **E**xecute — that turns any AI coding session into a senior-pair experience instead of fancy autocomplete. Plus a **doctrine layer** that propagates principles across every AI tool you use.

This repo is the **standalone distribution** of the PURE skills. The same skills are also bundled with the [vibe-coding-mastery](https://github.com/AQaddora/vibe-coding-mastery) courseware, which adds a 5-session mindset series. **If you just want the skills, this is the repo.** If you want the doctrine + the course, go to vibe-coding-mastery.

## Quick start

```bash
git clone https://github.com/AQaddora/pure-skill-suite.git
cd pure-skill-suite
./skills/install.sh
```

The installer creates `~/ai-doctrine.md`, installs all 8 skills into `~/.claude/skills/`, and (optionally) wires the doctrine into your current project so every AI tool reads the same memory.

Once installed, in Claude (or any tool that reads `~/.claude/skills/`):

```
"prime me for a FastAPI feature"
"run PURE on adding tenant audit logging"
"add to doctrine: always state Pydantic v2 in primer"
"handoff this — context is getting heavy"
```

Open Cursor or Copilot in the same project — they pick up the same rules from your doctrine automatically.

---

## The skills

Eight skills. Each has its own `SKILL.md` inside [`skills/<name>/`](skills/) — those are the canonical specs the AI reads. The summaries below are for humans browsing the repo.

### Prime

Build a tailored primer for an AI coding session **before** any real task — the stack, style, constraints, threat model, and audience the AI should know up front. Reads `~/ai-doctrine.md` so the primer always carries your established rules.

**Triggers** on phrases like *"prime me"*, *"set up context"*, *"build a primer"*, *"I'm starting a new feature"*.

→ [`skills/prime/SKILL.md`](skills/prime/SKILL.md)

### Understand

Clarifies scope **before** code is written. Summarizes existing context, identifies gaps, asks targeted clarifying questions one at a time so the AI doesn't sprint in the wrong direction.

**Triggers** on *"understand this"*, *"what am I missing"*, *"clarify requirements"*, or any vague feature request.

→ [`skills/understand/SKILL.md`](skills/understand/SKILL.md)

### Refine

Runs systematic self-review on AI output **before** it's accepted. Applies role-prompts (senior security engineer, principal architect, hostile reviewer) and produces a v1 → v2 diff with explicit reasoning.

**Triggers** on *"refine this"*, *"review as senior"*, *"improve this"*, *"second pass"*.

→ [`skills/refine/SKILL.md`](skills/refine/SKILL.md)

### Execute

Delegates real work to a coding agent (Claude Code, Cursor agent mode, Codex, Aider) and tracks the run end-to-end. Creates a run reference, watches for completion, links output back into the conversation.

**Triggers** on *"execute"*, *"run agent"*, *"ship this"*, *"delegate this"*.

→ [`skills/execute/SKILL.md`](skills/execute/SKILL.md)

### PURE Orchestrator

Runs the **full PURE Loop** (Prime → Understand → Refine → Execute) on a feature request, calling each phase's skill in sequence with explicit checkpoints for user approval.

**Triggers** on *"run PURE on..."*, *"process this feature"*, *"PURE this"*, *"full loop"*.

→ [`skills/pure-orchestrator/SKILL.md`](skills/pure-orchestrator/SKILL.md)

### Doctrine Keeper

Captures insights, rules, and learnings from any AI coding conversation into your personal `~/ai-doctrine.md` file — a single source of truth that's then auto-synced into Claude Code, Cursor, Copilot, Codex, Gemini CLI, and Windsurf so every tool reads the same hard-won rules.

**Triggers** on *"add to doctrine"*, *"save this rule"*, *"capture this learning"*, *"this should be a rule"*, *"remember this"*.

→ [`skills/doctrine-keeper/SKILL.md`](skills/doctrine-keeper/SKILL.md)

### Project Handoff

Migrates an in-flight AI coding session to a fresh chat (or a larger-context model) without losing state. Produces a copy-pasteable Markdown handoff block that works in any AI tool — Claude, Cursor, Copilot, Codex, ChatGPT.

**Triggers** on *"handoff this"*, *"we're running out of context"*, *"fresh chat for this"*, *"context window is getting full"*. Always runs **after** Prime has loaded the new chat.

→ [`skills/handoff/SKILL.md`](skills/handoff/SKILL.md)

### Organize Agents

Maintains a registry of agent runs and outputs across every coding agent you work with (Claude Code, Cursor, Codex, Aider, Gemini CLI, Windsurf). Search, tag, and track outcomes across sessions.

**Triggers** on *"list agents"*, *"show recent runs"*, *"agent status"*, *"what's in flight"*.

→ [`skills/organize-agents/SKILL.md`](skills/organize-agents/SKILL.md)

---

## How the skills work together

```
                  ┌─── prime ───┐
                  │             │
  feature ask ────┼─ understand ┤
                  │             ├─── orchestrator
                  │   refine    │
                  │             │
                  └── execute ──┘
                        │
                        ▼
                    doctrine-keeper  (captures learnings)
                    handoff          (when context fills)
                    organize-agents  (tracks runs)
```

The doctrine layer (`~/ai-doctrine.md` + the per-tool symlinks the installer wires up) means every learning captured in one tool is read by every other tool the next time you open it. The skills are how you talk to that layer.

## What gets installed

| Path | What |
| --- | --- |
| `~/ai-doctrine.md` | Single source of truth for your AI engineering rules. Edit directly. |
| `~/.claude/skills/<name>/` | One folder per skill above. Claude reads these. |
| Project-local: `CLAUDE.md`, `.cursorrules`, `AGENTS.md`, `.github/copilot-instructions.md`, etc. | Symlinks to `~/ai-doctrine.md` so the same memory follows you across tools. (Optional — installer asks.) |

The installer is non-destructive: it backs up any file it would replace and prints rollback instructions.

## Compatibility

| Tool | Skill execution | Doctrine read |
| --- | --- | --- |
| Claude Code / Claude Desktop | ✅ Native | ✅ Native (`CLAUDE.md`) |
| Cursor | ⚠ Manual invocation (paste the skill prompt) | ✅ Native (`.cursorrules`) |
| GitHub Copilot | ⚠ Manual invocation | ✅ Native (`.github/copilot-instructions.md`) |
| Codex (OpenAI) | ⚠ Manual invocation | ✅ Native (`AGENTS.md`) |
| Gemini CLI | ⚠ Manual invocation | ✅ Native (`GEMINI.md`) |
| Windsurf | ⚠ Manual invocation | ✅ Native (`.windsurfrules`) |

"Manual invocation" means: open the relevant `SKILL.md`, copy its content into the chat. The doctrine read is automatic in all cases because the symlinks expose `~/ai-doctrine.md` under the file each tool already looks for.

## Updating

```bash
cd pure-skill-suite
git pull origin main
./skills/install.sh  # idempotent — re-runs the symlink wiring
```

## Contributing

This is a personal-doctrine repo by design — it encodes one engineer's rules, not a community standard. PRs that improve clarity, fix bugs in the installer, or port a skill to another tool are welcome. Doctrine-content PRs ("you should also tell people to..." in `~/ai-doctrine.md`) won't be merged; your doctrine is yours.

## License

MIT — see [LICENSE](LICENSE). Use, modify, sell, fork freely. Attribution appreciated, not required.

## Related

- **[vibe-coding-mastery](https://github.com/AQaddora/vibe-coding-mastery)** — same skills bundled with the 5-session Mindset Foundations courseware
- **[aqaddoura.com/blog/pure](https://aqaddoura.com/blog/pure)** — the doctrine paper / origin story
- **[aqaddoura.com](https://aqaddoura.com)** — work + writing
