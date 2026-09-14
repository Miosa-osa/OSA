"""Verify the eight recovered splits retain every byte of their shipped originals.
Run: python3 test/skill_reference_preservation_test.py
"""
import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ReferencePreservationTest(unittest.TestCase):
    def test_original_content_and_navigation(self):
        originals = json.loads((ROOT / "test/fixtures/skill_split_originals.json").read_text())
        for name, expected in originals.items():
            with self.subTest(skill=name):
                folder = ROOT / "priv/skills" / name
                main = (folder / "SKILL.md").read_bytes()
                self.assertLess(len(main.splitlines()), 500)
                prefix, navigation = main.split(b"<!-- progressive-disclosure -->", 1)
                refs = re.findall(rb"\]\((references/[^)]+)\)", navigation)
                self.assertTrue(refs)
                self.assertEqual(len(refs), len(set(refs)))
                restored = prefix
                for ref in refs:
                    content = (folder / ref.decode()).read_bytes()
                    self.assertLessEqual(len(content.splitlines()), 300)
                    restored += content
                self.assertEqual(hashlib.sha256(restored).hexdigest(), expected,
                                 "split dropped or altered original material")

if __name__ == "__main__":
    unittest.main()
