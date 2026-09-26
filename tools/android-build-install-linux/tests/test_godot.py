import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from android_build_install_linux import core


class GodotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="abi godot ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "project.godot").write_text("config_version=5\n")
        self.presets = self.root / "export_presets.cfg"
        self.presets.write_text('[preset.0]\nname="Android Debug"\nplatform="Android"\n')
        self.executable = self.root / "fake godot"
        self.executable.write_text(
            f"#!{sys.executable}\n"
            "import os, sys\nfrom pathlib import Path\n"
            "assert sys.argv[1:4] == ['--headless', '--path', str(Path.cwd())]\n"
            "assert sys.argv[4:6] == ['--export-debug', 'Android Debug']\n"
            "if not os.environ.get('NO_APK'):\n"
            "    Path(sys.argv[6]).write_bytes(b'new apk')\n"
            "sys.exit(int(os.environ.get('EXPORT_EXIT', '0')))\n"
        )
        self.executable.chmod(0o755)
        self.pref = core.Preferences(godot_executable=str(self.executable))

    def test_godot_takes_precedence_over_generated_gradle(self):
        wrapper = self.root / "android" / "build" / "gradlew"
        wrapper.parent.mkdir(parents=True)
        wrapper.touch()
        self.assertEqual(core.select_project_root(str(self.root)), self.root)

    def test_preset_selection_rejects_missing_and_ambiguous(self):
        with self.presets.open("a") as handle:
            handle.write('[preset.1]\nname="Other"\nplatform="Android"\n')
        with self.assertRaises(core.ToolError):
            core.godot_export_preset(self.root, self.pref)
        self.pref.godot_preset = "Other"
        self.assertEqual(core.godot_export_preset(self.root, self.pref), "Other")
        self.pref.godot_preset = "Missing"
        with self.assertRaises(core.ToolError):
            core.godot_export_preset(self.root, self.pref)
        self.presets.unlink()
        with self.assertRaisesRegex(core.ToolError, "Project > Export"):
            core.godot_export_preset(self.root, self.pref)

    def test_non_android_preset_and_variant_options_are_not_selected(self):
        self.presets.write_text(
            '[preset.0]\nname="Desktop"\nplatform="Linux"\n'
            '[preset.0.options]\nname="Ignore me"\n'
            '[preset.1]\nname="Android Debug"\nplatform="Android"\n'
            '[preset.1.options]\ntextures=PackedStringArray(\n"a",\n"b")\n'
        )
        self.assertEqual(core.godot_export_preset(self.root, self.pref), "Android Debug")
        self.pref.godot_preset = "Desktop"
        with self.assertRaises(core.ToolError):
            core.godot_export_preset(self.root, self.pref)

    def test_export_success_and_freshness(self):
        core.export_godot(self.root, self.pref, {}, lambda line: None)
        apk = core.deterministic_apk(str(self.root), self.root, self.pref)
        self.assertEqual(apk.read_bytes(), b"new apk")
        self.assertEqual(core.build_status(str(self.root), self.root, self.pref)[0], "Fresh")
        cache = self.root / ".godot"
        cache.mkdir()
        (cache / "cache").write_bytes(b"ignored")
        self.assertEqual(core.build_status(str(self.root), self.root, self.pref)[0], "Fresh")
        source = self.root / "source.gd"
        source.write_text("# changed")
        os.utime(source, (apk.stat().st_mtime + 10,) * 2)
        self.assertEqual(core.build_status(str(self.root), self.root, self.pref)[0], "Stale")

    def test_preset_change_invalidates_old_apk(self):
        with self.presets.open("a") as handle:
            handle.write('[preset.1]\nname="Other"\nplatform="Android"\n')
        self.pref.godot_preset = "Android Debug"
        core.export_godot(self.root, self.pref, {}, lambda line: None)
        self.pref.godot_preset = "Other"
        self.assertEqual(core.build_status(str(self.root), self.root, self.pref)[0], "Stale")

    def test_failed_missing_and_cancelled_exports_preserve_previous_apk(self):
        apk = core.godot_apk(self.root)
        apk.parent.mkdir(parents=True)
        apk.write_bytes(b"previous apk")
        previous_time = apk.stat().st_mtime_ns
        for env in ({"EXPORT_EXIT": "1"}, {"NO_APK": "1"}):
            with self.subTest(env=env), self.assertRaises(core.ToolError):
                core.export_godot(self.root, self.pref, env, lambda line: None)
            self.assertEqual(apk.read_bytes(), b"previous apk")
            self.assertEqual(apk.stat().st_mtime_ns, previous_time)
        controller = core.ProcessController()
        controller.cancel()
        with self.assertRaises(core.OperationCancelled):
            core.export_godot(self.root, self.pref, {}, lambda line: None, controller)
        self.assertEqual(apk.read_bytes(), b"previous apk")
        self.assertEqual(list(apk.parent.glob("export-*")), [])

    def test_missing_executable_has_actionable_error(self):
        self.pref.godot_executable = str(self.root / "missing")
        with self.assertRaisesRegex(core.ToolError, "Install Godot 4"):
            core.godot_command(self.pref)

    def test_build_install_routes_export_and_stops_on_failure(self):
        real_run = core.run
        installs = []

        def run(argv, **kwargs):
            if argv[0] == "fake-adb":
                installs.append(argv)
                return subprocess.CompletedProcess(argv, 0, "Success", "")
            return real_run(argv, **kwargs)

        self.pref.auto_launch = False
        with mock.patch.object(core, "load_preferences", return_value=self.pref), \
                mock.patch.object(core, "resolve_adb", return_value="fake-adb"), \
                mock.patch.object(core, "resolve_device", return_value=core.Device("phone", "device", "Phone")), \
                mock.patch.object(core, "java_env", return_value={}), \
                mock.patch.object(core, "log_file", return_value=self.root / "build/log.txt"), \
                mock.patch.object(core, "package_id", return_value=None), \
                mock.patch.object(core, "run", side_effect=run):
            (self.root / "build").mkdir()
            core.build_install(str(self.root))
            self.assertEqual(installs, [["fake-adb", "-s", "phone", "install", "-r", str(core.godot_apk(self.root))]])
            installs.clear()
            with mock.patch.dict(os.environ, {"EXPORT_EXIT": "1"}), self.assertRaises(core.ToolError):
                core.build_install(str(self.root))
            self.assertEqual(installs, [])


if __name__ == "__main__":
    unittest.main()
