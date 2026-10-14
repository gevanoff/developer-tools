"""Exercise launcher upgrades without touching the user's actual XDG paths."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class DesktopInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="DroidRun upgrade ")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.data = self.home / "XDG data with spaces"
        self.apps = self.data / "applications"
        self.apps.mkdir(parents=True)
        self.legacy = self.apps / "android-build-install.desktop"
        self.desktop = self.apps / "droidrun.desktop"
        self.bin = self.home / ".local/bin"
        self.env = dict(os.environ, HOME=str(self.home), XDG_DATA_HOME=str(self.data))

    def install(self):
        return subprocess.run(["bash", str(ROOT / "install-desktop.sh")],
                              env=self.env, capture_output=True, text=True)

    def old_entry(self, root):
        return (
            "[Desktop Entry]\nType=Application\nName=DroidRun\n"
            f"Icon={root}/android_build_install_linux/assets/droidrun-icon.png\n"
            "Comment=Build, sync, install, and launch Android projects\n"
            f'Exec="{self.bin}/android-build-install" %f\n'
            "Terminal=false\nCategories=Development;\nStartupNotify=true\n"
        )

    def test_upgrade_and_reinstall(self):
        for root in (ROOT, ROOT.parent / "android-build-install-linux"):
            with self.subTest(root=root):
                self.legacy.write_text(self.old_entry(root))
                self.assertEqual(self.install().returncode, 0)
                self.assertFalse(self.legacy.exists())
                self.assertTrue(self.desktop.is_file())
                for command in ("droidrun", "android-build-install"):
                    self.assertEqual((self.bin / command).resolve(), ROOT / "droidrun")
                self.assertIn(f'Exec="{self.bin}/droidrun" %f', self.desktop.read_text())
                self.assertEqual(self.install().returncode, 0)
                self.assertEqual(list(self.apps.glob("*.desktop")), [self.desktop])

    def test_preserves_customized_or_unrelated_entries(self):
        for content in (self.old_entry(ROOT) + "# user customization\n",
                        self.old_entry(ROOT.parent / "other checkout")):
            with self.subTest(content=content):
                self.legacy.write_text(content)
                self.assertEqual(self.install().returncode, 0)
                self.assertEqual(self.legacy.read_text(), content)

    def test_preserves_symlink(self):
        target = self.home / "custom.desktop"
        target.write_text(self.old_entry(ROOT))
        self.legacy.symlink_to(target)
        self.assertEqual(self.install().returncode, 0)
        self.assertTrue(self.legacy.is_symlink())
        self.assertEqual(target.read_text(), self.old_entry(ROOT))

    def test_failed_replacement_preserves_legacy(self):
        content = self.old_entry(ROOT.parent / "android-build-install-linux")
        self.legacy.write_text(content)
        self.desktop.mkdir()  # Replacement write fails even when tests run as root.
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(self.legacy.read_text(), content)

    def test_backend_guide_link_exists(self):
        self.assertIn("../DroidRun/BUILD-BACKENDS.md", (ROOT / "README.md").read_text())
        self.assertTrue((ROOT / "../DroidRun/BUILD-BACKENDS.md").is_file())
