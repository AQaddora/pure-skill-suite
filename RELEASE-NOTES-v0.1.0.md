# PURE Skill Suite — v0.1.0 (first tagged release)

The first formal release of the PURE + AI Doctrine skill suite. Free, MIT, forever.

## What's in it

**The cross-tool memory bus.** A single `~/ai-doctrine.md` synced into Claude, Cursor, Copilot, Codex, Gemini CLI, Aider, and Windsurf — one rulebook every AI tool reads.

**The PURE Loop, as installable skills:**
- `doctrine-keeper` — the memory bus; captures every rule you learn.
- `prime` · `understand` · `refine` · `execute` — the four PURE phases.
- `organize-agents` · `pure-orchestrator` — run and track the full loop.
- `handoff` — migrate a long session to a fresh chat without losing state.

**New in v0.1.0 — the report-back trio** that closes the cross-session loop:
- `handoff-receiver` — boots a fresh agent loaded from a handoff bundle.
- `report-back` — mandatory completion report written to files (not just chat).
- `status-beacon` — append-only progress notes for long runs.

## Why it exists

Most "AI for devs" advice is theory. PURE is structure, and these are real skills with code. The loop is now closed end-to-end: prime context → work the phases → hand off cleanly → the next agent picks up loaded → it reports back in files. The same discipline in every tool.

This is the **standalone distribution** repo. The same skills are also bundled with the [vibe-coding-mastery](https://github.com/AQaddora/vibe-coding-mastery) courseware, which adds the 5-session Mindset Foundations series.

## Install

```bash
git clone https://github.com/AQaddora/pure-skill-suite.git
cd pure-skill-suite
./skills/install.sh
```

## Tagging this release (run on your Mac)

```bash
cd ~/Work/pure-skill-suite
git add skills/ docs/changelog.md RELEASE-NOTES-v0.1.0.md README.md
git commit -m "release(v0.1.0): first tagged release — PURE suite + report-back trio (11 skills)"
git tag -a v0.1.0 -m "PURE Skill Suite v0.1.0 — PURE + AI Doctrine skill suite"
git push origin main --tags
gh release create v0.1.0 --title "PURE Skill Suite v0.1.0" --notes-file RELEASE-NOTES-v0.1.0.md
```

Release URL will be: https://github.com/AQaddora/pure-skill-suite/releases/tag/v0.1.0
