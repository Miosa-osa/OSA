"""Regression tests for the two reporting defects found on `tb-cost-probe-v1`.

Both were measurement bugs, not agent bugs, and both biased the published
numbers in OSA's own favour — which is the class of error this benchmark exists
to prevent, so they get tests.

1. **Under-counted tokens/cost.** The spend sidecar OSA writes could lag the
   summed SSE frames by one LLM round-trip (a turn's final round-trip makes no
   tool call, so no mid-turn checkpoint follows it). The reader preferred the
   sidecar whenever the key was present, so the published input-token and $
   figures came out LOW — measured at 30k-110k input tokens per task, ~1.1% of
   the probe total.

2. **Sticky `runner_error`.** The driver initialises `status` to `runner_error`
   so a driver that dies mid-run cannot look successful, but the clean-exit
   branch only overwrote (None, "", "running") — none of which the driver ever
   sets. Every clean exit kept the sentinel and `report.py` bucketed the task as
   `unclassified:runner_error` rather than `completed_but_wrong`, making the
   whole failure taxonomy useless.

Run: `python3 -m pytest bench/terminalbench/test_report_spend.py`
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "driver"))

import osa_headless  # noqa: E402
import report  # noqa: E402


class TestStatusSentinel(unittest.TestCase):
    def test_the_initial_status_is_in_the_unset_set(self):
        """The guard must actually cover the value the driver starts from.

        This is the whole bug: the sentinel and the set that may replace it had
        drifted apart, and nothing noticed because both were plausible.
        """
        self.assertIn("runner_error", osa_headless._STATUS_UNSET)

    def test_a_clean_exit_recorded_under_the_old_bug_re_derives_as_completed(self):
        meta = {"osa_status": "runner_error", "osa_saw_done": True, "osa_tool_calls": 12}
        self.assertEqual(report._failure_reason(0.0, None, meta), "completed_but_wrong")

    def test_a_driver_that_really_died_keeps_its_runner_error(self):
        """No `done` frame => the sentinel means what it says. Not re-derived."""
        meta = {"osa_status": "runner_error", "osa_saw_done": False}
        self.assertEqual(
            report._failure_reason(0.0, None, meta), "unclassified:runner_error"
        )

    def test_a_resolved_task_still_has_no_failure_reason(self):
        meta = {"osa_status": "runner_error", "osa_saw_done": True}
        self.assertEqual(report._failure_reason(1.0, None, meta), "")

    def test_a_harness_exception_still_wins_over_the_re_derivation(self):
        meta = {"osa_status": "runner_error", "osa_saw_done": True}
        reason = report._failure_reason(0.0, {"exception_type": "Boom"}, meta)
        self.assertEqual(reason, "harness_exception:Boom")


class TestSpendReconciliation(unittest.TestCase):
    def test_newer_takes_the_larger_of_two_cumulative_readings(self):
        self.assertEqual(osa_headless._newer(0.28, 0.30), 0.30)
        self.assertEqual(osa_headless._newer(0.30, 0.28), 0.30)
        self.assertEqual(osa_headless._newer(None, 0.28), 0.28)
        self.assertIsNone(osa_headless._newer(None, None))

    def test_newer_ignores_booleans(self):
        """`True` is an int in Python; a flag must never become a dollar figure."""
        self.assertIsNone(osa_headless._newer(True, None))

    def test_a_lagging_sidecar_no_longer_lowers_the_published_tokens(self):
        """The measured shape of the bug, from `path-tracing` on the probe run."""
        meta = {
            "osa_spend_sidecar": {"input_tokens": 4_891_306, "cost_usd": 2.98},
            "osa_usage_sum": {"input_tokens": 4_999_152},
        }
        fixed = report._reconcile_spend(
            Path("/nonexistent"), {"n_input_tokens": 4_891_306, "cost_usd": 2.98}, meta
        )
        self.assertEqual(fixed["tokens_in"], 4_999_152)

    def test_an_agreeing_sidecar_is_left_alone(self):
        """On every trial whose sidecar was current the two agreed to the token.

        `max` must be a no-op there, or the fix would be moving numbers around
        for its own sake.
        """
        meta = {
            "osa_spend_sidecar": {"input_tokens": 753_062, "tree_cost_usd": 0.46381},
            "osa_usage_sum": {"input_tokens": 753_062},
        }
        fixed = report._reconcile_spend(
            Path("/nonexistent"), {"n_input_tokens": 753_062, "cost_usd": 0.46381}, meta
        )
        self.assertEqual(fixed["tokens_in"], 753_062)
        self.assertAlmostEqual(fixed["cost_usd"], 0.46381)

    def test_the_last_cost_update_frame_can_restore_a_lagging_cost(self):
        """The event log is the record no writer can lag, so it is the backstop."""
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            trial = Path(tmp)
            (trial / "agent").mkdir()
            with (trial / "agent" / "osa-events.jsonl").open("w") as fh:
                for cost in (0.10, 0.28, 0.302519):
                    fh.write(
                        json.dumps(
                            {"type": "cost_update", "tree_cost_usd": cost}
                        )
                        + "\n"
                    )
            meta = {"osa_spend_sidecar": {"cost_usd": 0.283729}, "osa_usage_sum": {}}
            fixed = report._reconcile_spend(trial, {"cost_usd": 0.283729}, meta)
            self.assertAlmostEqual(fixed["cost_usd"], 0.302519)

    def test_a_trial_with_no_records_at_all_reports_nothing_rather_than_zero(self):
        fixed = report._reconcile_spend(Path("/nonexistent"), {}, {})
        self.assertIsNone(fixed["tokens_in"])
        self.assertIsNone(fixed["cost_usd"])


if __name__ == "__main__":
    unittest.main()
