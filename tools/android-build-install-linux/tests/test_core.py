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

    def test_preferred_release_apk_is_honored_even_with_debug_output(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            debug = root / "app" / "build" / "outputs" / "apk" / "debug"
            release = root / "app" / "build" / "outputs" / "apk" / "release"
            debug.mkdir(parents=True)
            release.mkdir(parents=True)
            (debug / "app-debug.apk").write_bytes(b"debug")
            preferred = release / "app-release.apk"
            preferred.write_bytes(b"release")
            pref = core.Preferences(preferred_apk=str(preferred))
            self.assertEqual(core.deterministic_apk(str(root), root, pref), preferred)

    def test_git_fetch_failure_is_not_silently_ignored(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess = __import__("subprocess")
            subprocess.run(["git", "init", str(root)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(root), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.name", "Test"], check=True)
            (root / "README").write_text("x", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "README"], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-m", "init"], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(root), "remote", "add", "origin", "/definitely/missing/repo"], check=True)
            branch = subprocess.run(["git", "-C", str(root), "branch", "--show-current"], check=True, capture_output=True, text=True).stdout.strip()
            subprocess.run(["git", "-C", str(root), "config", f"branch.{branch}.remote", "origin"], check=True)
            subprocess.run(["git", "-C", str(root), "config", f"branch.{branch}.merge", f"refs/heads/{branch}"], check=True)
            with self.assertRaises(core.ToolError):
                core.git_status(str(root), fetch=True)

    def test_process_controller_terminates_process_group(self):
        subprocess = __import__("subprocess")
        proc = subprocess.Popen(["sleep", "30"], start_new_session=True)
        controller = core.ProcessController()
        try:
            controller.attach(proc)
            controller.cancel()
            proc.wait(timeout=5)
            self.assertNotEqual(proc.returncode, 0)
            self.assertTrue(controller.cancelled)
        finally:
            if proc.poll() is None:
                proc.kill()

    def test_freshness_scan_skips_directory_symlink_cycles(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "src").mkdir()
            source = root / "src" / "main.txt"
            source.write_text("x", encoding="utf-8")
            (root / "src" / "loop").symlink_to(root, target_is_directory=True)
            self.assertGreaterEqual(core.newest_project_input_mtime(str(root)), source.stat().st_mtime)

    def test_freshness_scan_follows_symlinked_file_target(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            external = root.parent / f"{root.name}-external.txt"
            external.write_text("linked input", encoding="utf-8")
            try:
                link = root / "linked-input.txt"
                link.symlink_to(external)
                self.assertGreaterEqual(core.newest_project_input_mtime(str(root)), external.stat().st_mtime)
            finally:
                external.unlink(missing_ok=True)

    def test_git_fetch_receives_cancellation_controller(self):
        controller = core.ProcessController()
        responses = [
            __import__("subprocess").CompletedProcess([], 0, "/tmp/repo\n", ""),
            __import__("subprocess").CompletedProcess([], 0, "", ""),
            __import__("subprocess").CompletedProcess([], 0, "", ""),
            __import__("subprocess").CompletedProcess([], 0, "origin/main\n", ""),
            __import__("subprocess").CompletedProcess([], 0, "0 0\n", ""),
        ]
        seen = []

        def fake_run(argv, **kwargs):
            seen.append((argv, kwargs))
            return responses.pop(0)

        with mock.patch.object(core, "run", side_effect=fake_run):
            self.assertEqual(core.git_status("/tmp/repo", fetch=True, controller=controller)[0], "Current")
        fetch_calls = [item for item in seen if "fetch" in item[0]]
        self.assertEqual(len(fetch_calls), 1)
        self.assertIs(fetch_calls[0][1].get("controller"), controller)

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
