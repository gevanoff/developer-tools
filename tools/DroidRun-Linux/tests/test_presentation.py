import unittest

from android_build_install_linux import presentation as p
from android_build_install_linux import theme


class ToneTests(unittest.TestCase):
    def test_tones_describe_the_next_sync(self):
        cases = {
            "Current": p.OK, "Fresh": p.OK, "Same": p.OK,
            "Behind 2": p.ACTION, "Stale": p.ACTION, "No APK": p.ACTION,
            "Different": p.ACTION, "Not installed": p.ACTION,
            "Dirty": p.WARN, "No upstream": p.WARN, "Ambiguous": p.WARN,
            "No device": p.WARN, "Configuration needed": p.WARN,
            "Diverged 3/1": p.ERROR, "Fetch failed": p.ERROR,
            "Ahead 1": p.NEUTRAL, "Not Git": p.NEUTRAL, "Unknown": p.NEUTRAL,
            "Queued": p.NEUTRAL, "": p.NEUTRAL, None: p.NEUTRAL,
        }
        for status, expected in cases.items():
            with self.subTest(status=status):
                self.assertEqual(p.tone(status), expected)

    def test_prefix_needs_a_word_boundary(self):
        self.assertEqual(p.tone("Behindhand"), p.NEUTRAL)


class SyncPreviewTests(unittest.TestCase):
    def test_full_path(self):
        preview = p.sync_preview("Behind 2", "Stale", "Different", True)
        self.assertTrue(preview.ready)
        self.assertEqual(preview.steps, ["Pull 2 commits", "Build", "Install", "Launch"])

    def test_single_commit_and_no_launch(self):
        preview = p.sync_preview("Behind 1", "Fresh", "Not installed", False)
        self.assertEqual(preview.steps, ["Pull 1 commit", "Install", "No launch"])

    def test_up_to_date_only_launches(self):
        preview = p.sync_preview("Current", "Fresh", "Same", True)
        self.assertEqual(preview.steps, ["Skip install (same APK)", "Launch"])

    def test_same_apk_is_not_trusted_after_a_rebuild(self):
        preview = p.sync_preview("Current", "Stale", "Same", True)
        self.assertEqual(preview.steps, ["Build", "Install if changed", "Launch"])

    def test_not_git_and_ahead_still_run(self):
        self.assertTrue(p.sync_preview("Not Git", "Fresh", "Different", True).ready)
        self.assertTrue(p.sync_preview("Ahead 3", "Fresh", "Different", True).ready)

    def test_blockers_match_build_install(self):
        for git, build, device in (("Dirty", "Fresh", "Same"), ("Diverged 1/1", "Fresh", "Same"),
                                   ("No upstream", "Fresh", "Same"), ("Unknown", "Fresh", "Same"),
                                   ("Current", "Fresh", "No device"),
                                   ("Current", "Configuration needed", "Unknown")):
            with self.subTest(git=git, build=build, device=device):
                preview = p.sync_preview(git, build, device, True)
                self.assertFalse(preview.ready)
                self.assertTrue(preview.headline.startswith("Sync & Run will stop"))
                self.assertTrue(preview.fix)

    def test_first_blocker_follows_build_install_order(self):
        # build_install selects the build plan, then the device, then checks Git.
        self.assertIn("configuring", p.sync_preview("Dirty", "Configuration needed", "No device", True).headline)
        self.assertIn("device", p.sync_preview("Dirty", "Fresh", "No device", True).headline)

    def test_unchecked_status_is_not_a_prediction(self):
        preview = p.sync_preview("Queued", "Queued", "Queued", True)
        self.assertFalse(preview.ready)
        self.assertIn("not checked", preview.headline)

    def test_ambiguous_build_warns_about_preferred_apk(self):
        preview = p.sync_preview("Current", "Ambiguous", "No local build", True)
        self.assertTrue(preview.ready)
        self.assertIn("Preferred APK", preview.fix)


class ContrastTests(unittest.TestCase):
    @staticmethod
    def ratio(a, b):
        def lum(h):
            def channel(c):
                c = int(h[c:c + 2], 16) / 255
                return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
            return 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5)
        hi, lo = sorted((lum(a), lum(b)), reverse=True)
        return (hi + 0.05) / (lo + 0.05)

    def test_text_and_chips_meet_aa(self):
        for surface in (theme.BG, theme.SURFACE, theme.RAISED, theme.SELECT):
            self.assertGreaterEqual(self.ratio(theme.TEXT, surface), 4.5)
            self.assertGreaterEqual(self.ratio(theme.MUTED, surface), 4.5)
        for name in theme.TONES:
            fg, bg = theme.chip_colors(name)
            self.assertGreaterEqual(self.ratio(fg, bg), 4.5, name)
        self.assertGreaterEqual(self.ratio(theme.ON_LIME, theme.LIME), 4.5)


if __name__ == "__main__":
    unittest.main()
