# sweep-sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A maestro skill that sweeps the fleet code-session roster, gives every cluttered/null-title row a readable title + category tag + truthful status, and writes the cleanups back through the existing session API — on demand, auto-applied, with one notify digest.

**Architecture:** A pure Python module (`derive.py`) holds all the deterministic naming/classification heuristics and is unit-tested in isolation. A bash orchestrator (`sweep.sh`) reads the roster, runs `derive.py`, applies the cheap-path writes (rename/idle) via the internal HTTP API, and emits a "peek queue" of fresh null-title rows (with extracted transcript slices) for the maestro to name with LLM help. `peek-transcript.sh` locates and slices a session's transcript by uuid. `SKILL.md` drives the LLM-in-the-loop steps (naming peek rows, notify). No DB schema change — tags ride in title prefix + summary.

**Tech Stack:** Python 3.11 (stdlib only — `unittest`, no pytest dependency), bash, `jq`, `curl`. The spine API at `https://api.aqaddoura.com` with `x-internal-secret` from `~/.aqos/secret`.

## Global Constraints

- **No schema migration.** Only existing `code_sessions` columns: `machine, project, repo, cwd, branch, status, title, summary, links_json`.
- **Write path:** `POST /api/internal/session` upserts by `session_key` and overwrites **only non-null fields** (`COALESCE`). Always send `session_key`; send only the fields you intend to change.
- **Never clobber a good name.** A row whose `title` is non-null and not equal to its `session_key` is "clean" — never rewrite its title (status-only hygiene allowed).
- **Tags live in the `summary` line**, never `links_json`.
- **Category taxonomy (emoji prefix on title):** 🛠 build · 🚀 deploy · 🔎 research · 🎨 design · 🧹 chore · 🤝 handoff · 💤 idle-noise.
- **Stale cutoff:** `active` with `last_seen` older than **2h** → `idle`.
- **Freshness window:** a bare null-title row is "fresh" (worth a deep-peek) if `last_seen` within **20 min**.
- **Python purity:** all heuristics are pure functions taking an explicit `now_epoch`, so tests are deterministic. No `time.time()` inside heuristic functions.
- **Auth/secret:** read secret from `~/.aqos/secret` (strip newline). API base from `AQOS_API` env, default `https://api.aqaddoura.com`. Fail-soft: if no secret, scripts print a clear message and exit non-zero without crashing the maestro.
- All paths below are relative to the repo root `pure-skill-suite/`.

---

## File Structure

```
skills/sweep-sessions/
  SKILL.md                      # trigger + LLM protocol (Task 6)
  scripts/
    derive.py                   # pure heuristics + CLI (Tasks 1-3)
    peek-transcript.sh          # locate + slice a transcript by uuid (Task 4)
    sweep.sh                    # orchestrator: list→derive→write→digest (Task 5)
  tests/
    test_derive.py              # unittest for derive.py (Tasks 1-3)
    fixtures/
      roster.json               # canned roster for sweep.sh test (Task 5)
      transcript.jsonl          # canned transcript for peek test (Task 4)
docs/superpowers/specs/2026-06-24-sweep-sessions-design.md   # (exists)
skills/install.sh               # add "sweep-sessions" to SKILLS array (Task 7)
```

---

### Task 1: derive.py — classification core

**Files:**
- Create: `skills/sweep-sessions/scripts/derive.py`
- Test: `skills/sweep-sessions/tests/test_derive.py`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `parse_ts(ts: str|None) -> int|None` — epoch seconds from a SQLite UTC string `"YYYY-MM-DD HH:MM:SS"`; `None` if unparseable/empty.
  - `is_clean_title(row: dict) -> bool` — True if `title` is non-null and `!= session_key`.
  - `is_bare_null(row: dict) -> bool` — True if `title` empty AND `repo` empty.
  - `is_stale(row: dict, now_epoch: int, hours: int = 2) -> bool` — True if `last_seen` older than `hours` (unparseable ⇒ stale).
  - `is_fresh(row: dict, now_epoch: int, minutes: int = 20) -> bool` — True if `last_seen` within `minutes`.

- [ ] **Step 1: Write the failing test**

Create `skills/sweep-sessions/tests/test_derive.py`:

