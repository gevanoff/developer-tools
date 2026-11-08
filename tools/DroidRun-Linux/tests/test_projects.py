import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from android_build_install_linux import projects as pr


def touch(path: Path, text: str = "") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


GODOT_PRESET = '[preset.0]\nname="Android"\nplatform="Android"\n'


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "my repo"
        self.repo.mkdir()

    def test_lists_valid_projects_beneath_with_kinds(self):
        touch(self.repo / "android app" / "gradlew")
        touch(self.repo / "android app" / "app" / "src" / "main" / "AndroidManifest.xml")
        touch(self.repo / "games" / "space" / "project.godot")
        touch(self.repo / "games" / "space" / "export_presets.cfg", GODOT_PRESET)
        touch(self.repo / "tools" / "flutter" / "android-build-install.json",
              '{"version": 1, "backend": "custom", "executable": "flutter", "apk": "a.apk"}')
        touch(self.repo / "server" / "gradlew")  # Gradle, but not Android
        touch(self.repo / "node_modules" / "x" / "gradlew")  # skipped folder
        found = pr.discover(str(self.repo))
        by_path = {c.relative: c for c in found.candidates}
        self.assertEqual(set(by_path), {"android app", os.path.join("games", "space"),
                                        os.path.join("tools", "flutter"), "server"})
        self.assertEqual(by_path["android app"].kind, "Gradle")
        self.assertTrue(by_path["android app"].recommended)
        self.assertEqual(by_path[os.path.join("games", "space")].kind, "Godot")
        self.assertEqual(by_path[os.path.join("tools", "flutter")].kind, "Custom build")
        self.assertFalse(by_path["server"].recommended)
        self.assertIn("AndroidManifest", by_path["server"].note)
        self.assertFalse(found.truncated)

    def test_godot_without_android_preset_is_not_recommended(self):
        touch(self.repo / "project.godot")
        candidate = pr.discover(str(self.repo)).candidates[0]
        self.assertEqual(candidate.relative, ".")
        self.assertFalse(candidate.recommended)
        self.assertIn("export preset", candidate.note)

    def test_a_project_owns_its_subtree(self):
        touch(self.repo / "project.godot")
        touch(self.repo / "android" / "build" / "gradlew")
        touch(self.repo / "android" / "gradlew")
        self.assertEqual([c.relative for c in pr.discover(str(self.repo)).candidates], ["."])

    def test_module_folder_offers_the_enclosing_project(self):
        touch(self.repo / "gradlew")
        module = self.repo / "app" / "src"
        touch(module / "main" / "AndroidManifest.xml")
        found = pr.discover(str(module))
        self.assertEqual(len(found.candidates), 1)
        self.assertTrue(found.candidates[0].outside)
        self.assertEqual(found.candidates[0].path, str(self.repo.resolve()))

    def test_depth_and_folder_limits(self):
        touch(self.repo / "a" / "b" / "c" / "d" / "e" / "gradlew")
        self.assertEqual(pr.discover(str(self.repo)).candidates, [])
        for index in range(30):
            (self.repo / f"folder {index:02}").mkdir()
        found = pr.discover(str(self.repo), folder_limit=10)
        self.assertTrue(found.truncated)

    def test_invalid_config_is_listed_with_a_note(self):
        touch(self.repo / "android-build-install.json", "{not json")
        candidate = pr.discover(str(self.repo)).candidates[0]
        self.assertFalse(candidate.recommended)
        self.assertIn("errors", candidate.note)


class NameTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        patcher = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(Path(self.temp.name) / "config")})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.project = Path(self.temp.name) / "chess app"
        self.project.mkdir()

    def test_rename_and_reset(self):
        self.assertEqual(pr.display_name(str(self.project)), "chess app")
        self.assertEqual(pr.set_name(str(self.project), "  Chatturanga \n (phone)  "), "Chatturanga (phone)")
        self.assertEqual(pr.display_name(str(self.project)), "Chatturanga (phone)")
        self.assertEqual(pr.set_name(str(self.project), ""), "chess app")
        self.assertEqual(pr.load_names(), {})

    def test_folder_name_is_not_stored_and_long_names_are_capped(self):
        pr.set_name(str(self.project), "chess app")
        self.assertEqual(pr.load_names(), {})
        self.assertEqual(len(pr.set_name(str(self.project), "x" * 200)), pr.NAME_LIMIT)

    def test_corrupt_names_file_is_ignored(self):
        pr.names_path().parent.mkdir(parents=True, exist_ok=True)
        pr.names_path().write_text("[1, 2]", encoding="utf-8")
        self.assertEqual(pr.display_name(str(self.project)), "chess app")


class ScopeTests(unittest.TestCase):
    def test_selected_or_all(self):
        everything = ["/a", "/b", "/c"]
        self.assertEqual(pr.refresh_targets(everything, []), everything)
        self.assertEqual(pr.refresh_targets(everything, ["/c", "/a"]), ["/a", "/c"])
        self.assertEqual(pr.refresh_targets(everything, ["/gone"]), everything)

    def test_labels(self):
        self.assertEqual(pr.refresh_label(0), "Refresh All")
        self.assertEqual(pr.refresh_label(1), "Refresh Selected")
        self.assertEqual(pr.refresh_label(3), "Refresh 3 Selected")


if __name__ == "__main__":
    unittest.main()
