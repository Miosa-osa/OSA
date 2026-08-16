#!/usr/bin/env python3
"""Regression tests for `scripts/failure_species.py`'s episode reduction.

The acceptance rule this whole file defends is stated once in
`failure_species.py`:

    A detector must fire on at least one failure and on ZERO solved trials.

`abandoned_background` violated it for the first time on `rstan-to-pystan` in
`runs/osa-tb20-full89-9b57ee7d` -- a SOLVED trial. The cause was not the rule
but the replay's reconstructed ledger: `background_command_completed` is not
guaranteed to reach the wire (`Shell.BackgroundTask` arbitrates the
poll-vs-broadcast race with a check-and-set, and when a `bash_output` poll wins
the broadcast is suppressed), so a finished job can sit in the ledger forever.

These tests pin the reconciliation against `running_count` and, more
importantly, pin the two things that must NOT change: a genuinely abandoned job
still fires, and an episode with no `running_count` at all degrades to the old
behaviour rather than silently going blind.

Run standalone:  python3 scripts/test_failure_species.py
Or under pytest: pytest scripts/test_failure_species.py
"""

from __future__ import annotations

import unittest

from failure_species import detect, episode


def started(bid: str, cmd: str, running_count=None) -> dict:
    e = {"type": "background_command_started", "background_id": bid, "command": cmd}
    if running_count is not None:
        e["running_count"] = running_count
    return e


def completed(bid: str, running_count=None) -> dict:
    e = {"type": "background_command_completed", "background_id": bid}
    if running_count is not None:
        e["running_count"] = running_count
    return e


DONE = {"type": "done"}


class ReconcileAgainstRunningCount(unittest.TestCase):
    def test_lost_completion_event_does_not_strand_the_job(self):
        """The `rstan-to-pystan` shape, reduced to its essentials.

        `pip` starts and its completion event never arrives. The NEXT job then
        starts reporting `running_count: 1` -- the runtime saying one job is
        live, which cannot be true if `pip` were also running.
        """
        ev = [
            started("bg_pip", "pip install pystan", running_count=1),
            started("bg_run", "python analysis.py", running_count=1),
            completed("bg_run", running_count=0),
            DONE,
        ]
        self.assertEqual(episode(ev)["running"], {})
        self.assertEqual(detect(episode(ev)), [])

    def test_a_genuinely_abandoned_job_still_fires(self):
        """The 12 true positives of the reference run must survive the fix."""
        ev = [started("bg_srv", "python /app/server.py", running_count=1), DONE]
        ep = episode(ev)
        self.assertEqual(list(ep["running"]), ["bg_srv"])
        self.assertEqual([s for s, _ in detect(ep)], ["abandoned_background"])

    def test_two_live_jobs_are_both_kept_when_the_count_agrees(self):
        ev = [
            started("bg_a", "make -j8", running_count=1),
            started("bg_b", "python train.py", running_count=2),
            DONE,
        ]
        self.assertEqual(sorted(episode(ev)["running"]), ["bg_a", "bg_b"])

    def test_the_oldest_entry_is_the_one_evicted(self):
        """A job that has outlived a later job's start is the stale one."""
        ev = [
            started("bg_old", "pip install x", running_count=1),
            started("bg_mid", "pip install y", running_count=2),
            started("bg_new", "python go.py", running_count=2),
            DONE,
        ]
        self.assertEqual(sorted(episode(ev)["running"]), ["bg_mid", "bg_new"])

    def test_absent_running_count_degrades_to_the_previous_behaviour(self):
        """Older logs predate the field; they must not become undetectable."""
        ev = [started("bg_srv", "python /app/server.py"), DONE]
        self.assertEqual(list(episode(ev)["running"]), ["bg_srv"])

    def test_a_malformed_running_count_is_ignored_rather_than_trusted(self):
        for bad in ("2", None, -1, 1.5):
            with self.subTest(bad=bad):
                ev = [started("bg_srv", "python /app/server.py", running_count=bad), DONE]
                self.assertEqual(list(episode(ev)["running"]), ["bg_srv"])

    def test_no_fire_without_done_even_with_a_live_job(self):
        """The species is *claiming completion* with work in flight."""
        ev = [started("bg_srv", "python /app/server.py", running_count=1)]
        self.assertEqual(detect(episode(ev)), [])


if __name__ == "__main__":
    unittest.main()