```python
import os, sys, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import derive  # noqa: E402

NOW = 1750765200  # fixed epoch for determinism (2025-06-24T11:40:00Z-ish)


def at(offset_secs):
    """SQLite UTC string `offset_secs` before NOW."""
    import datetime
    dt = datetime.datetime.utcfromtimestamp(NOW + offset_secs)
    return dt.strftime("%Y-%m-%d %H:%M:%S")


class TestCore(unittest.TestCase):
    def test_parse_ts_roundtrips(self):
        self.assertEqual(derive.parse_ts(at(0)), NOW)
        self.assertIsNone(derive.parse_ts(None))
        self.assertIsNone(derive.parse_ts("garbage"))

    def test_is_clean_title(self):
        self.assertTrue(derive.is_clean_title({"title": "HANDOFF: x", "session_key": "handoff-x"}))
        self.assertFalse(derive.is_clean_title({"title": None, "session_key": "claude:uuid"}))
        self.assertFalse(derive.is_clean_title({"title": "claude:uuid", "session_key": "claude:uuid"}))

    def test_is_bare_null(self):
        self.assertTrue(derive.is_bare_null({"title": None, "repo": None}))
        self.assertFalse(derive.is_bare_null({"title": None, "repo": "radx"}))
        self.assertFalse(derive.is_bare_null({"title": "x", "repo": None}))

    def test_staleness(self):
        self.assertFalse(derive.is_stale({"last_seen": at(-60)}, NOW))       # 1 min ago
        self.assertTrue(derive.is_stale({"last_seen": at(-3 * 3600)}, NOW))  # 3h ago
        self.assertTrue(derive.is_stale({"last_seen": None}, NOW))           # unknown ⇒ stale

    def test_freshness(self):
        self.assertTrue(derive.is_fresh({"last_seen": at(-300)}, NOW))       # 5 min ago
        self.assertFalse(derive.is_fresh({"last_seen": at(-3600)}, NOW))     # 1h ago


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd skills/sweep-sessions && python3 -m unittest tests.test_derive -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'derive'` (file not created yet).

- [ ] **Step 3: Write minimal implementation**

Create `skills/sweep-sessions/scripts/derive.py`:

```python
#!/usr/bin/env python3
"""sweep-sessions heuristics — pure, deterministic, unit-tested.

Turns a code_sessions roster row into a cleanup plan: a readable title,
a category tag, a tidy summary, and a truthful status. No I/O, no clock
reads inside the heuristics — callers pass an explicit `now_epoch`.
"""
import datetime

STALE_HOURS = 2
FRESH_MIN = 20


def parse_ts(ts):
    """Epoch seconds from a SQLite UTC string 'YYYY-MM-DD HH:MM:SS'."""
    if not ts:
        return None
    try:
        dt = datetime.datetime.strptime(str(ts), "%Y-%m-%d %H:%M:%S")
        return int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())
    except (ValueError, TypeError):
        return None


def is_clean_title(row):
    title = row.get("title")
    key = row.get("session_key") or ""
    if not title:
        return False
    return title != key


def is_bare_null(row):
    return not row.get("title") and not row.get("repo")


def is_stale(row, now_epoch, hours=STALE_HOURS):
    ts = parse_ts(row.get("last_seen"))
    if ts is None:
        return True
    return (now_epoch - ts) > hours * 3600


def is_fresh(row, now_epoch, minutes=FRESH_MIN):
    ts = parse_ts(row.get("last_seen"))
    if ts is None:
        return False
    return (now_epoch - ts) <= minutes * 60
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd skills/sweep-sessions && python3 -m unittest tests.test_derive -v`
Expected: PASS (5 tests OK).

- [ ] **Step 5: Commit**

```bash
git add skills/sweep-sessions/scripts/derive.py skills/sweep-sessions/tests/test_derive.py
git commit -m "feat(sweep-sessions): derive.py classification core + tests"
```

---

### Task 2: derive.py — naming & tag helpers

**Files:**
- Modify: `skills/sweep-sessions/scripts/derive.py`
- Test: `skills/sweep-sessions/tests/test_derive.py`

**Interfaces:**
- Consumes: `is_clean_title`, `is_bare_null` (Task 1).
- Produces:
  - `branch_kind(branch: str|None) -> str` — one of `feat|fix|chore|deploy|design|other`.
  - `branch_intent(branch: str|None) -> str` — human phrase, acronyms upper-cased (`"feat/seo-og-metadata"` → `"SEO OG metadata"`).
  - `category_for(row: dict) -> str` — taxonomy key (`build|deploy|research|design|chore|handoff|idle-noise`).
  - `repo_tags(row: dict) -> list[str]` — secondary tags (project + non-`here` machine + branch kind), de-duped, order-preserving.
  - `make_title(category: str, label: str) -> str` — `"<emoji> <label>"`.
  - Module constants `CATEGORY_EMOJI: dict`, `REPO_PROJECT_TAGS: dict`, `ACRONYMS: dict`.

- [ ] **Step 1: Write the failing test**

Append to `skills/sweep-sessions/tests/test_derive.py` (before the `if __name__` block):

