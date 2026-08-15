"""Regression tests for the deviations closed in the 2026-08-15 Harbor pass.

All three cover defects that made a published number mean something other than
what it said, which is the only class of bug this benchmark's own tests exist
for. Each names the deviation it closes so the docs and the tests cannot drift
apart silently.

* **D7 — token accounting.** `AgentContext.n_input_tokens` is documented as the
  whole prompt "including cache" (`harbor/models/agent/context.py:9-11`) and
  every reference adapter feeds it `total_prompt_tokens`, itself "including
  cached tokens" (`models/trajectories/final_metrics.py:11-14`). We were writing
  the uncached remainder into it, so every token and cost figure we published
  was incomparable with the field's.

* **Non-conforming task copies.** Four TB 2.0 tasks in our local `tasks/` carry
  larger budgets or memory than the canonical Hub package. Both leaderboard
  contracts forbid resource and timeout overrides, and this one never appears in
  `config.json` because it is baked into the task file. `crack-7z-hash` passed
  the full-89 run on such a copy.

* **Quota death vs model failure.** A 429 that means "this account is out of
  budget" and one that means "slow down" arrive identically and OSA's
  `ErrorCatalog` collapses both to `:rate_limit`. Harbor keeps them apart, and
  only one of them is in `exclude_exceptions`.

Run: `python3 -m pytest bench/terminalbench/test_conformance.py`
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "driver"))

# `report`/`datasets` are ambiguous basenames across bench/ -- see
# `_localimport` for the measured failure. Never `import report` here.
import _localimport  # noqa: E402
import osa_headless  # noqa: E402

datasets_mod = _localimport.load("datasets")
report = _localimport.load("report")


def _load_osa_agent():
    """`osa_agent` imports harbor, which lives only in the bench venv."""
    spec = importlib.util.spec_from_file_location("osa_agent", HERE / "osa_agent.py")
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    try:
        spec.loader.exec_module(mod)
    except Exception as exc:  # noqa: BLE001
        raise unittest.SkipTest(f"osa_agent unimportable here ({exc})") from exc
    return mod


class _Ctx:
    """Stand-in for `AgentContext`; the adapter only ever assigns attributes."""

    n_input_tokens = None
    n_output_tokens = None
    n_cache_tokens = None
    cost_usd = None
    metadata = None


class _Agent:
    """`populate_context_post_run` bound without Harbor's `__init__`."""

    def __init__(self, cls, logs_dir: Path):
        self._cls = cls
        self.logs_dir = logs_dir

    def populate(self, ctx):
        return self._cls.populate_context_post_run(self, ctx)


# ---------------------------------------------------------------- D7: tokens


class TestInputTokensIncludeCache(unittest.TestCase):
    def _run(self, usage: dict) -> _Ctx:
        import json
        import tempfile

        mod = _load_osa_agent()
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "osa-telemetry.json").write_text(
                json.dumps({"status": "ok", "usage_sum": usage})
            )
            ctx = _Ctx()
            _Agent(mod.OsaAgent, d).populate(ctx)
            return ctx

    def test_cache_read_and_creation_are_folded_into_n_input_tokens(self):
        """The fold `claude_code.py:755-759` does, done here.

        Magnitudes taken from `runs/anthropic-cache-probe-20260814`, which is
        the only run we hold where the provider reported cache at all: 101,547
        uncached input against 2,320,315 cache reads. Reporting 101,547 as the
        input-token figure understates the prompt by 23x.
        """
        ctx = self._run(
            {
                "input_tokens": 101_547,
                "output_tokens": 24_361,
                "cache_read_input_tokens": 2_320_315,
                "cache_creation_input_tokens": 77_815,
            }
        )
        self.assertEqual(ctx.n_input_tokens, 101_547 + 2_320_315 + 77_815)
        # `n_cache_tokens` is the cache SLICE, a subset of the above and not a
        # sibling of it (`claude_code.py:1526-1527`).
        self.assertEqual(ctx.n_cache_tokens, 2_320_315 + 77_815)
        self.assertEqual(ctx.metadata["osa_uncached_input_tokens"], 101_547)

    def test_a_provider_that_reports_no_cache_is_unchanged(self):
        """The measured shape of every trial in the run we have published.

        `runs/osa-tb20-full89-f6981b61` recorded cache_read = cache_creation = 0
        on all 87 trials that wrote telemetry, so D7 moves none of its figures.
        This is the test that keeps that true rather than asserted.
        """
        ctx = self._run(
            {
                "input_tokens": 449_149,
                "output_tokens": 12_510,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
            }
        )
        self.assertEqual(ctx.n_input_tokens, 449_149)
        self.assertIsNone(ctx.n_cache_tokens)


