#!/usr/bin/env python3
"""Tests for bench/report. Standard library unittest; no pytest required.

    python bench/report/test_report.py

The interesting tests are the honesty ones. Statistics can be checked against
published worked examples; a refusal policy can only be checked by trying to
get a misleading number out of it and failing.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import failures as fail_mod
import honesty
import render as render_mod
from loader import Run, SchemaError
from stats import (
    clopper_pearson,
    interval,
    min_n_for_halfwidth,
    rule_of_three,
    two_proportion,
    wald,
    wilson,
)


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------


def make_results(
    *,
    run_id="t",
    runner="osa",
    n=10,
    k=5,
    dataset_size=500,
    model="m",
    outcomes=None,
    reasons=None,
    cost=0.0,
    started="2026-08-13T10:00:00+00:00",
    finished="2026-08-13T11:00:00+00:00",
    wall_total=None,
    instance_prefix="acme__proj",
) -> dict:
    instances = []
    for i in range(n):
        resolved = i < k
        iid = f"{instance_prefix}-{1000+i}"
        instances.append(
            {
                "instance_id": iid,
                "resolved": resolved,
                "outcome": (outcomes or {}).get(iid, "resolved" if resolved else "unresolved"),
                "failure_reason": (
                    "" if resolved else (reasons or {}).get(iid, "fix_incomplete_fail_to_pass_still_failing")
                ),
                "wall_clock_s": 10.0,
                "tokens_in": 1000,
                "tokens_out": 100,
                "tokens_cache_read": 0,
                "tokens_cache_write": 0,
                "cost_usd": cost,
                "tool_calls": 5,
                "turns": 6,
                "patch_bytes": 100 if resolved else 0,
                "agent_status": "ok",
                "agent_error": None,
                "model": model,
                "session_id": f"sess-{iid}",
                "fail_to_pass_failing": [],
                "pass_to_pass_failing": [],
            }
        )
    return {
        "schema_version": 1,
        "config": {
            "run_id": run_id,
            "runner": runner,
            "transport": "http",
            "model": model,
            "dataset_name": "princeton-nlp/SWE-bench_Verified",
            "split": "test",
            "dataset_size": dataset_size,
            "instance_ids": [i["instance_id"] for i in instances],
            "agent_timeout_s": 1800,
            "max_turns": 60,
            "test_bridge": True,
            "namespace": "swebench",
            "swebench_version": "4.1.0",
            "started_at": started,
            "finished_at": finished,
            "host": {},
        },
        "aggregate": {
            "instances_attempted": n,
            "instances_resolved": k,
            "resolve_rate": (k / n) if n else None,
            "is_full_dataset_run": n == dataset_size,
            "wall_clock_total_s": wall_total if wall_total is not None else 10.0 * n,
            "tokens_in_total": 1000 * n,
            "tokens_out_total": 100 * n,
            "cost_usd_total": cost * n,
        },
        "harness_report": {},
        "instances": instances,
    }


def write_run(tmp: Path, doc: dict) -> Run:
    d = tmp / doc["config"]["run_id"]
    d.mkdir(parents=True, exist_ok=True)
    (d / "results.json").write_text(json.dumps(doc))
    return Run.load(d / "results.json")


# ---------------------------------------------------------------------------


class TestStats(unittest.TestCase):
    def test_wilson_matches_hand_computed_value(self):
        """15/50 at 95%, worked by hand from the closed form.

        p=0.3, z=1.959964, denom=1+z^2/50=1.076817,
        centre=(0.3+z^2/100)/denom=0.314284,
        margin=(z/denom)*sqrt(0.3*0.7/50+z^2/10000)=0.123240.
        """
        ci = wilson(15, 50)
        self.assertAlmostEqual(ci.low, 0.191035535, places=8)
        self.assertAlmostEqual(ci.high, 0.437503505, places=8)

    def test_wilson_never_leaves_the_unit_interval(self):
        for k, n in [(0, 1), (0, 10), (10, 10), (1, 3), (499, 500)]:
            ci = wilson(k, n)
            self.assertGreaterEqual(ci.low, 0.0)
            self.assertLessEqual(ci.high, 1.0)
            self.assertLessEqual(ci.low, ci.point)
            self.assertGreaterEqual(ci.high, ci.point)

    def test_wilson_has_width_at_the_extremes_and_wald_does_not(self):
        """The reason wald is unreachable from interval()."""
        self.assertEqual(wald(0, 20).width_pp, 0.0)
        self.assertEqual(wald(20, 20).width_pp, 0.0)
        self.assertGreater(wilson(0, 20).high, 0.10)
        self.assertLess(wilson(20, 20).low, 0.90)

    def test_clopper_pearson_is_conservative(self):
        for k, n in [(3, 20), (15, 50), (250, 500)]:
            cp, w = clopper_pearson(k, n), wilson(k, n)
            self.assertLessEqual(cp.low, w.low + 1e-9)
            self.assertGreaterEqual(cp.high, w.high - 1e-9)

    def test_clopper_pearson_known_values(self):
        # 0/10 at 95%: exact upper bound is 1 - 0.025^(1/10) = 0.3085.
        self.assertAlmostEqual(clopper_pearson(0, 10).high, 0.30850, places=4)
        self.assertEqual(clopper_pearson(0, 10).low, 0.0)
        self.assertEqual(clopper_pearson(10, 10).high, 1.0)

    def test_interval_refuses_wald(self):
        with self.assertRaises(ValueError):
            interval(1, 10, method="wald")

    def test_rule_of_three(self):
        self.assertAlmostEqual(rule_of_three(20), 0.1498, places=3)
        self.assertAlmostEqual(rule_of_three(100), 0.02996, places=4)

    def test_min_n_for_halfwidth(self):
        self.assertEqual(min_n_for_halfwidth(5.0), 385)  # the familiar n=385
        self.assertEqual(min_n_for_halfwidth(1.0), 9604)

    def test_two_proportion_overlapping_is_not_significant(self):
        r = two_proportion(6, 10, 5, 10)
        self.assertFalse(r["significant"])

    def test_two_proportion_clearly_different_is_significant(self):
        r = two_proportion(450, 500, 250, 500)
        self.assertTrue(r["significant"])
        self.assertGreater(r["diff_pp"], 30)

    def test_k_greater_than_n_rejected(self):
        with self.assertRaises(ValueError):
            wilson(11, 10)

    def test_zero_instances_does_not_crash(self):
        ci = wilson(0, 0)
        self.assertEqual((ci.low, ci.high), (0.0, 1.0))


class TestLoader(unittest.TestCase):
    def test_rejects_unknown_schema(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "results.json"
            p.write_text(json.dumps({"schema_version": 99, "config": {}, "aggregate": {}, "instances": []}))
            with self.assertRaises(SchemaError):
                Run.load(p)

    def test_rejects_missing_keys(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "results.json"
            p.write_text(json.dumps({"schema_version": 1, "config": {}}))
            with self.assertRaises(SchemaError):
                Run.load(p)

    def test_repo_derivation(self):
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), make_results(n=1, k=1, instance_prefix="django__django"))
            self.assertEqual(run.instances[0].repo, "django/django")

    def test_infra_failures_excluded_from_n_scorable(self):
        with tempfile.TemporaryDirectory() as t:
            doc = make_results(n=4, k=1)
            doc["instances"][3]["outcome"] = "eval_error"
            doc["instances"][3]["failure_reason"] = "patch_apply_or_eval_failed"
            run = write_run(Path(t), doc)
            self.assertEqual(run.n, 4)
            self.assertEqual(run.n_scorable, 3)

    def test_mixed_model_detected(self):
        with tempfile.TemporaryDirectory() as t:
            doc = make_results(n=2, k=1)
            doc["instances"][1]["model"] = "other-model"
            run = write_run(Path(t), doc)
            self.assertTrue(run.model.startswith("MIXED:"))


class TestHonestyRefusals(unittest.TestCase):
    """Each test tries to get a misleading claim out of the reporter."""

    def _v(self, doc, **kw):
        with tempfile.TemporaryDirectory() as t:
            return honesty.evaluate(write_run(Path(t), doc), **kw)

    def _codes(self, v):
        return {f.code for f in v.findings}

    def test_a_subset_can_never_be_a_dataset_score(self):
        v = self._v(make_results(n=499, k=300, dataset_size=500))
        self.assertIn("subset_not_a_dataset_score", self._codes(v))
        self.assertFalse(v.may_quote_headline_rate)

    def test_tiny_n_is_blocked(self):
        v = self._v(make_results(n=5, k=5))
        self.assertIn("sample_too_small_for_a_rate", self._codes(v))
        self.assertFalse(v.may_quote_headline_rate)

    def test_perfect_small_run_is_not_quotable(self):
        """The 2/2 = '100%' case that started all this."""
        v = self._v(make_results(n=2, k=2))
        self.assertFalse(v.may_quote_headline_rate)
        self.assertIn("perfect_score_is_a_lower_bound", self._codes(v))

    def test_zero_successes_is_reported_as_an_upper_bound(self):
        v = self._v(make_results(n=20, k=0))
        self.assertIn("zero_successes_is_an_upper_bound", self._codes(v))

    def test_full_clean_run_is_quotable_once_the_defects_are_fixed(self):
        """The rule engine, with the defect registry emptied.

        As of today two BLOCK-level defects are open, so no run at all is
        quotable -- see test_open_defects_block_even_a_full_dataset_run. This
        test isolates the rest of the rules so that fixing the defects is
        known to be sufficient.
        """
        doc = make_results(n=500, k=300, dataset_size=500)
        saved = list(honesty.KNOWN_HARNESS_DEFECTS)
        honesty.KNOWN_HARNESS_DEFECTS[:] = []
        self.addCleanup(lambda: honesty.KNOWN_HARNESS_DEFECTS.__setitem__(slice(None), saved))
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), doc)
            gold = write_run(Path(t), make_results(run_id="g", runner="gold", n=500, k=500, dataset_size=500, instance_prefix="acme__proj"))
            empty = write_run(Path(t), make_results(run_id="e", runner="empty", n=500, k=0, dataset_size=500, instance_prefix="acme__proj"))
            v = honesty.evaluate(
                run,
                controls={"gold": gold, "empty": empty},
                sibling_runs=[run],
                declared_random_seed=1,
            )
        self.assertTrue(v.may_quote_headline_rate, [f.code for f in v.blocks])
        self.assertIn("all 500 instances", honesty.claim_label(run, v))

    def test_broken_gold_control_blocks_everything(self):
        doc = make_results(n=500, k=300, dataset_size=500)
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), doc)
            gold = write_run(Path(t), make_results(run_id="g", runner="gold", n=500, k=490, dataset_size=500))
            v = honesty.evaluate(run, controls={"gold": gold}, sibling_runs=[run], declared_random_seed=1)
        self.assertIn("gold_control_failed", self._codes(v))
        self.assertFalse(v.may_quote_headline_rate)

    def test_scoring_empty_control_blocks_everything(self):
        doc = make_results(n=500, k=300, dataset_size=500)
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), doc)
            empty = write_run(Path(t), make_results(run_id="e", runner="empty", n=500, k=3, dataset_size=500))
            v = honesty.evaluate(run, controls={"empty": empty}, sibling_runs=[run], declared_random_seed=1)
        self.assertIn("empty_control_scored", self._codes(v))
        self.assertFalse(v.may_quote_headline_rate)

    def test_model_change_mid_run_blocks(self):
        doc = make_results(n=500, k=300, dataset_size=500)
        doc["instances"][7]["model"] = "someone-else"
        v = self._v(doc, declared_random_seed=1)
        self.assertIn("model_changed_mid_run", self._codes(v))
        self.assertFalse(v.may_quote_headline_rate)

    def test_pytest_defect_flagged_only_when_relevant(self):
        v = self._v(make_results(n=40, k=20, instance_prefix="pytest-dev__pytest"))
        self.assertIn("defect:pytest_instances_unwinnable", self._codes(v))
        v2 = self._v(make_results(n=40, k=20, instance_prefix="django__django"))
        self.assertNotIn("defect:pytest_instances_unwinnable", self._codes(v2))

    def test_open_defects_block_even_a_full_dataset_run(self):
        """While the F2P leak is open, no run is quotable. That is the point."""
        doc = make_results(n=500, k=300, dataset_size=500)
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), doc)
            v = honesty.evaluate(run, sibling_runs=[run], declared_random_seed=1)
        open_blocking = [d for d in honesty.KNOWN_HARNESS_DEFECTS if d.severity == honesty.BLOCK]
        if open_blocking:
            self.assertFalse(v.may_quote_headline_rate)

    def test_reused_inference_timestamps_flagged(self):
        doc = make_results(
            n=40, k=20,
            started="2026-08-13T10:00:00+00:00",
            finished="2026-08-13T10:00:05+00:00",
            wall_total=800.0,
        )
        self.assertIn("config_timestamps_inconsistent_with_work", self._codes(self._v(doc)))

    def test_empty_run_short_circuits(self):
        v = self._v(make_results(n=0, k=0))
        self.assertIn("empty_run", self._codes(v))
        self.assertFalse(v.may_quote_headline_rate)

    def test_zero_cost_on_an_unknown_model_stays_ambiguous(self):
        """Model not in the price table: we cannot tell a bug from a freebie."""
        v = self._v(make_results(n=40, k=20, cost=0.0, model="m"))
        self.assertIn("cost_is_zero_and_model_pricing_unknown", self._codes(v))

    def test_zero_cost_on_a_priced_model_is_called_a_defect(self):
        """glm-5.2:cloud IS priced, so a zero is broken accounting, not a
        subscription. The old wording asserted the flattering reading."""
        v = self._v(make_results(n=40, k=20, cost=0.0, model="glm-5.2:cloud"))
        codes = self._codes(v)
        self.assertIn("cost_is_zero_but_model_is_priced", codes)
        self.assertNotIn("cost_is_zero_and_model_pricing_unknown", codes)

    def test_zero_cost_on_a_local_model_is_correct(self):
        v = self._v(make_results(n=40, k=20, cost=0.0, model="qwen2.5:7b"))
        self.assertIn("cost_is_zero_because_model_is_local", self._codes(v))

    def test_nonzero_cost_produces_no_cost_finding(self):
        codes = self._codes(self._v(make_results(n=40, k=20, cost=1.5, model="glm-5.2:cloud")))
        self.assertFalse([c for c in codes if c.startswith("cost_is_zero")])

    def test_model_pricing_classifier(self):
        self.assertEqual(honesty.model_pricing("glm-5.2:cloud")[0], "priced")
        self.assertEqual(honesty.model_pricing("GLM-5.2:cloud")[0], "priced")
        self.assertEqual(honesty.model_pricing("llama3.1:8b")[0], "free")
        self.assertEqual(honesty.model_pricing("ollama/whatever")[0], "free")
        self.assertEqual(honesty.model_pricing(None)[0], "unknown")
        self.assertEqual(honesty.model_pricing("MIXED:a,b")[0], "unknown")


class TestSeedProvenance(unittest.TestCase):
    """`config.sampling.seed` is the run's own record of how it was drawn.

    The reporter used to read only the `--seed` CLI flag, so every schema-v2
    sample was told it had not declared a seed while its full provenance sat
    in the artefact next to the finding.
    """

    def _codes(self, doc, **kw):
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), doc)
            return {f.code for f in honesty.evaluate(run, **kw).findings}

    def _sampled(self, **samp):
        doc = make_results(n=40, k=20)
        doc["schema_version"] = 2
        base = {
            "method": "stratified-by-repo+hard-weighted",
            "seed": 20260813,
            "n_requested": 40,
            "population": 500,
            "hard_weighted": True,
            "weight_formula": "(0.10 + hardness)**2",
            "hardness_formula": "0.40*difficulty + ...",
            "mean_hardness_sample": 0.4434,
            "mean_hardness_population": 0.2967,
        }
        base.update(samp)
        doc["config"]["sampling"] = base
        return doc

    def test_recorded_seed_satisfies_the_declaration(self):
        codes = self._codes(self._sampled())
        self.assertNotIn("selection_not_a_declared_random_sample", codes)
        self.assertIn("selection_is_a_declared_seeded_sample", codes)

    def test_no_sampling_block_still_fires(self):
        doc = make_results(n=40, k=20)
        codes = self._codes(doc)
        self.assertIn("selection_not_a_declared_random_sample", codes)

    def test_cli_seed_still_overrides_for_out_of_band_draws(self):
        doc = make_results(n=40, k=20)
        codes = self._codes(doc, declared_random_seed=7)
        self.assertNotIn("selection_not_a_declared_random_sample", codes)

    def test_hard_weighting_is_reported_separately_from_seeding(self):
        """A seeded sample can still be unrepresentative, and that is a
        different claim from 'selection is undeclared'."""
        codes = self._codes(self._sampled())
        self.assertIn("sample_deliberately_weighted_hard", codes)
        codes_uniform = self._codes(self._sampled(hard_weighted=False))
        self.assertNotIn("sample_deliberately_weighted_hard", codes_uniform)

    def test_a_seeded_sample_is_not_thereby_quotable(self):
        """Declaring the seed removes one WARN; it does not remove a BLOCK."""
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), self._sampled())
            self.assertFalse(honesty.evaluate(run).may_quote_headline_rate)


class TestAirgapStatus(unittest.TestCase):
    """The web-lookup BLOCK closes only on recorded, probe-backed evidence."""

    def _run(self, tmp, *, airgap=None, net=None):
        doc = make_results(n=40, k=20)
        doc["schema_version"] = 2
        doc["config"]["f2p_hint"] = False
        if airgap is not None:
            doc["config"]["airgap"] = airgap
        if net is not None:
            doc["aggregate"]["network_tool_use"] = net
        return write_run(Path(tmp), doc)

    _CLEAN_NET = {
        "calls_by_tool": {},
        "succeeded_by_tool": {},
        "refused_by_tool": {},
        "residual_shell_egress": {"instances": {}, "scanned": 40},
    }
    _GOOD_AIRGAP = {"enforced": True, "denial_evidence": "permission denied"}

    def test_absent_by_default(self):
        with tempfile.TemporaryDirectory() as t:
            self.assertEqual(honesty.airgap_status(self._run(t))[0], "absent")

    def test_requested_but_unproven_is_its_own_block(self):
        with tempfile.TemporaryDirectory() as t:
            run = self._run(t, airgap={"enforced": False, "error": "HTTP 500"})
            self.assertEqual(honesty.airgap_status(run)[0], "unverified")
            codes = {f.code for f in honesty.evaluate(run).blocks}
            self.assertIn("airgap_requested_but_not_verified", codes)

    def test_unscanned_residual_surface_is_not_a_pass(self):
        """A missing key must never read as clean."""
        with tempfile.TemporaryDirectory() as t:
            run = self._run(t, airgap=self._GOOD_AIRGAP, net={"calls_by_tool": {}})
            self.assertEqual(honesty.airgap_status(run)[0], "unverified")

    def test_successful_calls_despite_a_passing_probe_is_a_breach(self):
        with tempfile.TemporaryDirectory() as t:
            net = dict(self._CLEAN_NET, calls_by_tool={"web_fetch": 3},
                       succeeded_by_tool={"web_fetch": 3})
            run = self._run(t, airgap=self._GOOD_AIRGAP, net=net)
            self.assertEqual(honesty.airgap_status(run)[0], "breached")
            self.assertIn(
                "airgap_verified_but_breached", {f.code for f in honesty.evaluate(run).blocks}
            )

    def test_refused_attempts_are_not_a_breach(self):
        """The airgap working looks like attempts in the log. Treating those as
        a breach reported the first successful airgap as a failure."""
        with tempfile.TemporaryDirectory() as t:
            net = dict(self._CLEAN_NET,
                       calls_by_tool={"web_search": 5, "web_fetch": 2},
                       refused_by_tool={"web_search": 5, "web_fetch": 2},
                       succeeded_by_tool={},
                       instances_that_used_one=["a__b-1", "a__b-2"])
            run = self._run(t, airgap=self._GOOD_AIRGAP, net=net)
            self.assertEqual(honesty.airgap_status(run)[0], "verified")
            codes = {f.code for f in honesty.evaluate(run).findings}
            self.assertIn("web_lookup_attempted_and_refused", codes)
            self.assertNotIn("defect:web_lookup_of_solution_not_prevented", codes)

    def test_a_pre_split_run_stays_conservative(self):
        """Older results.json has no succeeded_by_tool; any call is a breach."""
        with tempfile.TemporaryDirectory() as t:
            net = {"calls_by_tool": {"web_fetch": 1},
                   "residual_shell_egress": {"instances": {}, "scanned": 1}}
            run = self._run(t, airgap=self._GOOD_AIRGAP, net=net)
            self.assertEqual(honesty.airgap_status(run)[0], "breached")

    def test_shell_egress_hits_are_a_breach(self):
        with tempfile.TemporaryDirectory() as t:
            net = dict(
                self._CLEAN_NET,
                residual_shell_egress={"instances": {"a__b-1": [{"command": "urlopen"}]}},
            )
            run = self._run(t, airgap=self._GOOD_AIRGAP, net=net)
            self.assertEqual(honesty.airgap_status(run)[0], "breached")

    def test_verified_closes_the_web_lookup_defect(self):
        with tempfile.TemporaryDirectory() as t:
            run = self._run(t, airgap=self._GOOD_AIRGAP, net=self._CLEAN_NET)
            self.assertEqual(honesty.airgap_status(run)[0], "verified")
            codes = {f.code for f in honesty.evaluate(run).findings}
            self.assertNotIn("defect:web_lookup_of_solution_not_prevented", codes)
            self.assertIn("web_lookup_prevention_verified", codes)

    def test_verified_does_not_make_a_subset_quotable(self):
        """Closing one block must not be mistaken for closing the gate."""
        with tempfile.TemporaryDirectory() as t:
            run = self._run(t, airgap=self._GOOD_AIRGAP, net=self._CLEAN_NET)
            v = honesty.evaluate(run)
            self.assertFalse(v.may_quote_headline_rate)
            self.assertIn("subset_not_a_dataset_score", {f.code for f in v.blocks})


class TestSchemaV2(unittest.TestCase):
    """The multi-attempt and dropped-path fields added by bench/swebench v2."""

    def _v2(self, **over):
        doc = make_results(**over.pop("base", {}))
        doc["schema_version"] = 2
        doc["config"].setdefault("f2p_hint", False)
        return doc

    def test_v2_loads(self):
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), self._v2())
            self.assertEqual(run.schema_version, 2)

    def test_pass_at_k_headline_is_blocked(self):
        doc = self._v2(base=dict(n=40, k=20))
        doc["config"]["attempts"] = 5
        doc["aggregate"]["attempts"] = 5
        doc["aggregate"]["pass_at_1"] = 0.30
        for inst in doc["instances"]:
            inst["attempts_n"] = 5
            inst["resolved_any"] = inst["resolved"]
            inst["resolved_all"] = False
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), doc)
            v = honesty.evaluate(run)
        self.assertEqual(run.attempts, 5)
        self.assertIn(
            "headline_is_pass_at_k_not_pass_at_1", {f.code for f in v.findings}
        )
        self.assertFalse(v.may_quote_headline_rate)

    def test_f2p_hint_off_clears_that_defect(self):
        doc = self._v2(base=dict(n=40, k=20))
        doc["config"]["f2p_hint"] = False
        with tempfile.TemporaryDirectory() as t:
            v = honesty.evaluate(write_run(Path(t), doc))
        self.assertNotIn(
            "defect:f2p_test_names_leaked_to_agent", {f.code for f in v.findings}
        )

    def test_f2p_hint_on_reinstates_the_block(self):
        doc = self._v2(base=dict(n=40, k=20))
        doc["config"]["f2p_hint"] = True
        with tempfile.TemporaryDirectory() as t:
            v = honesty.evaluate(write_run(Path(t), doc))
        self.assertIn(
            "defect:f2p_test_names_leaked_to_agent", {f.code for f in v.findings}
        )

    def test_v1_run_without_the_key_is_treated_as_leaked(self):
        """The hint was unconditional before the flag existed."""
        with tempfile.TemporaryDirectory() as t:
            v = honesty.evaluate(write_run(Path(t), make_results(n=40, k=20)))
        self.assertIn(
            "defect:f2p_test_names_leaked_to_agent", {f.code for f in v.findings}
        )

    def test_stripped_source_file_is_detected_and_blocks(self):
        doc = self._v2(base=dict(n=40, k=20, instance_prefix="pytest-dev__pytest"))
        doc["instances"][0]["dropped_test_paths"] = ["src/_pytest/python.py"]
        doc["instances"][1]["dropped_test_paths"] = ["testing/test_ok.py"]  # genuine
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), doc)
            v = honesty.evaluate(run)
        self.assertEqual(list(run.dropped_source_paths), [doc["instances"][0]["instance_id"]])
        self.assertIn(
            "source_files_stripped_from_graded_patch", {f.code for f in v.findings}
        )
        self.assertFalse(v.may_quote_headline_rate)

    def test_v2_transcript_dir_is_preferred_over_reconstruction(self):
        with tempfile.TemporaryDirectory() as t:
            real = Path(t) / "traj"
            real.mkdir()
            doc = self._v2(base=dict(n=1, k=0))
            doc["instances"][0]["transcript_dir"] = str(real)
            a = fail_mod.analyse(write_run(Path(t), doc))
        self.assertEqual(a.failures[0].evidence.transcript, real)
        self.assertEqual(a.transcripts_missing, 0)

    def test_swebench_bucket_is_adopted_with_fault_mapping(self):
        with tempfile.TemporaryDirectory() as t:
            doc = self._v2(base=dict(n=1, k=0))
            doc["instances"][0]["failure_bucket"] = "context_compaction_lost_plan"
            doc["instances"][0]["failure_fault"] = "osa"
            a = fail_mod.analyse(write_run(Path(t), doc))
        self.assertEqual(a.failures[0].bucket.code, "context_compaction_lost_plan")
        self.assertEqual(a.failures[0].bucket.attribution, fail_mod.AGENT)

    def test_schema_v3_is_refused(self):
        with tempfile.TemporaryDirectory() as t:
            doc = self._v2()
            doc["schema_version"] = 3
            p = Path(t) / "results.json"
            p.write_text(json.dumps(doc))
            with self.assertRaises(SchemaError):
                Run.load(p)


class TestFailures(unittest.TestCase):
    def test_buckets_map_to_attribution(self):
        self.assertEqual(fail_mod.bucket_for("harness_error").attribution, fail_mod.HARNESS)
        self.assertEqual(fail_mod.bucket_for("no_patch_produced").attribution, fail_mod.AGENT)
        self.assertEqual(
            fail_mod.bucket_for("fix_incomplete_fail_to_pass_still_failing").attribution,
            fail_mod.MODEL,
        )
        self.assertEqual(fail_mod.bucket_for("nonsense").attribution, fail_mod.UNKNOWN)

    def test_analysis_counts_and_leads(self):
        with tempfile.TemporaryDirectory() as t:
            doc = make_results(n=10, k=0)
            for inst in doc["instances"]:
                inst["failure_reason"] = "no_patch_produced"
                inst["outcome"] = "empty_patch"
            a = fail_mod.analyse(write_run(Path(t), doc))
        self.assertEqual(len(a.failures), 10)
        self.assertEqual(a.by_bucket["no_patch_produced"], 10)
        self.assertEqual(a.by_attribution[fail_mod.AGENT], 10)
        self.assertTrue(any("clean working" in l for l in a.leads))

    def test_zero_tool_call_failures_surface_as_a_lead(self):
        with tempfile.TemporaryDirectory() as t:
            doc = make_results(n=4, k=0)
            for inst in doc["instances"]:
                inst["tool_calls"] = 0
            a = fail_mod.analyse(write_run(Path(t), doc))
        self.assertTrue(any("ZERO tool calls" in l for l in a.leads))

    def test_missing_transcripts_are_counted_not_hidden(self):
        with tempfile.TemporaryDirectory() as t:
            os.environ["OSA_HOME"] = t  # no sessions dir -> nothing resolvable
            a = fail_mod.analyse(write_run(Path(t), make_results(n=3, k=0)))
            os.environ.pop("OSA_HOME")
        self.assertEqual(a.transcripts_missing, 3)


class TestRender(unittest.TestCase):
    def test_blocked_run_never_prints_a_bare_headline_percentage(self):
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), make_results(n=2, k=2))
            v = honesty.evaluate(run)
            out = render_mod.render(run, verdict=v, analysis=fail_mod.analyse(run))
        self.assertNotIn("**2 / 2 resolved — 100.0%**", out)
        self.assertIn("2 of 2 instances resolved", out)
        self.assertIn("may not be quoted as a score", out)

    def test_report_always_carries_the_cross_harness_refusal(self):
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), make_results(n=40, k=20))
            out = render_mod.render(
                run, verdict=honesty.evaluate(run), analysis=fail_mod.analyse(run)
            )
        self.assertIn("cannot be compared with any other harness", out)

    def test_denominator_is_always_present(self):
        with tempfile.TemporaryDirectory() as t:
            run = write_run(Path(t), make_results(n=40, k=20))
            out = render_mod.render(
                run, verdict=honesty.evaluate(run), analysis=fail_mod.analyse(run)
            )
        self.assertIn("40 of 500 instances", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
