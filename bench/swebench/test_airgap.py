#!/usr/bin/env python3
"""Tests for the airgap classifier.

`airgap.probe()` needs a live backend, so what is tested here is the part that
decides what the backend's answer MEANT: `_classify`. That split is deliberate.
The previous airgap shipped because "it looks right" stood in for "a backend
was observed refusing", and the classifier is where that substitution would
happen again -- every one of these tests is a way the probe could have said
"enforced" without enforcement being real.

    ./.venv/bin/python test_airgap.py
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import airgap  # noqa: E402


def _blank() -> dict:
    return {
        "enforced": False,
        "tool_calls_seen": [],
        "denied_tool_evidence": None,
        "shell_egress_evidence": None,
        "control_tool_evidence": None,
        "page_content_observed": False,
        "final_message_tail": None,
        "error": None,
    }


def _call(name: str, cid: str, *, args="", success=True, ms=5) -> list[dict]:
    """The exact two-frame shape OSA emits for one tool call."""
    return [
        {"type": "tool_call", "phase": "start", "name": name,
         "args": args, "tool_call_id": cid},
        {"type": "tool_call", "phase": "end", "name": name,
         "success": success, "duration_ms": ms, "tool_call_id": cid},
    ]


def _frames(*, web_ok=False, egress_ok=False, benign_ok=True, control_ok=True,
            skip=()) -> list[dict]:
    f: list[dict] = []
    if "web" not in skip:
        f += _call("web_fetch", "c1", args="https://example.com",
                   success=web_ok, ms=200 if web_ok else 0)
    if "egress" not in skip:
        f += _call("shell_execute", "c2",
                   args='python3 -c "import urllib.request; urlopen(...)"',
                   success=egress_ok)
    if "benign" not in skip:
        f += _call("shell_execute", "c3",
                   args=f"echo {airgap.BENIGN_SHELL_MARKER}", success=benign_ok)
    if "control" not in skip:
        f += _call("dir_list", "c4", args=".", success=control_ok)
    f.append({"type": "done"})
    return f


def classify(**kw) -> dict:
    return airgap._classify(_blank(), _frames(**kw))


class TestClassifier(unittest.TestCase):
    def test_the_only_passing_shape(self):
        a = classify()
        self.assertTrue(a["enforced"])
        self.assertIsNone(a["error"])
        self.assertTrue(a["shell_surface_refused"])
        self.assertTrue(a["benign_shell_still_works"])

    def test_web_fetch_succeeding_fails(self):
        a = classify(web_ok=True)
        self.assertFalse(a["enforced"])
        self.assertIn("RAN", a["error"])

    def test_shell_egress_succeeding_fails(self):
        """The hole the previous run actually leaked through."""
        a = classify(egress_ok=True)
        self.assertFalse(a["enforced"])

    def test_over_matching_deny_rules_fail(self):
        """A rule that blocks every shell command would look like a perfect
        airgap and would silently destroy the benchmark."""
        a = classify(benign_ok=False)
        self.assertFalse(a["enforced"])
        self.assertIn("over-matching", a["error"])

    def test_a_dead_backend_is_not_enforcement(self):
        a = classify(control_ok=False)
        self.assertFalse(a["enforced"])
        self.assertIn("broken backend", a["error"])

    def test_untested_surfaces_are_not_credited(self):
        for skipped, needle in (
            (("web",), "never called a denied tool"),
            (("egress",), "residual shell surface is untested"),
            (("benign",), "blast radius"),
        ):
            with self.subTest(skipped=skipped):
                a = airgap._classify(_blank(), _frames(skip=skipped))
                self.assertFalse(a["enforced"])
                self.assertIn(needle, a["error"])

    def test_page_content_anywhere_overrides_a_clean_frame_set(self):
        """If the h1 of example.com appears, the fetch happened -- whatever the
        success flags claim."""
        f = _frames()
        f.append({"type": "message", "content": "the page said Example Domain"})
        a = airgap._classify(_blank(), f)
        self.assertTrue(a["page_content_observed"])
        self.assertFalse(a["enforced"])

    def test_the_two_shell_steps_are_told_apart_by_id_not_order(self):
        """`end` frames carry no args. Joining on tool_call_id is the only way
        to know which shell_execute was which, and reversing the order must not
        change the verdict."""
        f = _call("web_fetch", "c1", success=False, ms=0)
        f += _call("shell_execute", "c3",
                   args=f"echo {airgap.BENIGN_SHELL_MARKER}", success=True)
        f += _call("shell_execute", "c2", args="import urllib", success=False)
        f += _call("dir_list", "c4", success=True)
        a = airgap._classify(_blank(), f)
        self.assertTrue(a["enforced"], a["error"])


class TestDenyRules(unittest.TestCase):
    def test_covers_every_tool_the_reporter_watches(self):
        rules = set(airgap.deny_rules())
        for tool in airgap.NETWORK_TOOLS:
            self.assertIn(tool, rules)

    def test_covers_the_paths_the_previous_run_actually_used(self):
        """Both real leaks from runs/osa-hard40-v2: a curl to
        raw.githubusercontent.com, and a python3 -c urllib one-liner."""
        rules = airgap.deny_rules()
        self.assertIn("shell_execute(curl:*)", rules)
        self.assertIn("shell_execute(*urllib*)", rules)
        self.assertIn("shell_execute(*://raw.githubusercontent.com*)", rules)

    def test_shell_is_not_denied_wholesale(self):
        """The agent must keep a shell; an airgap that removes it measures
        something else entirely."""
        self.assertNotIn("shell_execute", airgap.deny_rules())

    def test_settings_document_sets_nothing_but_the_deny_list(self):
        doc = airgap.settings_document()
        self.assertEqual(set(doc) - {"_comment"}, {"permissions"})
        self.assertEqual(set(doc["permissions"]), {"deny"})


class TestResidualScan(unittest.TestCase):
    def _log(self, tmp: Path, events: list[dict]) -> Path:
        p = tmp / "e.jsonl"
        p.write_text("\n".join(json.dumps(e) for e in events))
        return p

    def test_finds_a_python_urllib_one_liner(self):
        import tempfile

        with tempfile.TemporaryDirectory() as t:
            p = self._log(Path(t), [
                {"type": "tool_call", "phase": "start", "name": "shell_execute",
                 "arguments": {"command": 'python3 -c "import urllib.request"'}},
            ])
            hits = airgap.residual_egress_evidence(p)
            self.assertEqual(len(hits), 1)

    def test_ignores_ordinary_commands(self):
        import tempfile

        with tempfile.TemporaryDirectory() as t:
            p = self._log(Path(t), [
                {"type": "tool_call", "phase": "start", "name": "shell_execute",
                 "arguments": {"command": "python3 -m pytest tests/"}},
                {"type": "tool_call", "phase": "start", "name": "file_read",
                 "arguments": {"path": "urllib_helper.py"}},
            ])
            self.assertEqual(airgap.residual_egress_evidence(p), [])

    def test_missing_log_is_empty_not_a_crash(self):
        self.assertEqual(airgap.residual_egress_evidence(Path("/nope/x.jsonl")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