class TestReporterDoesNotDoubleCountCache(unittest.TestCase):
    """`report.py::_reconcile_spend` must not add cache to a cache-inclusive
    total. `tokens_in` there is the UNCACHED remainder, and `build` adds the two
    cache counters back on to form `input_tokens_per_task`."""

    def _reconcile(self, agent_result, meta):
        return report._reconcile_spend(Path("/nonexistent"), agent_result, meta)

    def test_post_d7_artefact_uses_the_uncached_key(self):
        got = self._reconcile(
            {"n_input_tokens": 500, "n_output_tokens": 10},
            {
                "osa_uncached_input_tokens": 100,
                "osa_usage_sum": {
                    "input_tokens": 100,
                    "cache_read_input_tokens": 300,
                    "cache_creation_input_tokens": 100,
                },
            },
        )
        self.assertEqual(got["tokens_in"], 100)
        self.assertEqual(got["tokens_cache_read"], 300)
        self.assertEqual(got["tokens_cache_write"], 100)
        # uncached + read + write == the adapter's n_input_tokens, exactly once.
        self.assertEqual(
            got["tokens_in"] + got["tokens_cache_read"] + got["tokens_cache_write"],
            500,
        )

    def test_pre_d7_artefact_still_re_derives_correctly(self):
        """An archived run must not be retroactively mis-scored by the fix.

        Before D7, `n_input_tokens` WAS the uncached remainder and there is no
        `osa_uncached_input_tokens` key. Its absence is the discriminator.
        """
        got = self._reconcile(
            {"n_input_tokens": 100, "n_output_tokens": 10},
            {"osa_usage_sum": {"input_tokens": 100}},
        )
        self.assertEqual(got["tokens_in"], 100)


# ------------------------------------------------- non-conforming task copies


class TestNonConformingTaskCopies(unittest.TestCase):
    def test_the_recorded_table_matches_what_is_on_disk(self):
        """The check that stops the table becoming prose that drifts.

        A failure here means either a task was fixed and the entry is stale, or
        a NEW divergence appeared and was not recorded. The second is the one
        that quietly buys us a point.
        """
        ds = datasets_mod.get("tb2.0")
        if not ds.present:
            self.skipTest("tb2.0 task copy not on disk")
        self.assertEqual(datasets_mod.check_conformance(ds), [])

    def test_crack_7z_hash_is_void(self):
        ds = datasets_mod.get("tb2.0")
        reason = datasets_mod.void_reason(ds, "crack-7z-hash")
        self.assertIsNotNone(reason)
        self.assertIn("1800s", reason)
        self.assertIn("900s", reason)

    def test_a_conforming_task_is_not_void(self):
        ds = datasets_mod.get("tb2.0")
        self.assertIsNone(datasets_mod.void_reason(ds, "build-pmars"))

    def test_build_marks_the_row_and_publishes_a_second_rate(self):
        rows = [
            {
                "task_name": "terminal-bench/crack-7z-hash",
                "resolved": True,
                "reward": 1.0,
                "failure_reason": "",
                "fault_owner": "resolved",
                "self_inflicted": {},
                "tokens_in": None, "tokens_out": None, "tokens_cache": None,
                "tokens_cache_read": None, "tokens_cache_write": None,
                "cost_usd": None, "wall_clock_s": None, "agent_setup_s": None,
                "agent_exec_s": None, "osa_boot_s": None, "turns": None,
                "tool_calls": None, "write_ops": None, "peak_context_tokens": None,
                "denials": None, "osa_tool_faults": None, "add_dir_mentions": None,
                "trial_name": "crack-7z-hash__x",
            },
            {
                "task_name": "terminal-bench/build-pmars",
                "resolved": False,
                "reward": 0.0,
                "failure_reason": "completed_but_wrong",
                "fault_owner": "model",
                "self_inflicted": {},
                "tokens_in": None, "tokens_out": None, "tokens_cache": None,
                "tokens_cache_read": None, "tokens_cache_write": None,
                "cost_usd": None, "wall_clock_s": None, "agent_setup_s": None,
                "agent_exec_s": None, "osa_boot_s": None, "turns": None,
                "tool_calls": None, "write_ops": None, "peak_context_tokens": None,
                "denials": None, "osa_tool_faults": None, "add_dir_mentions": None,
                "trial_name": "build-pmars__x",
            },
        ]
        out = report.build(config={"dataset_key": "tb2.0"}, rows=rows)
        a = out["aggregate"]
        self.assertEqual(a["n_void"], 1)
        self.assertEqual(a["void_tasks"][0]["task_name"], "terminal-bench/crack-7z-hash")
        # The raw rate is NOT silently corrected -- a shrinking denominator that
        # nobody can audit is the failure mode, in either direction.
        self.assertEqual(a["accuracy"], 0.5)
        self.assertEqual(a["accuracy_excluding_void"], 0.0)

    def test_the_summary_says_so_under_the_headline(self):
        out = report.build(
            config={"dataset_key": "tb2.0", "run_id": "t"},
            rows=[
                {
                    "task_name": "terminal-bench/crack-7z-hash",
                    "resolved": True, "reward": 1.0, "failure_reason": "",
                    "fault_owner": "resolved", "self_inflicted": {},
                    "tokens_in": None, "tokens_out": None, "tokens_cache": None,
                    "tokens_cache_read": None, "tokens_cache_write": None,
                    "cost_usd": None, "wall_clock_s": None, "agent_setup_s": None,
                    "agent_exec_s": None, "osa_boot_s": None, "turns": None,
                    "tool_calls": None, "write_ops": None,
                    "peak_context_tokens": None, "denials": None,
                    "osa_tool_faults": None, "add_dir_mentions": None,
                    "trial_name": "crack-7z-hash__x",
                }
            ],
        )
        md = report.summary_md(out)
        head = md[md.index("## Headline") :]
        self.assertIn("NOT measurements", head)
        self.assertIn("crack-7z-hash", head)


