import json
import os
import subprocess
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

from android_build_install_linux import backends, core


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="android project with spaces ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def config(self, **values):
        (self.root / backends.CONFIG).write_text(json.dumps({"version": 1, **values}))

    def godot(self):
        (self.root / "project.godot").write_text("config_version=5\n")
        (self.root / "export_presets.cfg").write_text(
            '[preset.0]\nname="Android Debug"\nplatform="Android"\n'
            '[preset.0.options]\nkeystore/debug=""\n'
            '[preset.1]\nname="Web"\nplatform="Web"\n')

    def executable(self, name, body):
        path = self.root / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)
        return str(path)

    def run_build(self, *, sync=False):
        calls = []
        actual_run = core.run

        def run(argv, **kwargs):
            if argv[0] == "fake-adb":
                calls.append(argv)
                return subprocess.CompletedProcess(argv, 0, "", "")
            return actual_run(argv, **kwargs)

        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(core, "load_preferences", return_value=core.Preferences(auto_launch=False)))
            stack.enter_context(mock.patch.object(core, "resolve_adb", return_value="fake-adb"))
            stack.enter_context(mock.patch.object(core, "resolve_device", return_value=core.Device("serial", "device", "test")))
            stack.enter_context(mock.patch.object(core, "package_id", return_value=None))
            stack.enter_context(mock.patch.object(core, "log_file", return_value=self.root / "test.log"))
            stack.enter_context(mock.patch.object(core, "java_env", side_effect=AssertionError("Non-Gradle must not require Java")))
            stack.enter_context(mock.patch.object(core, "run", side_effect=run))
            core.build_install(str(self.root), sync=sync, force_build=not sync)
        return calls

    def test_godot_owns_nested_generated_gradle(self):
        self.godot()
        nested = self.root / "android" / "build"
        nested.mkdir(parents=True)
        (nested / "gradlew").touch()
        plan = backends.select_plan(str(self.root))
        self.assertEqual(plan.backend, "godot")
        self.assertEqual(plan.arguments[-2], "Android Debug")
        self.assertEqual(plan.apk, self.root / "build/android/app-debug.apk")

    def test_missing_and_ambiguous_presets_are_actionable(self):
        (self.root / "project.godot").touch()
        with self.assertRaisesRegex(backends.BackendError, "Project > Export"):
            backends.select_plan(str(self.root))
        self.godot()
        with (self.root / "export_presets.cfg").open("a") as f:
            f.write('[preset.2]\nname="Other Android"\nplatform="Android"\n')
        with self.assertRaisesRegex(backends.BackendError, "set preset"):
            backends.select_plan(str(self.root))
        self.config(backend="godot", preset="Other Android")
        self.assertEqual(backends.select_plan(str(self.root)).arguments[-2], "Other Android")

    def test_multiple_sibling_roots_fail_and_symlink_cycle_is_skipped(self):
        for name in ("one", "two"):
            directory = self.root / name
            directory.mkdir()
            (directory / "project.godot").touch()
        (self.root / "loop").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(backends.BackendError, "Multiple build roots"):
            backends.select_plan(str(self.root))

    def test_invalid_config_and_non_apk_output_rejected(self):
        for values in ({"backend": "unknown"}, {"backend": "custom", "apk": "app.aab"},
                       {"backend": "custom", "apk": "app.apk", "arguments": "shell string"}):
            self.config(**values)
            with self.assertRaises(backends.BackendError):
                backends.select_plan(str(self.root))
        (self.root / backends.CONFIG).write_text("{")
        with self.assertRaisesRegex(backends.BackendError, "Invalid"):
            backends.select_plan(str(self.root))

    def test_platform_override_and_exact_output(self):
        self.config(backend="custom", executable="unused", apk="out/test.apk",
                    linux={"executable": "/bin/echo", "arguments": ["literal $HOME; hi"]})
        plan = backends.select_plan(str(self.root))
        self.assertEqual(backends.command(plan, "ignored"), [str(Path("/bin/echo").resolve()), "literal $HOME; hi"])
        self.assertIsNone(core.deterministic_apk(str(self.root), self.root, core.Preferences()))
        plan.apk.parent.mkdir()
        plan.apk.write_bytes(b"apk")
        self.assertEqual(core.deterministic_apk(str(self.root), self.root, core.Preferences()), plan.apk)
        with self.assertRaisesRegex(core.ToolError, "conflicts"):
            core.deterministic_apk(str(self.root), self.root, core.Preferences(preferred_apk="other.apk"))

    def test_custom_build_install_with_spaces_and_literal_arguments(self):
        exe = self.executable("fake builder", """import sys
from pathlib import Path
assert sys.argv[1] == 'literal $HOME; value with spaces'
assert Path.cwd() == Path(__file__).parent
Path('output dir/test.apk').write_bytes(b'new apk')
""")
        self.config(backend="custom", executable=Path(exe).name, arguments=["literal $HOME; value with spaces"], apk="output dir/test.apk")
        calls = self.run_build(sync=True)
        self.assertEqual(calls, [["fake-adb", "-s", "serial", "install", "-r", str(self.root / "output dir/test.apk")]])
        self.assertEqual(core.build_status(str(self.root), self.root, core.Preferences())[0], "Stale")

    def test_godot_export_invocation_and_install(self):
        self.godot()
        exe = self.executable("fake godot", """import sys
from pathlib import Path
assert sys.argv[1:3] == ['--headless', '--path']
assert sys.argv[4:6] == ['--export-debug', 'Android Debug']
assert sys.argv[3] == str(Path.cwd())
Path(sys.argv[6]).write_bytes(b'godot apk')
""")
        self.config(backend="godot", executable=exe)
        self.assertEqual(len(self.run_build()), 1)

    def test_godot_freshness_ignores_cache_but_tracks_project_inputs(self):
        self.godot()
        apk = self.root / "build/android/app-debug.apk"
        apk.parent.mkdir(parents=True)
        apk.write_bytes(b"apk")
        stamp = max(path.stat().st_mtime for path in self.root.iterdir()) + 10
        os.utime(apk, (stamp, stamp))
        status = lambda: core.build_status(str(self.root), self.root, core.Preferences())[0]
        self.assertEqual(status(), "Fresh")
        for cache in (".godot", ".import"):
            path = self.root / cache / "cache.txt"
            path.parent.mkdir()
            path.write_text("generated")
            os.utime(path, (stamp + 10, stamp + 10))
        self.assertEqual(status(), "Fresh")
        for name in ("project.godot", "export_presets.cfg", "lesson.gd", "words.json", "texture.png"):
            path = self.root / name
            if not path.exists():
                path.write_text("input")
            os.utime(path, (stamp + 1, stamp + 1))
            self.assertEqual(status(), "Stale", name)
            os.utime(path, (stamp - 1, stamp - 1))
        self.assertEqual(status(), "Fresh")
        apk.unlink()
        self.assertEqual(status(), "No APK")

    def test_godot4_precedes_generic_godot_on_path(self):
        self.godot()
        plan = backends.select_plan(str(self.root))
        with mock.patch.object(backends.shutil, "which", side_effect=lambda name: "/bin/true" if name == "godot4" else "/bin/false"):
            self.assertEqual(backends.command(plan, "ignored")[0], "/bin/true")

    def test_failed_missing_and_unchanged_outputs_never_install_or_touch_old_apk(self):
        apk = self.root / "old.apk"
        for body in ("raise SystemExit(7)\n", "pass\n"):
            apk.write_bytes(b"old apk")
            os.utime(apk, (100, 100))
            exe = self.executable("failed builder", body)
            self.config(backend="custom", executable=exe, apk="old.apk")
            with self.assertRaises(core.ToolError):
                self.run_build()
            self.assertEqual(apk.read_bytes(), b"old apk")
            self.assertEqual(apk.stat().st_mtime, 100)
        apk.unlink()
        with self.assertRaisesRegex(core.ToolError, "did not produce"):
            self.run_build()

    def test_status_explains_missing_godot_setup_without_running_builder(self):
        (self.root / "project.godot").touch()
        with mock.patch.object(core, "git_status", return_value=("Not Git", "")):
            status = core.project_status(str(self.root))
        self.assertEqual(status.build, "Configuration needed")
        self.assertIn("Project > Export", status.detail)


if __name__ == "__main__":
    unittest.main()
