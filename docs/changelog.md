# Changelog

All notable changes to the PURE skill suite are recorded here.

The format roughly follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are dated; tagged releases are called out where they apply.

## 2026-05-31 — Report-back trio added (skills 9–11) · readied for v0.1.0 release

### Added

- **Three new skills that close the cross-session loop:**
  - `handoff-receiver` (✅ final) — the receiving half of `handoff`. Boots a fresh agent loaded from a handoff bundle: reads README + manifest, primes from it, confirms locked decisions before coding, refuses to start on a bundle with no mission.
  - `report-back` (✅ final) — mandatory completion report to **files**, not just chat. Writes `<bundle>-shipped/handoff.md` (fixed schema) and sets the source `manifest.json` status to `shipped · <SHA>` or `blocked · <reason>`.
  - `status-beacon` (✅ final) — append-only mid-flight `progress.md` notes for long runs, so an orchestrator can watch without interrupting.
- Skills README bumped 8 → 11; installer count updated.

### Why this matters

`handoff` packed a session; nothing formalized the *receiving* and *reporting* halves. These three make delegation a closed file-based loop: a control plane hands a bundle → `handoff-receiver` boots loaded → `status-beacon` logs progress → `report-back` writes the result back. Files in, files out — the same discipline across Claude, Cursor, Copilot, Codex, Gemini, Aider, Windsurf. Bundled into the first tagged release, **v0.1.0**.
