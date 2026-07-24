import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = (
    Path(__file__).resolve().parents[2]
    / "scripts"
    / "sync_action_capabilities.py"
)
SPEC = importlib.util.spec_from_file_location("sync_action_capabilities", MODULE_PATH)
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class SyncActionCapabilitiesTest(unittest.TestCase):
    def test_rejects_policy_and_duplicate_aliases(self):
        with self.assertRaises(ValueError):
            SYNC.validate(
                {
                    "capabilities": [
                        {
                            "name": "sandbox.exec",
                            "fingerprint": "sha256:" + "a" * 64,
                            "risk": "write",
                            "surfaces": {"osa": ["shell_execute:miosa"]},
                        }
                    ]
                }
            )

        with self.assertRaises(ValueError):
            SYNC.validate(
                {
                    "capabilities": [
                        {
                            "name": "sandbox.exec",
                            "fingerprint": "sha256:" + "a" * 64,
                            "surfaces": {"osa": ["duplicate"]},
                        },
                        {
                            "name": "computer.click",
                            "fingerprint": "sha256:" + "b" * 64,
                            "surfaces": {"osa": ["duplicate"]},
                        },
                    ]
                }
            )

    def test_sync_writes_a_valid_identity_contract(self):
        contract = {
            "version": 1,
            "capabilities": [
                {
                    "name": "sandbox.exec",
                    "version": "1.0.0",
                    "fingerprint": "sha256:" + "a" * 64,
                    "surfaces": {"osa": ["shell_execute:miosa"]},
                }
            ],
        }

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.json"
            destination = Path(directory) / "output.json"
            source.write_text(json.dumps(contract))
            SYNC.sync(source, destination)

            self.assertEqual(contract, json.loads(destination.read_text()))
            self.assertEqual(0o644, destination.stat().st_mode & 0o777)


if __name__ == "__main__":
    unittest.main()
