---
name: sweep-sessions
description: Sweep the fleet code-session roster and make the Ops Room readable — give every cluttered or null-title session a clear title, a category tag (🛠 build / 🚀 deploy / 🔎 research / 🎨 design / 🧹 chore / 🤝 handoff / 💤 idle-noise), and a truthful status, then write the cleanups back through the session API and push one digest. Use when Ahmed says "sweep sessions", "rename the sessions", "clean up / tidy the ops room", "the roster is messy/unreadable", or as a maestro housekeeping pass. On-demand, auto-applies, notify-don't-gate. Never overwrites an already-good name. PRIVATE to Ahmed Qaddoura's AQaddoura OS.
---

# sweep-sessions — make the Ops Room readable

The code-session registry on the spine is the fleet's shared "what's running"
board, but it fills with bare `claude:<uuid>` rows (no title, no repo) and stale
`active` rows that drown out the real work. This skill sweeps it clean.

## What it does
1. Pulls the whole roster (`GET /api/internal/sessions`).
2. For each row, derives a plan (pure heuristics in `scripts/derive.py`):
   - **already-clean** name (`maestro-*`, `handoff-*`, any human title) → left alone
     (status-only hygiene if it went stale).
   - **structured** row (has repo/branch) → renamed to `<emoji> <repo> · <intent>`
     with a `tags:` line in the summary.
   - **bare fresh** row → queued for a transcript peek so it gets a real name.
   - **bare stale** row → tagged 💤 idle-noise + status idle.
   - any `active` row stale > 2h → status idle.
3. Writes the cheap-path cleanups back (`POST /api/internal/session`, non-null
   fields only — never clobbers).
4. Names the peek queue from transcript slices (below), writes those too.
5. Pushes one digest to Ahmed.

## Run it

```
# Always preview first against the live roster (read-only):
scripts/sweep.sh sweep --dry-run

# Apply for real:
scripts/sweep.sh sweep
```

`sweep` writes a peek queue to `$SWEEP_PEEK_OUT` (default `/tmp/sweep-peek.json`):
`{ "peek": [ { session_key, slice, ... }, ... ] }`.

## Name the peek queue (LLM-in-the-loop)
For each entry in the peek queue:
- Read its `slice` (a short cut of the session's transcript). If the slice is
  empty (transcript on another machine / not found), tag it 💤 idle-noise and
  set status idle — don't invent a title.
- Otherwise write a 3–6 word title with the right category emoji and a `tags:`
  line, then persist it:
  ```
  scripts/sweep.sh write --key "<session_key>" \
    --title "🔎 wa inbound history bug" \
    --summary "debugging recent-N history loader\ntags: aqaddoura · research"
  ```
- If a peek row is on `fatmac`/`droplet`, fetch its slice over SSH first
  (`ssh <machine> 'bash -s' < scripts/peek-transcript.sh --uuid <uuid>` via the
  mydroplet ProxyJump) — best-effort; fall back to idle-noise if unreachable.

When there are several peek rows, hand the whole queue to ONE subagent (the
slices are noisy) and have it return `{session_key → {title, summary}}`; then
loop `sweep.sh write` over the results. Keep the noise out of the maestro context.

## Notify (don't gate)
After applying, push the digest line to Ahmed on WhatsApp + AQ Backoffice (the
owner notify path / `send_whatsapp`). Example:
`swept 41: 26 renamed · 9 tagged idle · 4 already clean · 2 peek-queued`.
No approval gate — this is housekeeping under the notify-don't-gate rule.

## Rules
- **Never overwrite a good name.** Clean rows are skipped by construction; trust it.
- **Idempotent.** Re-running is safe — a row renamed last pass is "clean" this pass.
- **Best-effort peeks.** A missing transcript ⇒ idle-noise, never a guessed title.
- **Fail-soft.** No secret / roster unreachable ⇒ report it, change nothing.
- Relates to [[maestro-sync-skill]] (the roster is the same board) and the
  notify-don't-gate doctrine.