# ------------------------------------------------------------- quota vs model


class TestQuotaIsNotAModelFailure(unittest.TestCase):
    #: Verbatim from `runs/rerun-timeouts-f6981b61`.
    QUOTA_REASON = (
        'All providers failed: ollama: "Ollama returned 429: %{\\"error\\" => '
        '\\"you (focused_varahamihira_355) have reached your session usage '
        'limit, add extra usage: https://ollama.com/settings\\"}"'
    )

    def test_report_separates_quota_from_a_generic_provider_error(self):
        quota = report._failure_reason(
            0.0,
            None,
            {
                "osa_status": "provider_error",
                "osa_turn_error_owner": "provider",
                "osa_turn_error": {
                    "owner": "provider",
                    "category": "rate_limit",
                    "reason": self.QUOTA_REASON,
                },
            },
        )
        self.assertEqual(quota, "provider_quota_exhausted")

        transient = report._failure_reason(
            0.0,
            None,
            {
                "osa_status": "provider_error",
                "osa_turn_error_owner": "provider",
                "osa_turn_error": {
                    "owner": "provider",
                    "category": "rate_limit",
                    "reason": "Ollama returned 429: too many requests",
                },
            },
        )
        self.assertEqual(transient, "provider_error")

    def test_neither_is_charged_to_the_model(self):
        self.assertEqual(report._fault_owner("provider_quota_exhausted"), "ambiguous")
        self.assertEqual(report._fault_owner("provider_error"), "ambiguous")

    def test_task_output_mentioning_a_quota_cannot_trigger_it(self):
        """The category gate runs first, so free text never reaches the match."""
        self.assertFalse(
            report._is_quota_exhaustion(
                {"category": "unknown", "reason": "the test prints 'usage limit'"}
            )
        )

    def test_the_driver_emits_the_phrase_harbor_maps_to_a_usage_limit(self):
        line = osa_headless._classifier_line(
            {"turn_error": {"category": "rate_limit", "reason": self.QUOTA_REASON}}
        )
        self.assertIn("Quota exceeded.", line)
        # `_classify_exec_error` keeps the match with the greatest END OFFSET
        # (`agents/installed/base.py:792-798`), so anything after the phrase can
        # out-rank it. The category annotation used to sit there, and for
        # `rate_limit` the annotation itself matches `rate.?limit` -- which
        # silently demoted every quota death back to `ApiRateLimitError` and
        # left Harbor retrying an empty wallet.
        self.assertTrue(line.rstrip().endswith("Quota exceeded."))

    def test_the_driver_exits_non_zero_so_harbor_sees_it_at_all(self):
        """D2's other half. Exit 0 meant `_classify_exec_error` never ran and a
        quota death was recorded as a legitimate reward-0."""
        self.assertNotEqual(osa_headless._EXIT_CODES["provider_error"], 0)



