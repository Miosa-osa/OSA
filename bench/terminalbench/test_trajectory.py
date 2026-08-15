#!/usr/bin/env python3
"""D8 — the ATIF export, and the reason it is not switched on.

Two things are asserted here and they are not the same thing:

1. **The export is correct.** `Trajectory(**doc)` over the archived runs. Cheap
   and worth having, because every ATIF model is `extra="forbid"` and a typo in
   a key name is otherwise silent until a submission is rejected.

2. **The argument-fidelity gate is real.** A trajectory whose `arguments` are
   `{}` passes (1) and is worse than nothing: `harbor/utils/traces_utils.py`
   serialises `arguments` verbatim into SFT training conversations. The gate is
   what stops (1) being mistaken for readiness, so it is tested as hard as the
   schema is.

`arg_hash` is a port of Elixir's `ToolArgMetrics.arg_hash/1`. The port is pinned
against REAL stream data rather than against a fixture, because a fixture would
be written from the same misunderstanding as the port.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import _localimport  # noqa: E402

traj = _localimport.load("trajectory")

RUN = HERE / "runs" / "osa-tb20-full89-f6981b61" / "harbor" / "2026-08-15__02-04-49"


def _trials():
    if not RUN.is_dir():
        return []
    return [d for d in sorted(RUN.glob("*__*"))
            if (d / "agent" / "osa-events.jsonl").exists()]


class TestArgHashPort(unittest.TestCase):
    """The Python port must agree with what the agent wrote, byte for byte."""

    def test_canonicalisation_sorts_and_stringifies_keys(self):
        # `%{"a" => 1}` and `%{a: 1}` arrive through two decode paths and must
        # agree -- the exact property `ToolArgMetrics.canonicalize/1` exists for.
        self.assertEqual(traj.arg_hash({"b": 1, "a": 2}), traj.arg_hash({"a": 2, "b": 1}))
        self.assertEqual(len(traj.arg_hash({"a": 1})), 32)

    def test_the_port_reproduces_hashes_the_agent_actually_wrote(self):
        trials = _trials()
        if not trials:
            self.skipTest("archived run not on disk")
        checked = 0
        for d in trials[:12]:
            events = traj.read_events(d)
            rec = traj.recover_arguments(events)
            for e in events:
                if e.get("type") != "tool_call" or e.get("phase") != "start":
                    continue
                args, verified = rec.get(e.get("tool_call_id") or "", ({}, False))
                if verified:
                    self.assertEqual(traj.arg_hash(args), e["args_hash"])
                    checked += 1
        self.assertGreater(checked, 100, "the port was barely exercised")


class TestExportValidates(unittest.TestCase):
    def test_every_archived_trial_produces_a_valid_atif_document(self):
        trials = _trials()
        if not trials:
            self.skipTest("archived run not on disk")
        try:
            from harbor.models.trajectories import Trajectory
        except ImportError:
            self.skipTest("harbor not importable under this interpreter")
        for d in trials:
            doc, _ = traj.build(d, instruction="x", agent_version="test")
            with self.subTest(trial=d.name):
                Trajectory(**doc)

    def test_step_one_is_the_user_instruction_and_carries_no_agent_fields(self):
        """`Step.validate_agent_only_fields` rejects a user step with metrics."""
        trials = _trials()
        if not trials:
            self.skipTest("archived run not on disk")
        doc, _ = traj.build(trials[0], instruction="do the thing")
        self.assertEqual(doc["steps"][0]["source"], "user")
        self.assertEqual(doc["steps"][0]["message"], "do the thing")
        for f in ("metrics", "tool_calls", "reasoning_content", "model_name"):
            self.assertNotIn(f, doc["steps"][0])


class TestFidelityGate(unittest.TestCase):
    """The part that stops a valid-but-worthless trajectory being submitted."""

    def test_unverified_arguments_are_empty_and_flagged_never_guessed(self):
        trials = _trials()
        if not trials:
            self.skipTest("archived run not on disk")
        seen_unverified = False
        for d in trials[:20]:
            doc, _ = traj.build(d)
            for step in doc["steps"]:
                for tc in step.get("tool_calls") or []:
                    if not tc["extra"]["osa_arguments_verified"]:
                        seen_unverified = True
                        # A plausible-looking wrong argument in a training
                        # export is worse than an absent one.
                        self.assertEqual(tc["arguments"], {})
                    self.assertIsNotNone(tc["extra"]["osa_args_hash"])
        self.assertTrue(seen_unverified, "no unverified call in 20 trials?")

    def test_every_document_states_its_own_fidelity(self):
        trials = _trials()
        if not trials:
            self.skipTest("archived run not on disk")
        doc, fid = traj.build(trials[0])
        self.assertIn("osa_arg_fidelity", doc["extra"])
        self.assertEqual(doc["extra"]["osa_arg_fidelity"], fid)
        self.assertLessEqual(fid["arguments_verified"], fid["tool_calls"])

    def test_file_write_arguments_are_not_recoverable_at_all(self):
        """The precise shape of what `lib/` must fix.

        `file_write`'s content appears in NO event: the hint is the bare path
        and there is no `command_output_delta` analogue for it. 214 of 3,796
        calls in the archived run, plus 542 `task_write`, is 19.9% of all tool
        calls that no host-side reconstruction can ever reach.
        """
        trials = _trials()
        if not trials:
            self.skipTest("archived run not on disk")
        calls = verified = 0
        for d in trials:
            events = traj.read_events(d)
            rec = traj.recover_arguments(events)
            for e in events:
                if (e.get("type") == "tool_call" and e.get("phase") == "start"
                        and e.get("name") in ("file_write", "task_write")):
                    calls += 1
                    verified += int(rec.get(e.get("tool_call_id") or "",
                                            ({}, False))[1])
        self.assertGreater(calls, 0)
        self.assertEqual(verified, 0)

    def test_supports_atif_is_still_off(self):
        """It must not be flipped while the fidelity floor is unmet.

        Asserted against the adapter's source rather than by importing it, so
        this runs without harbor. If someone flips the flag, the export becomes
        submittable at ~57% argument fidelity and every consumer downstream of
        `traces_utils` gets `{}` as training data.
        """
        src = (HERE / "osa_agent.py").read_text()
        self.assertIn("SUPPORTS_ATIF = False", src)


if __name__ == "__main__":
    unittest.main()