```python
class TestNaming(unittest.TestCase):
    def test_branch_kind(self):
        self.assertEqual(derive.branch_kind("feat/seo-og-metadata"), "feat")
        self.assertEqual(derive.branch_kind("fix/login"), "fix")
        self.assertEqual(derive.branch_kind("deploy/pipeline"), "deploy")
        self.assertEqual(derive.branch_kind("staging"), "other")
        self.assertEqual(derive.branch_kind(None), "other")

    def test_branch_intent(self):
        self.assertEqual(derive.branch_intent("feat/seo-og-metadata"), "SEO OG metadata")
        self.assertEqual(derive.branch_intent("fix/ops-cors"), "ops CORS")
        self.assertEqual(derive.branch_intent("staging"), "staging")
        self.assertEqual(derive.branch_intent(None), "")

    def test_category_for(self):
        self.assertEqual(derive.category_for({"branch": "feat/x", "repo": "radx"}), "build")
        self.assertEqual(derive.category_for({"branch": "deploy/x", "repo": "radx"}), "deploy")
        self.assertEqual(derive.category_for({"branch": "fix/x", "repo": "radx"}), "chore")
        self.assertEqual(derive.category_for({"branch": "main", "repo": "radx"}), "build")
        self.assertEqual(derive.category_for({"session_key": "handoff-x", "title": "HANDOFF: x"}), "handoff")
        self.assertEqual(derive.category_for({"repo": None, "branch": None}), "idle-noise")

    def test_repo_tags(self):
        tags = derive.repo_tags({"repo": "taqat-academy", "machine": "here", "branch": "feat/x"})
        self.assertEqual(tags, ["brightgaza", "feat"])
        tags2 = derive.repo_tags({"repo": "radx-swift", "machine": "fatmac", "branch": "main"})
        self.assertEqual(tags2, ["radx", "fatmac"])

    def test_make_title(self):
        self.assertEqual(derive.make_title("build", "radx · explore tab"), "🛠 radx · explore tab")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd skills/sweep-sessions && python3 -m unittest tests.test_derive -v`
Expected: FAIL — `AttributeError: module 'derive' has no attribute 'branch_kind'`.

- [ ] **Step 3: Write minimal implementation**

Append to `skills/sweep-sessions/scripts/derive.py`:

```python
CATEGORY_EMOJI = {
    "build": "🛠",
    "deploy": "🚀",
    "research": "🔎",
    "design": "🎨",
    "chore": "🧹",
    "handoff": "🤝",
    "idle-noise": "💤",
}

# repo basename → project tags (extend as the fleet grows)
REPO_PROJECT_TAGS = {
    "taqat-academy": ["brightgaza"],
    "my-child-nest": ["brightteam"],
    "radx": ["radx"],
    "radx-swift": ["radx"],
    "aqaddoura.com-private": ["aqaddoura"],
    "aqaddoura-mcp-authenticator": ["aqaddoura"],
    "aqaddoura-os": ["aqos"],
    "pure-skill-suite": ["aqos"],
}

ACRONYMS = {
    "seo": "SEO", "og": "OG", "pr": "PR", "prs": "PRs", "ui": "UI",
    "ux": "UX", "api": "API", "cors": "CORS", "mcp": "MCP", "os": "OS",
    "wa": "WA", "ig": "IG", "db": "DB",
}


def branch_kind(branch):
    b = (branch or "").lower()
    if b.startswith(("feat/", "feature/")):
        return "feat"
    if b.startswith(("fix/", "bugfix/", "hotfix/")):
        return "fix"
    if b.startswith(("chore/", "refactor/")):
        return "chore"
    if b.startswith(("deploy/", "release/")):
        return "deploy"
    if b.startswith(("design/", "ux/")):
        return "design"
    return "other"


def branch_intent(branch):
    if not branch:
        return ""
    slug = branch.split("/", 1)[1] if "/" in branch else branch
    words = slug.replace("-", " ").replace("_", " ").split()
    return " ".join(ACRONYMS.get(w.lower(), w) for w in words).strip()


def category_for(row):
    key = row.get("session_key") or ""
    title = row.get("title") or ""
    if key.startswith("handoff") or title.startswith("HANDOFF"):
        return "handoff"
    kind = branch_kind(row.get("branch"))
    if kind == "deploy":
        return "deploy"
    if kind == "design":
        return "design"
    if kind in ("fix", "chore"):
        return "chore"
    if kind == "feat":
        return "build"
    if row.get("repo"):
        return "build"
    return "idle-noise"


def repo_tags(row):
    tags = []
    repo = row.get("repo")
    if repo:
        tags += REPO_PROJECT_TAGS.get(repo, [])
    machine = row.get("machine")
    if machine and machine != "here":
        tags.append(machine)
    kind = branch_kind(row.get("branch"))
    if kind != "other":
        tags.append(kind)
    seen, out = set(), []
    for t in tags:
        if t not in seen:
            seen.add(t)
            out.append(t)
    return out


def make_title(category, label):
    return f"{CATEGORY_EMOJI[category]} {label}".strip()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd skills/sweep-sessions && python3 -m unittest tests.test_derive -v`
Expected: PASS (all TestCore + TestNaming tests OK).

- [ ] **Step 5: Commit**

```bash
git add skills/sweep-sessions/scripts/derive.py skills/sweep-sessions/tests/test_derive.py
git commit -m "feat(sweep-sessions): branch/category/tag naming helpers + tests"
```

---

### Task 3: derive.py — derive_row, derive_all, CLI

**Files:**
- Modify: `skills/sweep-sessions/scripts/derive.py`
- Test: `skills/sweep-sessions/tests/test_derive.py`

**Interfaces:**
- Consumes: everything from Tasks 1-2.
- Produces:
  - `derive_row(row: dict, now_epoch: int) -> dict` — a plan:
    `{"session_key", "action", "title", "summary", "status", "category", "tags", "old_title"}`
    where `action ∈ {"skip","rename","idle","peek"}`. For `skip`/`idle` the `title`/`summary`
    fields that should not change are `None` (so the API leaves them untouched).
  - `derive_all(payload: dict, now_epoch: int) -> dict` — `{"plans": [derive_row(...) for sessions]}`.
  - CLI: `python3 derive.py --now <epoch>` reads roster JSON on stdin (`{"sessions":[...]}`),
    writes `{"plans":[...]}` to stdout. `--now` optional (defaults to current UTC epoch).

