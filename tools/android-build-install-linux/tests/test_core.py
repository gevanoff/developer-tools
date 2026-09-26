import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from android_build_install_linux import core


class CoreTests(unittest.TestCase):
    def test_find_nested_gradle_root(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            android = root / "android"
            android.mkdir()
            wrapper = android / "gradlew"
            wrapper.write_text("#!/bin/sh\n", encoding="utf-8")
            wrapper.chmod(0o755)
            self.assertEqual(core.find_gradle_roots(str(root)), [android])

    def test_apk_selection_prefers_conventional(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app = root / "app" / "build" / "outputs" / "apk" / "debug"
            other = root / "feature" / "build" / "outputs" / "apk" / "debug"
            app.mkdir(parents=True)
            other.mkdir(parents=True)
            conventional = app / "app-debug.apk"
            conventional.write_bytes(b"a")
            (other / "feature-debug.apk").write_bytes(b"b")
            self.assertEqual(core.deterministic_apk(str(root), root, core.Preferences()), conventional)

    def test_xdg_paths(self):
        with tempfile.TemporaryDirectory() as td:
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": td, "XDG_STATE_HOME": td}, clear=False):
                self.assertTrue(str(core.config_root()).startswith(td))
                self.assertTrue(str(core.state_root()).startswith(td))

    def test_sha256(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "x"
            p.write_bytes(b"abc")
            self.assertEqual(core.sha256(p), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")


if __name__ == "__main__":
    unittest.main()
