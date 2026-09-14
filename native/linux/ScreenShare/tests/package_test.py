"""Permission-free packaging contract tests using a real built ELF helper."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PackageTest(unittest.TestCase):
    def check_archive(self, mutate=None, architecture=None):
        with tempfile.TemporaryDirectory(prefix="osa-wayland-negative-") as temp:
            root = Path(temp)
            helper_dir = root / "release/lib/optimal_system_agent-1.0.197/priv/helpers"
            subprocess.run(["bash", str(ROOT / "stage.sh"), str(helper_dir)], check=True, capture_output=True)
            archive = root / "release.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                for path in helper_dir.iterdir():
                    info = tar.gettarinfo(str(path), arcname="./lib/optimal_system_agent-1.0.197/priv/helpers/" + path.name)
                    payload = path.read_bytes()
                    if mutate:
                        result = mutate(info, payload)
                        if result is None:
                            continue
                        info, payload = result
                    tar.addfile(info, io.BytesIO(payload) if info.isfile() else None)
            return subprocess.run(
                ["bash", str(ROOT / "verify-package.sh"), str(archive), architecture or os.environ["OSA_TEST_ARCH"]],
                capture_output=True, text=True,
            )

    def test_real_helper_survives_staging_and_archive_verification(self):
        with tempfile.TemporaryDirectory(prefix="osa-wayland-package-") as temp:
            root = Path(temp)
            helper_dir = root / "release/lib/optimal_system_agent-1.0.197/priv/helpers"
            helper_dir.mkdir(parents=True)
            staged = subprocess.run(
                ["bash", str(ROOT / "stage.sh"), str(helper_dir)],
                cwd=temp, capture_output=True, text=True,
            )
            self.assertEqual(staged.returncode, 0, staged.stderr)
            archive = root / "osa-linux.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(root / "release/lib", arcname="./lib")
            checked = subprocess.run(
                ["bash", str(ROOT / "verify-package.sh"), str(archive), os.environ["OSA_TEST_ARCH"]],
                cwd=temp, capture_output=True, text=True,
            )
            self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_missing_helper_is_not_a_valid_release(self):
        result = self.check_archive(lambda info, payload: None if info.name.endswith("/osa-screen-capture-wayland") else (info, payload))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one", result.stderr)

    def test_stale_helper_is_rejected_even_when_it_is_executable(self):
        def stale(info, payload):
            if info.name.endswith("/osa-screen-capture-wayland"):
                payload = payload[:-1] + bytes([payload[-1] ^ 1])
            return info, payload
        result = self.check_archive(stale)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from the current build", result.stderr)

    def test_link_to_helper_outside_release_is_rejected(self):
        def linked(info, payload):
            if info.name.endswith("/osa-screen-capture-wayland"):
                info.type = tarfile.SYMTYPE
                info.linkname = "/tmp/not-packaged"
                info.size = 0
            return info, payload
        result = self.check_archive(linked)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("regular file", result.stderr)

    def test_wrong_architecture_is_rejected(self):
        wrong = "x64" if os.environ["OSA_TEST_ARCH"] == "arm64" else "arm64"
        result = self.check_archive(architecture=wrong)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("architecture", result.stderr)

    def test_missing_runtime_documentation_is_rejected(self):
        result = self.check_archive(lambda info, payload: None if info.name.endswith(".runtime.md") else (info, payload))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime requirements", result.stderr)

    def test_staging_without_a_build_does_not_create_a_destination(self):
        with tempfile.TemporaryDirectory(prefix="osa-wayland-no-build-") as temp:
            destination = Path(temp) / "helpers"
            result = subprocess.run(
                ["bash", str(ROOT / "stage.sh"), str(destination)],
                env={**os.environ, "CARGO_TARGET_DIR": str(Path(temp) / "missing-target")},
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Missing built helper", result.stderr)
            self.assertFalse(destination.exists())

    def test_relative_build_target_is_rejected_without_guessing_cwd(self):
        with tempfile.TemporaryDirectory(prefix="osa-wayland-relative-target-") as temp:
            result = subprocess.run(
                ["bash", str(ROOT / "stage.sh"), str(Path(temp) / "helpers")],
                env={**os.environ, "CARGO_TARGET_DIR": "target"},
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be absolute", result.stderr)


if __name__ == "__main__":
    unittest.main()