Plan semantics (exact):
- **clean + not stale** → `action="skip"`, all change-fields `None`.
- **clean + active & stale** → `action="idle"`, `status="idle"`, title/summary `None` (keep the good name).
- **bare-null + fresh** → `action="peek"`, `category="idle-noise"` (fallback), title/summary `None`
  (the maestro fills them after reading the transcript).
- **bare-null + not fresh** → `action="idle"`, `title="💤 idle-noise"`, `summary="tags: idle-noise"`,
  `status="idle"`.
- **structured (has repo/branch, not clean)** → `action="rename"`,
  `title=make_title(category, "<repo> · <intent-or-branch-or-repo>")`,
  `summary="<branch>\ntags: <tags joined by ' · '>"` (omit branch line if no branch),
  `status="idle"` only if active & stale else `None`.

- [ ] **Step 1: Write the failing test**

Append to `skills/sweep-sessions/tests/test_derive.py`:

```python
class TestDeriveRow(unittest.TestCase):
    def test_skip_clean_fresh(self):
        row = {"session_key": "maestro-x", "title": "[steer] Ahmed Jaber PRs",
               "status": "active", "last_seen": at(-60)}
        p = derive.derive_row(row, NOW)
        self.assertEqual(p["action"], "skip")
        self.assertIsNone(p["title"])

    def test_clean_but_stale_goes_idle_keeps_name(self):
        row = {"session_key": "maestro-x", "title": "[steer] Ahmed Jaber PRs",
               "status": "active", "last_seen": at(-3 * 3600)}
        p = derive.derive_row(row, NOW)
        self.assertEqual(p["action"], "idle")
        self.assertEqual(p["status"], "idle")
        self.assertIsNone(p["title"])  # never clobber the good name

    def test_structured_rename(self):
        row = {"session_key": "claude:abc", "title": None, "repo": "taqat-academy",
               "branch": "feat/seo-og-metadata", "machine": "here",
               "status": "active", "last_seen": at(-60)}
        p = derive.derive_row(row, NOW)
        self.assertEqual(p["action"], "rename")
        self.assertEqual(p["title"], "🛠 taqat-academy · SEO OG metadata")
        self.assertIn("tags: brightgaza · feat", p["summary"])
        self.assertIsNone(p["status"])  # fresh ⇒ leave status

    def test_structured_stale_rename_and_idle(self):
        row = {"session_key": "claude:abc", "title": None, "repo": "radx",
               "branch": "feature/explore-tab", "machine": "here",
               "status": "active", "last_seen": at(-5 * 3600)}
        p = derive.derive_row(row, NOW)
        self.assertEqual(p["action"], "rename")
        self.assertEqual(p["status"], "idle")

    def test_bare_null_fresh_is_peek(self):
        row = {"session_key": "claude:abc", "title": None, "repo": None,
               "machine": "here", "status": "active", "last_seen": at(-120)}
        p = derive.derive_row(row, NOW)
        self.assertEqual(p["action"], "peek")
        self.assertIsNone(p["title"])

    def test_bare_null_stale_is_idle_noise(self):
        row = {"session_key": "claude:abc", "title": None, "repo": None,
               "machine": "here", "status": "active", "last_seen": at(-9 * 3600)}
        p = derive.derive_row(row, NOW)
        self.assertEqual(p["action"], "idle")
        self.assertEqual(p["title"], "💤 idle-noise")
        self.assertEqual(p["status"], "idle")

    def test_idempotent_rename_output_is_clean(self):
        # feed a renamed row back in → it now has a clean title → skip
        renamed = {"session_key": "claude:abc", "title": "🛠 taqat-academy · SEO OG metadata",
                   "repo": "taqat-academy", "branch": "feat/seo-og-metadata",
                   "status": "active", "last_seen": at(-60)}
        p = derive.derive_row(renamed, NOW)
        self.assertEqual(p["action"], "skip")

    def test_derive_all_wraps_plans(self):
        payload = {"sessions": [
            {"session_key": "maestro-x", "title": "good", "last_seen": at(-60), "status": "active"},
        ]}
        out = derive.derive_all(payload, NOW)
        self.assertEqual(len(out["plans"]), 1)
        self.assertEqual(out["plans"][0]["action"], "skip")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd skills/sweep-sessions && python3 -m unittest tests.test_derive -v`
Expected: FAIL — `AttributeError: module 'derive' has no attribute 'derive_row'`.

- [ ] **Step 3: Write minimal implementation**

Append to `skills/sweep-sessions/scripts/derive.py`:

