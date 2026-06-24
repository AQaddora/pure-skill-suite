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
