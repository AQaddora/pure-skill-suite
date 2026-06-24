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


if __name__ == "__main__":
    unittest.main()