```python
def _tags_line(tags):
    return "tags: " + " · ".join(tags) if tags else "tags: build"


def derive_row(row, now_epoch):
    key = row.get("session_key")
    old_title = row.get("title")
    status_now = row.get("status")
    active_and_stale = status_now == "active" and is_stale(row, now_epoch)
    plan = {
        "session_key": key, "action": "skip", "title": None, "summary": None,
        "status": None, "category": None, "tags": [], "old_title": old_title,
    }

    if is_clean_title(row):
        if active_and_stale:
            plan["action"] = "idle"
            plan["status"] = "idle"
        return plan

    if is_bare_null(row):
        if is_fresh(row, now_epoch):
            plan["action"] = "peek"
            plan["category"] = "idle-noise"  # fallback until the maestro names it
        else:
            plan["action"] = "idle"
            plan["category"] = "idle-noise"
            plan["title"] = make_title("idle-noise", "idle-noise")
            plan["summary"] = "tags: idle-noise"
            plan["status"] = "idle"
        return plan

    # structured row with a missing/ugly title → rename
    category = category_for(row)
    intent = branch_intent(row.get("branch")) or row.get("branch") or ""
    repo = row.get("repo") or "session"
    label = f"{repo} · {intent}".strip(" ·") if intent else repo
    tags = repo_tags(row)
    summary_lines = []
    if row.get("branch"):
        summary_lines.append(row["branch"])
    summary_lines.append(_tags_line(tags))
    plan["action"] = "rename"
    plan["category"] = category
    plan["tags"] = tags
    plan["title"] = make_title(category, label)
    plan["summary"] = "\n".join(summary_lines)
    if active_and_stale:
        plan["status"] = "idle"
    return plan


def derive_all(payload, now_epoch):
    sessions = (payload or {}).get("sessions") or []
    return {"plans": [derive_row(r, now_epoch) for r in sessions]}


def _main(argv):
    import json
    import sys
    import time
    now = int(time.time())
    if "--now" in argv:
        now = int(argv[argv.index("--now") + 1])
    payload = json.load(sys.stdin)
    json.dump(derive_all(payload, now), sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    import sys
    _main(sys.argv[1:])
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd skills/sweep-sessions && python3 -m unittest tests.test_derive -v`
Expected: PASS (all tests across TestCore, TestNaming, TestDeriveRow).

- [ ] **Step 5: Verify the CLI round-trips**

Run:
```bash
cd skills/sweep-sessions && echo '{"sessions":[{"session_key":"claude:abc","title":null,"repo":"radx","branch":"feat/explore-tab","machine":"here","status":"active","last_seen":"2020-01-01 00:00:00"}]}' | python3 scripts/derive.py --now 1750765200
```
Expected: a JSON line containing `"action": "rename"` and `"title": "🛠 radx · explore tab"`.

- [ ] **Step 6: Commit**

```bash
git add skills/sweep-sessions/scripts/derive.py skills/sweep-sessions/tests/test_derive.py
git commit -m "feat(sweep-sessions): derive_row/derive_all plan engine + CLI"
```

---

### Task 4: peek-transcript.sh — locate + slice a transcript

**Files:**
- Create: `skills/sweep-sessions/scripts/peek-transcript.sh`
- Create: `skills/sweep-sessions/tests/fixtures/transcript.jsonl`
- Test: inline shell assertions (Step 2/5 below)

**Interfaces:**
- Consumes: nothing.
- Produces: `peek-transcript.sh --uuid <uuid> [--root <dir>] [--max <chars>]` — finds
  `<uuid>.jsonl` under the search roots (`--root`, else `~/.claude/projects` and
  `~/.claude-roza/projects`), extracts the text of user/assistant messages, prints a
  plain-text slice capped at `--max` chars (default 1500). Prints nothing and exits 0
  if no transcript is found (best-effort — caller falls back to idle-noise).

- [ ] **Step 1: Create the fixture transcript**

Create `skills/sweep-sessions/tests/fixtures/transcript.jsonl` (two JSONL lines):

```
{"type":"user","message":{"content":"help me fix the wa inbound history loader, it loads oldest N not recent N"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Found it — ORDER BY id ASC LIMIT N. Switching to DESC then re-ordering ASC."}]}}
```

- [ ] **Step 2: Write the failing test (run before the script exists)**

Run:
```bash
cd skills/sweep-sessions
cp tests/fixtures/transcript.jsonl tests/fixtures/peek-abc123.jsonl
bash scripts/peek-transcript.sh --uuid peek-abc123 --root tests/fixtures
```
Expected: FAIL — `bash: scripts/peek-transcript.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `skills/sweep-sessions/scripts/peek-transcript.sh`:

```bash
#!/usr/bin/env bash
# peek-transcript.sh — locate a Claude Code transcript by uuid and print a short
# text slice of its user/assistant messages, so the maestro can infer what a
# bare null-title session is actually doing. Best-effort: prints nothing if the
# transcript isn't found locally. Remote machines are handled by the caller (ssh).
set -u

UUID="" MAX=1500
ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --uuid) UUID="$2"; shift 2;;
    --root) ROOTS+=("$2"); shift 2;;
    --max)  MAX="$2"; shift 2;;
    *) shift;;
  esac
done
[ -z "$UUID" ] && { echo "usage: peek-transcript.sh --uuid <uuid> [--root DIR] [--max N]" >&2; exit 2; }

