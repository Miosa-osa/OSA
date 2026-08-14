"""The driver's fault-attribution contract, and the report's trial arithmetic.

These are the two places where an infrastructure failure can be silently
rebilled to the model, so they are the two places that get tests.

`osa_headless.py` is written for the inside of a task container and imports only
stdlib, so it loads here directly from its path -- there is no package to import
it through.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import report as report_mod  # noqa: E402


def _load_driver():
    spec = importlib.util.spec_from_file_location(
        "osa_headless", HERE / "driver" / "osa_headless.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


driver = _load_driver()


# --------------------------------------------------------------- exit codes


class TestExitCodes:
    """Which statuses are charged to the model and which are not."""

    def test_ok_is_success(self):
        assert driver._EXIT_CODES["ok"] == 0

    def test_budget_exhaustion_stays_gradeable(self):
        """`timeout` MUST stay 0.

        Harbor grades its own agent timeouts -- `AgentTimeoutError` is caught
        inside the phase and the verifier still runs. Measured on the full-89
        run: 2 of the 5 trials this driver ended with `status: timeout` scored
        reward 1.0, because the work was already on disk and only the terminal
        frame was missing. A non-zero exit here raises before the verifier and
        converts those into errored trials, losing real passes.
        """
        assert driver._EXIT_CODES["timeout"] == 0

    @pytest.mark.parametrize(
        "status",
        [
            "install_or_boot_failed",
            "orchestrate_rejected",
            "overdrive_rejected",
            "stream_closed_without_done",
            "provider_error",
            "osa_internal_error",
            "turn_error_unattributed",
        ],
    )
    def test_faults_are_non_zero(self, status):
        """Every fault must be visible to Harbor's classifier and retry logic.

        This is the regression guard for the defect that made the whole
        fault-attribution effort necessary: the driver returned 0 for all of
        these, so `_exec` never raised, `ERROR_PATTERNS` never fired, and a
        provider outage was recorded as a legitimate reward-0.
        """
        assert driver._EXIT_CODES[status] != 0

    def test_exit_codes_are_distinct(self):
        """Distinct codes so a post-mortem can tell the faults apart."""
        faults = {k: v for k, v in driver._EXIT_CODES.items() if v != 0}
        assert len(set(faults.values())) == len(faults)

    def test_every_owner_status_has_an_exit_code(self):
        """`_OWNER_STATUS` maps turn errors onto statuses; all must be covered.

        A status with no entry falls through to the unattributed default rather
        than to 0, but leaving one unmapped hides a real fault behind a generic
        code, so the table has to stay complete by construction.
        """
        for status in driver._OWNER_STATUS.values():
            assert status in driver._EXIT_CODES


# ------------------------------------------------------- classifier honesty


class TestClassifierLine:
    """The line Harbor's `ERROR_PATTERNS` reads, and when we refuse to emit it."""

    def test_no_turn_error_no_line(self):
        assert driver._classifier_line({}) is None

    def test_known_category_maps(self):
        line = driver._classifier_line({"turn_error": {"category": "rate_limit"}})
        assert line and "rate limit" in line

    def test_leading_colon_is_tolerated(self):
        """OSA stamps Elixir atoms; `:rate_limit` and `rate_limit` are one thing."""
        assert driver._classifier_line({"turn_error": {"category": ":rate_limit"}})

    def test_osa_owned_categories_emit_no_provider_phrase(self):
        """An OSA bug must never be dressed up as a provider fault.

        These four are `ErrorCatalog`'s harness-fault categories. They exit
        non-zero as `osa_internal_error`, but they must not print a phrase that
        makes Harbor classify them as an API error -- that would relabel our own
        defect as upstream's, which is the original misattribution running
        backwards.
        """
        for category in (
            "harness_error",
            "request_shape",
            "tool_use_mismatch",
            "duplicate_tool_use",
        ):
            assert driver._classifier_line({"turn_error": {"category": category}}) is None

    def test_free_text_is_never_matched(self):
        """Only the structured `category` field is read.

        A substring search over an error *message* is how a task whose own
        output mentions "rate limit" gets misclassified as one.
        """
        assert (
            driver._classifier_line({"turn_error": "failed: rate limit exceeded"})
            is None
        )
        assert (
            driver._classifier_line(
                {"turn_error": {"message": "rate limit", "category": None}}
            )
            is None
        )

    def test_unmapped_category_is_silent(self):
        assert driver._classifier_line({"turn_error": {"category": "unknown"}}) is None

    def test_overload_phrase_survives_harbors_catch_all(self):
        """Regression guard for a real Harbor quirk.

        `_classify_exec_error` takes the LAST matching pattern, and a generic
        `API Error` rule sits after the overload rule. So the phrase upstream
        adapters use -- "API Error: Overloaded" -- downgrades to
        `UnknownApiError`. Ours must not contain that substring.
        """
        phrase = driver._CATEGORY_PHRASE["server_overload"]
        assert not re.search(r"API Error", phrase, re.IGNORECASE)


# ----------------------------------------------------------- trial counting


#: Every key `report.build` reads off a row, defaulted to "absent".
#:
#: Spelled out rather than built with a `defaultdict` so that a new required
#: field in `collect()` breaks these tests loudly instead of being silently
#: read as None -- these tests are about arithmetic over rows, and a fixture
#: that quietly absorbs schema drift stops testing the thing it names.
_ROW_DEFAULTS: dict = {
    "wall_clock_s": None,
    "agent_setup_s": None,
    "agent_exec_s": None,
    "tokens_in": None,
    "tokens_out": None,
    "tokens_cache": None,
    "tokens_cache_read": None,
    "tokens_cache_write": None,
    "cost_usd": None,
    "cost_complete": None,
    "turns": None,
    "tool_calls": None,
    "osa_status": None,
    "osa_error": None,
    "osa_boot_s": None,
    "osa_saw_done": None,
    "osa_last_event_type": None,
    "self_inflicted": {},
    "self_inflicted_samples": {},
    "exception": None,
    "exception_message": None,
    "telemetry_path": None,
    "trial_dir": None,
}


