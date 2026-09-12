"""Real helper IPC tests. Never supplies a bootable image or starts a VM."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class HelperProtocol(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "owned"
        self.cache = Path(self.temp.name) / "cache"
        self.root.mkdir(mode=0o700)
        self.cache.mkdir(mode=0o700)
        self.args = [BINARY, "--root", str(self.root), "--artifacts", str(self.cache),
                     "--max-cpus", "2", "--max-memory-mib", "1024", "--max-disk-mib", "128"]
        self.process = subprocess.Popen(self.args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def tearDown(self):
        self.process.communicate(timeout=15)
        self.temp.cleanup()

    def request(self, operation, **fields):
        request = dict(version=1, id="test", operation=operation, **fields)
        self.process.stdin.write(json.dumps(request).encode() + b"\n")
        self.process.stdin.flush()
        import select
        ready, _, _ = select.select([self.process.stdout], [], [], 5)
        self.assertTrue(ready, "helper response deadline")
        return json.loads(self.process.stdout.readline())

    def test_probe_never_claims_guest_ready(self):
        reply = self.request("probe")
        self.assertEqual(reply["id"], "test")
        self.assertEqual(reply["result"]["backend"], "apple_virtualization")
        self.assertFalse(reply["result"]["guest_ready"])
        self.assertEqual([p.name for p in self.root.iterdir()], [".owner.lock"])

    def test_missing_artifact_fails_without_retaining_workload(self):
        identity = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        reply = self.request("create", workload_id=identity, metadata=dict(
            backend="apple_virtualization", architecture="arm64", kernel_sha256="a" * 64,
            rootfs_sha256="b" * 64, vcpu_count=1, memory_mib=512, disk_mib=64))
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["error"], "missingArtifact")
        self.assertFalse((self.root / identity).exists())

    def test_capacity_rejected_before_side_effects(self):
        identity = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        reply = self.request("create", workload_id=identity, metadata=dict(
            backend="apple_virtualization", architecture="arm64", kernel_sha256="a" * 64,
            rootfs_sha256="b" * 64, vcpu_count=3, memory_mib=512, disk_mib=64))
        self.assertEqual(reply["error"], "capacityExceeded")
        self.assertFalse((self.root / identity).exists())

    def test_delete_preserves_unowned_directory(self):
        identity = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        path = self.root / identity
        path.mkdir(mode=0o700)
        (path / "personal.txt").write_text("preserve")
        self.assertFalse(self.request("delete", workload_id=identity)["ok"])
        self.assertEqual((path / "personal.txt").read_text(), "preserve")

    def test_single_owner_lock(self):
        self.request("probe")
        second = subprocess.run(self.args, input=b"", capture_output=True, timeout=5)
        self.assertEqual(second.returncode, 78)

    def test_revocation_preserves_files(self):
        (self.root / "keep").write_text("preserve")
        result = self.request("stop_all")["result"]
        self.assertTrue(result["disks_preserved"])
        self.assertEqual((self.root / "keep").read_text(), "preserve")

    def test_oversized_input_terminates(self):
        self.process.stdin.write(b"x" * 16385)
        self.process.stdin.flush()
        self.assertEqual(self.process.wait(timeout=5), 65)


if __name__ == "__main__":
    unittest.main()