# Default search roots: both known Claude homes.
if [ "${#ROOTS[@]}" -eq 0 ]; then
  ROOTS=("$HOME/.claude/projects" "$HOME/.claude-roza/projects")
fi

FILE=""
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  found="$(find "$root" -name "${UUID}.jsonl" -type f 2>/dev/null | head -1)"
  [ -n "$found" ] && { FILE="$found"; break; }
done
[ -z "$FILE" ] && exit 0  # best-effort: nothing to peek

# Extract message text: content is either a string or an array of {type,text} parts.
jq -r '
  select(.message.content != null)
  | if (.message.content | type) == "string"
    then .message.content
    else (.message.content[]? | select(.type == "text") | .text)
    end
' "$FILE" 2>/dev/null | head -c "$MAX"
```

Make it executable: `chmod +x skills/sweep-sessions/scripts/peek-transcript.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd skills/sweep-sessions
bash scripts/peek-transcript.sh --uuid peek-abc123 --root tests/fixtures
```
Expected: output contains `wa inbound history loader` and `ORDER BY id ASC`.

- [ ] **Step 5: Verify the not-found path is silent**

Run:
```bash
cd skills/sweep-sessions
bash scripts/peek-transcript.sh --uuid does-not-exist --root tests/fixtures; echo "exit=$?"
```
Expected: no transcript text, `exit=0`.

- [ ] **Step 6: Clean up the temp fixture copy and commit**

```bash
cd skills/sweep-sessions && rm -f tests/fixtures/peek-abc123.jsonl
cd - >/dev/null
git add skills/sweep-sessions/scripts/peek-transcript.sh skills/sweep-sessions/tests/fixtures/transcript.jsonl
git commit -m "feat(sweep-sessions): peek-transcript.sh locate+slice a transcript by uuid"
```

---

### Task 5: sweep.sh — orchestrator (list → derive → write → digest)

**Files:**
- Create: `skills/sweep-sessions/scripts/sweep.sh`
- Create: `skills/sweep-sessions/tests/fixtures/roster.json`
- Test: inline shell assertions (Steps below)

**Interfaces:**
- Consumes: `derive.py` (Task 3), `peek-transcript.sh` (Task 4).
- Produces two subcommands:
  - `sweep.sh sweep [--dry-run] [--input FILE] [--now EPOCH]` — load roster (from `--input`
    or `GET /api/internal/sessions`), run `derive.py`, apply `rename`/`idle` plans via
    `POST /api/internal/session` (skipped under `--dry-run`, which prints `OLD → NEW` lines),
    build the peek queue (each `peek` plan + its transcript slice) into
    `${SWEEP_PEEK_OUT:-/tmp/sweep-peek.json}`, then print a digest line.
  - `sweep.sh write --key K [--title T] [--summary S] [--status ST]` — single
    `POST /api/internal/session` (used by the maestro to write a named peek row).
- Digest format (stdout, last line):
  `swept <N>: <R> renamed · <I> tagged idle · <S> already clean · <P> peek-queued`

- [ ] **Step 1: Create the fixture roster**

Create `skills/sweep-sessions/tests/fixtures/roster.json`:

```json
{"ok":true,"sessions":[
  {"session_key":"maestro-x","title":"[steer] Ahmed Jaber PRs","repo":"taqat-academy","branch":null,"machine":"here","status":"active","last_seen":"2026-06-24 11:52:40"},
  {"session_key":"claude:struct1","title":null,"repo":"taqat-academy","branch":"feat/seo-og-metadata","machine":"here","status":"active","last_seen":"2026-06-24 11:39:00"},
  {"session_key":"claude:stale1","title":null,"repo":"radx","branch":"feature/explore-tab","machine":"here","status":"active","last_seen":"2026-06-24 06:00:00"},
  {"session_key":"claude:barefresh","title":null,"repo":null,"branch":null,"machine":"here","status":"active","last_seen":"2026-06-24 11:38:00"},
  {"session_key":"claude:barestale","title":null,"repo":null,"branch":null,"machine":"here","status":"active","last_seen":"2026-06-23 02:00:00"}
]}
```

(With `--now 1750765200` = `2026-06-24 11:40:00Z`: struct1 fresh-rename, stale1 stale-rename+idle, barefresh peek, barestale idle-noise, maestro-x skip.)

- [ ] **Step 2: Write the failing test (run before the script exists)**

Run:
```bash
cd skills/sweep-sessions
bash scripts/sweep.sh sweep --dry-run --input tests/fixtures/roster.json --now 1750765200
```
Expected: FAIL — `No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `skills/sweep-sessions/scripts/sweep.sh`:

```bash
#!/usr/bin/env bash
# sweep.sh — sweep the fleet code-session roster: derive readable titles + tags +
# truthful status, write the cheap-path cleanups back, and emit a peek queue for
# bare fresh rows the maestro will name from their transcripts. Fail-soft.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
API="${AQOS_API:-https://api.aqaddoura.com}"
SECRET="${AQOS_INTERNAL_SECRET:-}"
[ -z "$SECRET" ] && [ -f "$HOME/.aqos/secret" ] && SECRET="$(tr -d '\n\r' < "$HOME/.aqos/secret")"

post_session() { # $1=json body
  curl -fsS -X POST "$API/api/internal/session" \
    -H "content-type: application/json" \
    -H "x-internal-secret: $SECRET" \
    --data "$1" >/dev/null
}

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

cmd_write() {
  local key="" title="" summary="" status=""
  while [ $# -gt 0 ]; do case "$1" in
    --key) key="$2"; shift 2;; --title) title="$2"; shift 2;;
    --summary) summary="$2"; shift 2;; --status) status="$2"; shift 2;;
    *) shift;; esac; done
  [ -z "$key" ] && { echo "write: --key required" >&2; return 2; }
  [ -z "$SECRET" ] && { echo "write: no secret — skipping" >&2; return 1; }
  local body="{\"session_key\":$(json_str "$key")"
  [ -n "$title" ]   && body="$body,\"title\":$(json_str "$title")"
  [ -n "$summary" ] && body="$body,\"summary\":$(json_str "$summary")"
  [ -n "$status" ]  && body="$body,\"status\":$(json_str "$status")"
  body="$body}"
  post_session "$body"
}

cmd_sweep() {
  local dry="" input="" now=""
  while [ $# -gt 0 ]; do case "$1" in
    --dry-run) dry=1; shift;; --input) input="$2"; shift 2;;
    --now) now="$2"; shift 2;; *) shift;; esac; done

  local roster
  if [ -n "$input" ]; then
    roster="$(cat "$input")"
  else
    [ -z "$SECRET" ] && { echo "sweep: no secret — cannot reach roster" >&2; return 1; }
    roster="$(curl -fsS "$API/api/internal/sessions" -H "x-internal-secret: $SECRET")"
  fi

  local now_arg=()
  [ -n "$now" ] && now_arg=(--now "$now")
  local plans
  plans="$(printf '%s' "$roster" | python3 "$HERE/derive.py" "${now_arg[@]}")"

  local peek_out="${SWEEP_PEEK_OUT:-/tmp/sweep-peek.json}"
  local n=0 r=0 i=0 s=0 p=0
  : > "$peek_out.tmp"

  # Walk each plan as a compact JSON line.
  while IFS= read -r plan; do
    [ -z "$plan" ] && continue
    n=$((n+1))
    local action key title summary status
    action="$(printf '%s' "$plan" | jq -r '.action')"
    key="$(printf '%s' "$plan" | jq -r '.session_key')"
    title="$(printf '%s' "$plan" | jq -r '.title // ""')"
    summary="$(printf '%s' "$plan" | jq -r '.summary // ""')"
    status="$(printf '%s' "$plan" | jq -r '.status // ""')"
    case "$action" in
      skip) s=$((s+1));;
      rename)
        r=$((r+1))
        if [ -n "$dry" ]; then
          echo "RENAME $key → $title  [$status]"
        else
          cmd_write --key "$key" --title "$title" --summary "$summary" ${status:+--status "$status"}
        fi;;
      idle)
        i=$((i+1))
        if [ -n "$dry" ]; then
          echo "IDLE   $key → ${title:-<keep>}  [idle]"
        else
          cmd_write --key "$key" ${title:+--title "$title"} ${summary:+--summary "$summary"} --status "${status:-idle}"
        fi;;
      peek)
        p=$((p+1))
        local uuid slice
        uuid="${key#claude:}"
        slice="$(bash "$HERE/peek-transcript.sh" --uuid "$uuid" 2>/dev/null)"
        printf '%s\n' "$(printf '%s' "$plan" | jq --arg sl "$slice" '. + {slice:$sl}')" >> "$peek_out.tmp"
        [ -n "$dry" ] && echo "PEEK   $key (slice ${#slice} chars)";;
    esac
  done < <(printf '%s' "$plans" | jq -c '.plans[]')

  jq -s '{peek: .}' "$peek_out.tmp" > "$peek_out" 2>/dev/null || echo '{"peek":[]}' > "$peek_out"
  rm -f "$peek_out.tmp"

  echo "swept $n: $r renamed · $i tagged idle · $s already clean · $p peek-queued"
}

case "${1:-}" in
  sweep) shift; cmd_sweep "$@";;
  write) shift; cmd_write "$@";;
  *) echo "usage: sweep.sh {sweep|write} [...]" >&2; exit 2;;
esac
```

Make it executable: `chmod +x skills/sweep-sessions/scripts/sweep.sh`

- [ ] **Step 4: Run the dry-run test to verify it passes**

Run:
```bash
cd skills/sweep-sessions
SWEEP_PEEK_OUT=/tmp/sweep-peek-test.json bash scripts/sweep.sh sweep --dry-run --input tests/fixtures/roster.json --now 1750765200
```
Expected output includes:
```
RENAME claude:struct1 → 🛠 taqat-academy · SEO OG metadata  []
RENAME claude:stale1 → 🛠 radx · explore tab  [idle]
IDLE   claude:barestale → 💤 idle-noise  [idle]
PEEK   claude:barefresh (slice 0 chars)
swept 5: 2 renamed · 1 tagged idle · 1 already clean · 1 peek-queued
```

