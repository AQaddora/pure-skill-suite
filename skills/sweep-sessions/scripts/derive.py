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