class TestJudgeTaskFiltering(unittest.TestCase):
    """The runner must dispatch the same set the controls measured.

    16 of Harbor-Index's 80 tasks are graded by an LLM-judge ensemble that runs
    at VERIFY time. `controls.py` has filtered them out since it was written;
    `run_bench.py` did not, so a full run would have dispatched 80 and reported
    a rate over a denominator only 64 of which had ever been control-measured --
    and `controls.py gate` could not have caught it, because it only inspects
    the tasks a run actually recorded.
    """

    def setUp(self):
        self.ds = datasets_mod.get("harbor-index")
        if not self.ds.present:
            self.skipTest("harbor-index not on disk")
        self.rb = _localimport.load("run_bench")

    def test_sixteen_of_eighty_need_a_credential(self):
        """Pinned, because the number IS the correction to the denominator."""
        self.assertEqual(len(self.ds.task_names()), 80)
        self.assertEqual(len(datasets_mod.judge_required_tasks(self.ds)), 16)

    def test_the_runner_and_the_controls_agree_on_what_is_gradeable(self):
        """The defect was these two disagreeing, so this is the real assertion."""
        runner_kept, _ = self.rb.filter_judge_tasks(
            self.ds, self.ds.task_names(), set(), have_key=False
        )
        controls_kept = datasets_mod.gradeable_tasks(self.ds, have_judge_key=False)
        self.assertEqual(sorted(runner_kept), sorted(controls_kept))
        self.assertEqual(len(runner_kept), 64)

    def test_a_judge_task_is_dropped_when_unnamed(self):
        kept, dropped = self.rb.filter_judge_tasks(
            self.ds, ["hle-vowel-marking-system", "usaco-assign-cows-to-barns"],
            set(), have_key=False,
        )
        self.assertEqual(kept, ["usaco-assign-cows-to-barns"])
        self.assertEqual(dropped, ["hle-vowel-marking-system"])

    def test_a_judge_task_named_by_hand_is_refused_not_dropped(self):
        """A silent drop of a task the operator asked for is the same class of
        defect as reporting on a denominator you did not measure."""
        with self.assertRaises(SystemExit) as cm:
            self.rb.filter_judge_tasks(
                self.ds, ["hle-vowel-marking-system"],
                {"hle-vowel-marking-system"}, have_key=False,
            )
        self.assertIn("ANTHROPIC_API_KEY", str(cm.exception))

    def test_nothing_is_dropped_when_the_credential_exists(self):
        names = self.ds.task_names()
        kept, dropped = self.rb.filter_judge_tasks(
            self.ds, list(names), set(), have_key=True
        )
        self.assertEqual(kept, list(names))
        self.assertEqual(dropped, [])

    def test_datasets_without_judged_tasks_are_untouched(self):
        ds = datasets_mod.get("tb2.0")
        if not ds.present:
            self.skipTest("tb2.0 not on disk")
        kept, dropped = self.rb.filter_judge_tasks(
            ds, ["build-pmars"], set(), have_key=False
        )
        self.assertEqual((kept, dropped), (["build-pmars"], []))

    def test_the_summary_states_the_effective_denominator(self):
        out = report.build(
            config={
                "dataset_key": "harbor-index", "run_id": "t", "dataset_size": 80,
                "effective_denominator": 64, "have_judge_key": False,
                "judge_skipped_tasks": ["hle-vowel-marking-system"],
            },
            rows=[{
                "task_name": "harbor-index/usaco-assign-cows-to-barns",
                "resolved": True, "reward": 1.0, "failure_reason": "",
                "fault_owner": "resolved", "self_inflicted": {},
                "tokens_in": None, "tokens_out": None, "tokens_cache": None,
                "tokens_cache_read": None, "tokens_cache_write": None,
                "cost_usd": None, "wall_clock_s": None, "agent_setup_s": None,
                "agent_exec_s": None, "osa_boot_s": None, "turns": None,
                "tool_calls": None, "write_ops": None,
                "peak_context_tokens": None, "denials": None,
                "osa_tool_faults": None, "add_dir_mentions": None,
                "trial_name": "usaco-assign-cows-to-barns__x",
            }],
        )
        self.assertEqual(out["aggregate"]["effective_denominator"], 64)
        md = report.summary_md(out)
        head = md.split("## Headline", 1)[1]
        self.assertIn("over 64 tasks, not 80", head)
        self.assertIn("**absences, not failures**", head)
        self.assertIn("hle-vowel-marking-system", head)
        # The caveat must precede the cost table, not trail it.
        self.assertLess(head.index("over 64 tasks"), head.index("## Who failed"))


if __name__ == "__main__":
    unittest.main()