- [ ] **Step 5: Verify the peek queue file is valid JSON**

Run: `jq '.peek | length' /tmp/sweep-peek-test.json`
Expected: `1`

- [ ] **Step 6: Commit**

```bash
git add skills/sweep-sessions/scripts/sweep.sh skills/sweep-sessions/tests/fixtures/roster.json
git commit -m "feat(sweep-sessions): sweep.sh orchestrator (sweep/write, dry-run, peek queue)"
```

---

### Task 6: SKILL.md — trigger + LLM protocol

**Files:**
- Create: `skills/sweep-sessions/SKILL.md`

**Interfaces:**
- Consumes: `scripts/sweep.sh`, `scripts/peek-transcript.sh`, `scripts/derive.py`.
- Produces: the maestro-facing protocol (no code symbols).

- [ ] **Step 1: Write SKILL.md**

Create `skills/sweep-sessions/SKILL.md`:

```markdown
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
```

- [ ] **Step 2: Sanity-check the front-matter parses**

Run:
```bash
cd skills/sweep-sessions
python3 -c "import sys; t=open('SKILL.md').read(); fm=t.split('---')[1]; print('name ok' if 'name: sweep-sessions' in fm else 'NAME MISSING')"
```
Expected: `name ok`

- [ ] **Step 3: Commit**

```bash
git add skills/sweep-sessions/SKILL.md
git commit -m "docs(sweep-sessions): SKILL.md protocol + peek-naming loop + notify"
```

---

### Task 7: Register in install.sh + final verification

**Files:**
- Modify: `skills/install.sh:60-75` (the `SKILLS` array)

**Interfaces:**
- Consumes: the whole skill (Tasks 1-6).
- Produces: fleet propagation entry.

- [ ] **Step 1: Add sweep-sessions to the install array**

In `skills/install.sh`, change the array (currently ending at `"montage-creator"`):

```bash
# All 14 skills, in install order (doctrine-keeper first — others depend on it)
SKILLS=(
    "doctrine-keeper"
    "prime"
    "understand"
    "refine"
    "execute"
    "organize-agents"
    "pure-orchestrator"
    "handoff"
    "handoff-receiver"
    "report-back"
    "status-beacon"
    "3d-modeler"
    "montage-creator"
    "sweep-sessions"
)
```

- [ ] **Step 2: Verify install.sh still parses**

Run: `bash -n skills/install.sh && echo "syntax ok"`
Expected: `syntax ok`

- [ ] **Step 3: Run the full Python test suite**

Run: `cd skills/sweep-sessions && python3 -m unittest discover -s tests -v`
Expected: PASS (all derive tests).

- [ ] **Step 4: Read-only live dry-run against the real roster**

Run:
```bash
cd skills/sweep-sessions && scripts/sweep.sh sweep --dry-run | tail -20
```
Expected: a list of `RENAME/IDLE/PEEK` lines for the live roster and a final `swept N: ...`
digest. **No writes happen** (dry-run). Confirm the proposed titles look sane; if a repo
is mis-tagged, extend `REPO_PROJECT_TAGS` in `derive.py` and re-run.

- [ ] **Step 5: Commit**

```bash
git add skills/install.sh
git commit -m "chore(sweep-sessions): register skill in install.sh fleet array"
```

- [ ] **Step 6: Final review**

Confirm: `git log --oneline` shows the 7 task commits; `python3 -m unittest discover` green;
dry-run output sane. The skill is ready. Applying for real (`scripts/sweep.sh sweep`) and
pushing/propagating (`git push` + per-node `install.sh`) are gated on Ahmed — surface them
as the next step, don't auto-run.

---

## Self-Review

**Spec coverage:**
- Read all rows (`GET …/sessions`) → Task 5 `cmd_sweep`. ✓
- Write via non-null upsert → Task 5 `cmd_write`. ✓
- Tags in summary, not links_json → Task 3 `_tags_line` / `derive_row`. ✓
- Category taxonomy (7 emoji) → Task 2 `CATEGORY_EMOJI` / `category_for`. ✓
- Skip-clean / cheap-derive / deep-peek-fresh / tag-stale-idle → Task 3 `derive_row`. ✓
- Transcript location across both `.claude` homes + SSH for remote → Task 4 + Task 6. ✓
- 2h stale → idle; 20 min freshness → Tasks 1/3 constants + tests. ✓
- Cost guard: cheap path is pure; peeks only for fresh null rows; subagent for naming → Task 5 peek queue + Task 6 protocol. ✓
- One-line digest + notify → Task 5 digest + Task 6 notify section. ✓
- Idempotency / never-clobber → Task 3 `test_idempotent_rename_output_is_clean`, `is_clean_title`. ✓
- Dry-run before live → Task 5 + Task 7 Step 4. ✓
- install.sh propagation → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code. ✓

**Type consistency:** Plan dict keys (`action,title,summary,status,category,tags,session_key,old_title`) are identical across `derive_row`, the tests, and `sweep.sh`'s `jq` reads. `make_title`, `category_for`, `repo_tags`, `branch_intent`, `branch_kind` signatures match their call sites. ✓
```

