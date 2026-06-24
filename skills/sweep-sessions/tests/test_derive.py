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
