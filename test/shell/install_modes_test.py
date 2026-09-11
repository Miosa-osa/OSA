#!/usr/bin/env python3
"""Run the real installer/launcher offline with checksummed release fixtures.

These tests cover shell control flow, not native runtime compatibility.
See docs/headless-install.md for the separate real-artifact acceptance gate.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[2] / "scripts/install.sh"

# A port this suite owns. Deliberately NOT `install.sh`'s 9089 default: see the
# OSA_PORT entry in `setUp`. Any value works as long as it is not a port a real
# OSA daemon would be using.
TEST_PORT = 19393


class InstallModesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="osa-install-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.osa = self.home / ".osa"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.requests = self.root / "requests"
        self.calls = self.root / "calls"
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home), "OSA_HOME": str(self.osa),
            # NOT the default. `install.sh` resolves `PORT="${OSA_PORT:-9089}"`,
            # and `daemon_pid/0` falls back to `lsof -ti :$PORT` when the sandbox
            # has no pidfile — which it never does. Left unset, this suite
            # therefore asks `lsof` who is listening on 9089 and finds the
            # DEVELOPER'S OWN RUNNING DAEMON, which `stop_daemon` then kills with
            # `kill -TERM -- -$pid`. Measured on 2026-09-11: running this file on
            # a host with a live OSA daemon terminated that daemon mid-session.
            "OSA_PORT": str(TEST_PORT),
            "SHELL": "/bin/bash", "LANG": "C.UTF-8",
            "FIXTURE_ROOT": str(self.root), "INSTALLER": str(INSTALLER),
        }
        self.script(self.bin / "uname", 'case "$1" in -s) echo Linux;; -m) echo x86_64;; esac')
        # `lsof` reports NOTHING, which is the truth: the sandbox has no daemon.
        # This is the second half of the isolation and the load-bearing one —
        # a unique port only helps until something happens to listen on it,
        # whereas a stubbed `lsof` makes `daemon_pid/0` resolve to empty no
        # matter what is running on the host. Without it, `stop_daemon` can
        # reach a process outside the sandbox.
        self.script(self.bin / "lsof", "exit 1")
        # Full installs finish by attaching to a healthy fixture, never a real daemon.
        self.script(self.bin / "curl", r'''
import json, os, pathlib, shutil, sys
r = pathlib.Path(os.environ['FIXTURE_ROOT'])
args = sys.argv[1:]
url = next(a for a in args if a.startswith(('https://', 'http://')))
with (r / 'requests').open('a') as f: f.write(url+'\n')
dest = pathlib.Path(args[args.index('-o')+1]) if '-o' in args else None
if '/health' in url:
    print(json.dumps({'status':'ok', 'version': (r/'latest').read_text().strip()[1:]}))
    sys.exit(0)
if '/releases/latest' in url:
    dest.write_text(json.dumps({'tag_name': (r/'latest').read_text().strip(), 'body': 'fixture notes'}))
elif url.endswith('/scripts/install.sh'):
    source = pathlib.Path(os.environ.get('FIXTURE_INSTALLER', os.environ['INSTALLER']))
    shutil.copyfile(source, dest)
else:
    version, name = url.split('/')[-2:]
    source = r/version/name
    if not source.exists(): sys.exit(22)
    shutil.copyfile(source, dest)
''', python=True)
        for version in ("1.0.194", "1.0.195"):
            assets = self.root / f"v{version}"
            assets.mkdir()
            release = self.root / f"release-{version}"
            (release / "bin").mkdir(parents=True)
            self.script(release / "bin/osagent", f'''
echo "backend $*" >> "$FIXTURE_ROOT/calls"
case "$1" in version) echo "osagent v{version}";; esac
''')
            with tarfile.open(assets / "osa-linux-x64.tar.gz", "w:gz") as tar:
                tar.add(release / "bin", arcname="bin")
            self.script(assets / "osagent-tui-linux-x64", f'''
echo "tui $*" >> "$FIXTURE_ROOT/calls"
if [ "${{FAIL_TUI:-}}" = 1 ]; then echo 'libasound.so.2: not found' >&2; exit 127; fi
if [ "${{1:-}}" = --version ]; then echo 'osagent-tui {version}'; fi
''')
            for name in ("osa-linux-x64.tar.gz", "osagent-tui-linux-x64"):
                checksum = hashlib.sha256((assets / name).read_bytes()).hexdigest()
                (assets / (name + ".sha256")).write_text(f"{checksum}  {name}\n")
        (self.root / "latest").write_text("v1.0.195\n")

    def script(self, path, body, python=False):
        path.write_text((f"#!{sys.executable}\n" if python else "#!/bin/sh\n") + body + "\n")
        path.chmod(0o755)

    def call(self, args, expected=0, **env):
        result = subprocess.run(args, env=self.env | env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
        self.assertEqual(result.returncode, expected, result.stdout)
        return result.stdout

    def install(self, **env):
        return self.call(["sh", str(INSTALLER)], OSA_VERSION="v1.0.195", **env)

    def cli(self, *args, expected=0, **env):
        return self.call([str(self.osa / "bin/osa"), *args], expected, **env)

    def assert_headless(self):
        self.assertEqual((self.osa / "install_mode").read_text(), "headless\n")
        self.assertFalse((self.osa / "bin/osagent-tui").exists())
        self.assertNotIn("osagent-tui-", self.requests.read_text())
        self.assertNotIn("tui ", self.calls.read_text() if self.calls.exists() else "")

    def test_fresh_headless_without_tui_dependencies_and_no_implicit_daemon(self):
        self.call(["bash", str(INSTALLER)], OSA_VERSION="v1.0.195", OSA_INSTALL_MODE="headless", FAIL_TUI="1")
        self.assertFalse((self.home / ".bashrc").exists())
        self.cli("opencomputers", "login", "--key", "oc_host_fixture")
        self.cli("serve")
        output = self.cli("version")
        self.assertIn("headless", output)
        self.assertNotIn("repair", output)
        before = self.calls.read_text()
        for args in ((), ("resume",), ("--overdrive",)):
            self.assertIn("headless", self.cli(*args, expected=1))
        self.assertEqual(self.calls.read_text(), before)
        self.assertFalse((self.osa / "run/backend.pid").exists())
        self.assert_headless()

    def test_reinstall_and_same_version_update_preserve_headless(self):
        self.install(OSA_INSTALL_MODE="headless")
        self.install(FAIL_TUI="1")
        self.cli("update", FAIL_TUI="1")
        self.assert_headless()

    def test_headless_upgrade_and_launcher_reexec(self):
        self.call(["sh", str(INSTALLER)], OSA_INSTALL_MODE="headless", OSA_VERSION="v1.0.194")
        launcher = self.osa / "bin/osa"
        launcher.write_text(launcher.read_text() + "\n# previous launcher\n")
        self.cli("update", FAIL_TUI="1")
        self.assertEqual((self.osa / "version").read_text(), "v1.0.195\n")
        self.assertIn("v1.0.195", self.cli("version"))
        self.assert_headless()

    def test_full_remains_default_and_missing_tui_is_repaired(self):
        self.install()
        self.assertEqual((self.osa / "install_mode").read_text(), "full\n")
        (self.osa / "bin/osagent-tui").unlink()
        self.cli("update")
        self.assertTrue((self.osa / "bin/osagent-tui").exists())
        self.assertIn("tui ", self.calls.read_text())

    def test_full_upgrade_keeps_both_components(self):
        self.call(["sh", str(INSTALLER)], OSA_VERSION="v1.0.194")
        self.cli("update")
        self.assertEqual((self.osa / "version").read_text(), "v1.0.195\n")
        self.assertIn("osagent-tui 1.0.195", self.cli("version"))
        self.assertEqual((self.osa / "install_mode").read_text(), "full\n")

    def test_explicit_full_reinstall_adds_tui(self):
        self.install(OSA_INSTALL_MODE="headless")
        self.install(OSA_INSTALL_MODE="full")
        self.assertEqual((self.osa / "install_mode").read_text(), "full\n")
        self.assertTrue((self.osa / "bin/osagent-tui").exists())

    def test_explicit_headless_preserves_existing_tui_and_profile(self):
        self.install()
        tui = (self.osa / "bin/osagent-tui").read_bytes()
        profile = (self.home / ".bashrc").read_bytes()
        self.requests.write_text("")
        self.calls.write_text("")
        self.install(OSA_INSTALL_MODE="headless", FAIL_TUI="1")
        self.cli("update", FAIL_TUI="1")
        self.assertEqual((self.osa / "bin/osagent-tui").read_bytes(), tui)
        self.assertEqual((self.home / ".bashrc").read_bytes(), profile)
        self.assertEqual((self.osa / "install_mode").read_text(), "headless\n")
        self.assertNotIn("osagent-tui-", self.requests.read_text())
        self.assertNotIn("tui ", self.calls.read_text())

    def test_legacy_full_reinstall_and_update_remain_full(self):
        self.install()
        (self.osa / "install_mode").unlink()
        self.install()
        self.assertEqual((self.osa / "install_mode").read_text(), "full\n")
        (self.osa / "install_mode").unlink()
        self.cli("update")
        self.assertEqual((self.osa / "install_mode").read_text(), "full\n")

    def test_headless_refuses_launcher_without_mode_support(self):
        self.install(OSA_INSTALL_MODE="headless")
        old = self.root / "old-install.sh"
        old.write_text(INSTALLER.read_text().replace("# OSA_HEADLESS_INSTALL_V1:", "# old launcher:"))
        before = (self.osa / "bin/osa").read_bytes()
        self.assertIn("does not support headless", self.cli("update", expected=3, FIXTURE_INSTALLER=str(old)))
        self.assertEqual((self.osa / "bin/osa").read_bytes(), before)
        self.assert_headless()
        self.call(["sh", str(INSTALLER)], OSA_VERSION="v1.0.194")
        self.cli("update", expected=3, FIXTURE_INSTALLER=str(old))
        self.assertEqual((self.osa / "version").read_text(), "v1.0.194\n")
        self.assertIn("v1.0.194", self.cli("version"))

    def test_saved_invalid_mode_fails_closed(self):
        self.install(OSA_INSTALL_MODE="headless")
        (self.osa / "install_mode").write_text("typo\n")
        self.requests.write_text("")
        self.call(["sh", str(INSTALLER)], expected=1)
        self.cli("update", expected=1)
        self.assertEqual(self.requests.read_text(), "")

    def test_headless_update_requires_valid_checksum_before_swap(self):
        self.call(["sh", str(INSTALLER)], OSA_INSTALL_MODE="headless", OSA_VERSION="v1.0.194")
        asset = self.root / "v1.0.195/osa-linux-x64.tar.gz.sha256"
        for contents in ("0" * 64 + "  osa-linux-x64.tar.gz\n", None):
            if contents is None:
                asset.unlink()
            else:
                asset.write_text(contents)
            self.cli("update", expected=3)
            self.assertEqual((self.osa / "version").read_text(), "v1.0.194\n")
            self.assertIn("v1.0.194", self.cli("version"))
        self.assert_headless()

    def test_full_still_fails_for_missing_native_tui_library(self):
        self.call(["sh", str(INSTALLER)], expected=3, OSA_VERSION="v1.0.195", FAIL_TUI="1")
        self.assertFalse((self.osa / "install_mode").exists())

    def test_invalid_mode_fails_before_download_or_install(self):
        self.call(["sh", str(INSTALLER)], expected=1, OSA_INSTALL_MODE="typo")
        self.assertFalse(self.requests.exists())
        self.assertFalse(self.osa.exists())

    def test_headless_rejects_bad_or_missing_checksum(self):
        asset = self.root / "v1.0.195/osa-linux-x64.tar.gz.sha256"
        asset.write_text("0" * 64 + "  osa-linux-x64.tar.gz\n")
        self.call(["sh", str(INSTALLER)], expected=3, OSA_INSTALL_MODE="headless", OSA_VERSION="v1.0.195")
        self.assertFalse((self.osa / "install_mode").exists())
        asset.unlink()
        self.call(["sh", str(INSTALLER)], expected=3, OSA_INSTALL_MODE="headless", OSA_VERSION="v1.0.195")
        self.assertFalse((self.osa / "install_mode").exists())


    def test_suite_cannot_reach_a_daemon_outside_the_sandbox(self):
        """A full install cycle must not kill a process the sandbox does not own.

        MEASURED, 2026-09-11: this suite terminated a developer's live OSA daemon
        on :9089. The chain was `OSA_HOME` pointed at a temp dir (so no pidfile)
        -> `daemon_pid/0` fell back to `lsof -ti :9089` -> `lsof` was the REAL
        one, not a stub -> it found the host's daemon -> `stop_daemon` ran
        `kill -TERM -- -$pid`.

        So this test puts a real listener on the port the sandbox is configured
        to use and asserts it is STILL LISTENING after a complete install. It
        fails if the port is left at the default with a live daemon there, and
        it fails if `lsof` is ever un-stubbed — the two halves of the fix.
        """
        import socket

        sentinel = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sentinel.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.addCleanup(sentinel.close)
        sentinel.bind(("127.0.0.1", TEST_PORT))
        sentinel.listen(1)

        # The sandbox must be pointed somewhere other than install.sh's default.
        self.assertIn("OSA_PORT", self.env,
                      "the sandbox env must pin OSA_PORT; without it install.sh "
                      "resolves PORT=9089 and can reach a host daemon")
        self.assertNotEqual(str(self.env["OSA_PORT"]), "9089",
                            "the sandbox must not use install.sh's default port")

        self.install(OSA_INSTALL_MODE="headless")
        self.assert_headless()

        # Still listening: nothing in the cycle touched a process it does not own.
        self.assertEqual(sentinel.getsockname()[1], TEST_PORT)
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe.settimeout(2)
        try:
            probe.connect(("127.0.0.1", TEST_PORT))
        except OSError as exc:
            self.fail(f"the sandbox's install cycle killed a listener it did not "
                      f"own on :{TEST_PORT} ({exc})")
        finally:
            probe.close()

if __name__ == "__main__":
    unittest.main(verbosity=2)