def _row(task: str, reward: float | None, **extra) -> dict:
    return {
        **_ROW_DEFAULTS,
        "task_name": task,
        "trial_name": f"{task}__x",
        "reward": reward,
        "resolved": bool(reward is not None and reward >= 1.0),
        "failure_reason": None,
        "fault_owner": "model",
        **extra,
    }


class TestMultiTrial:
    """pass@1 vs pass@k, and the noise the k=1 runs never measured."""

    def test_single_trial_runs_report_nothing(self):
        """At k=1 there is no per-task distribution, so the block stays absent
        rather than reporting a degenerate pass@1 that duplicates `accuracy`."""
        rows = [_row("a", 1.0), _row("b", 0.0)]
        assert report_mod.multi_trial(rows, 1) is None

    def test_pass_at_1_is_the_mean_per_task_fraction(self):
        rows = [_row("a", 1.0)] * 4 + [_row("a", 0.0)] * 1
        rows += [_row("b", 0.0)] * 5
        m = report_mod.multi_trial(rows, 5)
        assert m["pass_at_1"] == pytest.approx((0.8 + 0.0) / 2)

    def test_pass_at_k_counts_solved_at_least_once(self):
        rows = [_row("a", 1.0)] + [_row("a", 0.0)] * 4
        rows += [_row("b", 0.0)] * 5
        m = report_mod.multi_trial(rows, 5)
        assert m["pass_at_k"] == pytest.approx(0.5)

    def test_pass_at_k_is_never_below_pass_at_1(self):
        rows = [_row("a", 1.0), _row("a", 0.0), _row("b", 0.0), _row("b", 0.0)]
        m = report_mod.multi_trial(rows, 2)
        assert m["pass_at_k"] >= m["pass_at_1"]

    def test_errored_trials_leave_the_task_denominator(self):
        """An ungraded trial is not a failed attempt.

        Folding it in as a 0 is the same substitution the exit-code table
        exists to stop, one level up.
        """
        rows = [_row("a", 1.0), _row("a", None), _row("a", None)]
        m = report_mod.multi_trial(rows, 3)
        task = m["per_task"][0]
        assert task["n_graded"] == 1
        assert task["n_errored"] == 2
        assert task["pass_fraction"] == 1.0

    def test_task_with_no_graded_trial_has_no_fraction(self):
        rows = [_row("a", None), _row("a", None)]
        m = report_mod.multi_trial(rows, 2)
        assert m["per_task"][0]["pass_fraction"] is None
        assert m["pass_at_1"] is None

    def test_flaky_tasks_are_named(self):
        """The tasks that disagreed with themselves ARE the noise floor."""
        rows = [_row("steady", 1.0)] * 3 + [_row("coinflip", 1.0), _row("coinflip", 0.0), _row("coinflip", 1.0)]
        m = report_mod.multi_trial(rows, 3)
        assert m["flaky_tasks"] == ["coinflip"]
        assert m["n_flaky"] == 1


class TestAggregateShape:
    """The fields a reader needs to not misquote a multi-trial run."""

    def _build(self, rows, k):
        return report_mod.build(
            config={"n_attempts": k, "dataset_size": 2}, rows=rows
        )["aggregate"]

    def test_k1_tasks_attempted_equals_trials(self):
        a = self._build([_row("a", 1.0), _row("b", 0.0)], 1)
        assert a["tasks_attempted"] == a["trials_attempted"] == 2
        assert a["is_full_dataset_run"] is True

    def test_k5_does_not_inflate_the_denominator(self):
        """445 trial rows over 89 tasks is still an 89-task run.

        Counting trial rows against `dataset_size` would make every 5-trial full
        run declare itself a subset and disclaim its own headline.
        """
        rows = [_row("a", 1.0) for _ in range(5)] + [_row("b", 0.0) for _ in range(5)]
        a = self._build(rows, 5)
        assert a["tasks_attempted"] == 2
        assert a["trials_attempted"] == 10
        assert a["is_full_dataset_run"] is True

    def test_leaderboard_minimum_is_stated(self):
        assert self._build([_row("a", 1.0)], 1)["meets_leaderboard_trial_minimum"] is False
        rows = [_row("a", 1.0) for _ in range(5)]
        assert self._build(rows, 5)["meets_leaderboard_trial_minimum"] is True

    def test_k1_summary_says_it_is_inadmissible(self):
        """A k=1 run must disclaim itself in the rendered summary, not only in
        the JSON -- the markdown is what gets pasted into a message."""
        res = report_mod.build(
            config={"run_id": "t", "n_attempts": 1, "dataset_size": 2},
            rows=[_row("a", 1.0), _row("b", 0.0)],
        )
        md = report_mod.summary_md(res)
        assert "five trials" in md
        assert "not admissible" in md

    def test_k5_summary_leads_with_pass_at_1(self):
        """pass@k is the flattering number; it must never stand alone."""
        rows = [_row("a", 1.0) for _ in range(5)] + [_row("b", 0.0) for _ in range(5)]
        res = report_mod.build(
            config={"run_id": "t", "n_attempts": 5, "dataset_size": 2}, rows=rows
        )
        md = report_mod.summary_md(res)
        assert "pass@1" in md
        assert "pass@5" in md
        assert "per-**trial** rate" in md
