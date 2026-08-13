"""Rules that decide what a run is allowed to claim.

The premise: a number that cannot survive scrutiny is worse than no number.
So the reporter is not a formatter with warnings bolted on -- it is a gate.
Every claim has to earn its wording, and the wording is computed, not chosen.

Three severities:

  BLOCK  the run may not be quoted as a headline rate at all. The reporter
         prints counts and an interval, and refuses to emit a bare percentage
         as a claim.
  WARN   the number may be quoted, but only with the caveat attached to it.
  NOTE   context a reader needs; does not constrain the claim.

`KNOWN_HARNESS_DEFECTS` is the part that matters most in practice. Defects
found by auditing the pipeline are encoded here, so that every report
generated while a defect is open carries the defect on its face. Removing an
entry from that list is a claim that the defect is fixed, and should be made
in the same commit that fixes it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from stats import interval, min_n_for_halfwidth, rule_of_three

if TYPE_CHECKING:
    from loader import Run

BLOCK, WARN, NOTE = "BLOCK", "WARN", "NOTE"
_ORDER = {BLOCK: 0, WARN: 1, NOTE: 2}

#: Below this many tasks we refuse to present a percentage as the headline.
#: 30 is not magic; it is the point at which a Wilson interval on a mid-range
#: rate stops being wider than the entire spread of the public leaderboard.
MIN_N_FOR_RATE = 30

#: If the 95% interval is wider than this, the number cannot separate any two
#: harnesses anyone would actually compare, so it is not a ranking claim.
MAX_USEFUL_CI_WIDTH_PP = 20.0


@dataclass(frozen=True)
class Finding:
    severity: str
    code: str
    message: str
    detail: str = ""

    def to_json(self) -> dict:
        d = {"severity": self.severity, "code": self.code, "message": self.message}
        if self.detail:
            d["detail"] = self.detail
        return d


# ---------------------------------------------------------------------------
# Defects found by auditing bench/swebench. Each one distorts a reported score.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Defect:
    code: str
    severity: str
    direction: str  # inflates | deflates | distorts
    message: str
    detail: str
    #: Predicate over a Run; None means "always applies until fixed".
    applies_when: object = None


KNOWN_HARNESS_DEFECTS: list[Defect] = [
    Defect(
        code="f2p_test_names_leaked_to_agent",
        severity=BLOCK,
        direction="inflates",
        message=(
            "This run enabled --f2p-hint: the hidden FAIL_TO_PASS test node "
            "IDs were readable by the agent in run_tests.sh."
        ),
        detail=(
            "bench/swebench bakes the FAIL_TO_PASS node ids into run_tests.sh "
            "(mode 0755) at the repo root, and the prompt tells the agent to "
            "use that script. Test names routinely state the required "
            "behaviour outright -- pallets__flask-5014's only F2P is "
            "'tests/test_blueprints.py::test_empty_name_not_allowed'. The "
            "official SWE-bench submission checklist requires 'Does not use "
            "SWE-bench test knowledge (PASS_TO_PASS, FAIL_TO_PASS)'; a run in "
            "this state is not leaderboard-eligible and its rate is an "
            "overestimate of unaided ability. The flag now defaults to OFF; "
            "leave it off for any run whose number will be quoted."
        ),
        # Only fires when the run actually enabled the hint. Runs predating
        # the flag have no key and are treated as leaked, which is correct:
        # the hint was unconditional before it existed.
        applies_when=lambda run: run.config.get("f2p_hint", True) is not False,
    ),
    Defect(
        code="web_lookup_of_solution_not_prevented",
        severity=BLOCK,
        direction="inflates",
        message=(
            "The agent has unrestricted network and web tools while the prompt "
            "names the repo and the exact base commit."
        ),
        detail=(
            "The task container is started --network none, but the agent runs "
            "on the host, and bench/swebench/osa_runner.py sets "
            "'permission_mode overdrive' which disables the approval path "
            "entirely. OSA ships web_search, web_fetch and download builtins. "
            "The upstream fix for every SWE-bench instance is a public commit, "
            "so the agent can in principle retrieve the answer. The official "
            "checklist requires 'Does not have web-browsing OR has taken steps "
            "to prevent lookup of SWE-bench solutions via web-browsing'. Until "
            "the bench disables those tools (or the run is executed with no "
            "egress), the score cannot be attributed to problem-solving. "
            "Closing this needs THREE things recorded in the run's own "
            "artefacts, all checked by airgap_status(): a probe attestation "
            "in config.airgap showing a live backend refusing a denied tool; "
            "zero network-tool calls in aggregate.network_tool_use; and an "
            "explicit (possibly empty) residual_shell_egress list. See "
            "bench/swebench/airgap.py."
        ),
        applies_when=lambda run: airgap_status(run)[0] != "verified",
    ),
    Defect(
        code="pytest_instances_unwinnable",
        severity=WARN,
        direction="deflates",
        message=(
            "FIXED. Runs recorded before the fix stripped legitimate source "
            "files and reported the result as 'no_patch_produced'."
        ),
        detail=(
            "bench/swebench/runners.py used to guess which files the grader "
            "would revert by matching the substring 'test/', which is "
            "contained in 'src/_pytest/'. Every pytest-dev/pytest instance "
            "therefore had its entire source patch stripped before grading, "
            "and the empty diff was then charged to the agent. Verified "
            "against all 500 gold patches: 19 stripped in full, 0 in part, an "
            "achievable ceiling of 96.2%. It also matched legitimate source "
            "paths such as django/test/client.py.\n\n"
            "The fix is `test_patch_files()`, which derives the strip list "
            "from the instance's own test_patch — the exact set the grader "
            "reverts — so it is correct by construction rather than merely "
            "less wrong. Re-verified across all 500 gold patches: 0 damaged, "
            "ceiling 100.0%.\n\n"
            "This entry is retained rather than deleted because it still "
            "applies to results recorded BEFORE the fix, and a report over old "
            "data must keep carrying the caveat. It fires only on runs whose "
            "harness predates it."
        ),
        applies_when=lambda run: (
            any(i.instance_id.startswith("pytest-dev__pytest") for i in run.instances)
            and not _strip_list_derived_from_test_patch(run)
        ),
    ),
    Defect(
        code="gold_control_bypasses_patch_extraction",
        severity=WARN,
        direction="distorts",
        message=(
            "The gold control does not exercise the workspace or patch "
            "extraction path, so it cannot detect bugs in either."
        ),
        detail=(
            "bench/swebench/runners.py:GoldRunner returns the dataset's own "
            "patch string directly. It never materialises a workspace and "
            "never calls git_diff(). A gold run at 100% therefore validates "
            "grading only. The pytest stripping defect above sat in exactly "
            "the blind spot this creates. A trustworthy upper control would "
            "apply the gold patch to the prepared workspace and let the normal "
            "extraction path produce the diff."
        ),
    ),
]


# ---------------------------------------------------------------------------
# Was web lookup actually prevented?
# ---------------------------------------------------------------------------


def airgap_status(run: "Run") -> tuple[str, str]:
    """Classify a run's web-lookup posture from its own artefacts.

    Returns `(status, reason)` where status is one of:

      "absent"      no airgap was installed. The original defect stands.
      "unverified"  an airgap was requested but the live probe did not observe
                    a refusal. This is WORSE than absent, because a knob that
                    silently does nothing invites the number to be quoted.
      "breached"    the airgap was verified and network tools were used anyway.
                    Either the enforcement regressed mid-run or the harness is
                    mis-recording; either way the run is not usable.
      "verified"    probe observed a refusal, no network tool call was
                    recorded, and the residual shell surface was explicitly
                    scanned.

    Deliberately evidence-first and fail-closed: every unknown maps to a state
    that keeps the block standing. A missing key is never read as a pass.
    """
    ag = run.airgap
    net = run.network_tool_use

    if not ag:
        return "absent", "no config.airgap block; no airgap was installed"

    if ag.get("enforced") is not True:
        return (
            "unverified",
            "config.airgap is present but `enforced` is not true — the probe "
            "did not observe a live backend refusing a denied tool"
            + (f" ({ag['error']})" if ag.get("error") else ""),
        )

    # Attempts and successes are different questions. A DENIED web_fetch
    # cannot have carried the answer back, so it is not a breach -- it is
    # evidence that enforcement bit. Only a call that RETURNED invalidates a
    # score. Runs recorded before this split have no `succeeded_by_tool`, and
    # for those the conservative reading (any call is a breach) is kept.
    succeeded = net.get("succeeded_by_tool")
    if succeeded is None:
        succeeded = net.get("calls_by_tool") or {}
    if succeeded:
        return (
            "breached",
            "the airgap probe passed but network tool calls still SUCCEEDED: "
            f"{succeeded}"
            + (
                f" on {net.get('instances_that_got_through')}"
                if net.get("instances_that_got_through")
                else ""
            ),
        )

    # The residual surface (shell/python egress) must have been LOOKED AT.
    # An absent key means nobody scanned, which is not the same as clean.
    if "residual_shell_egress" not in net:
        return (
            "unverified",
            "no residual_shell_egress key in network_tool_use — the surface "
            "the deny rules cannot cover was never scanned, so 'clean' is "
            "unsupported",
        )

    residual = net.get("residual_shell_egress") or {}
    hits = residual.get("instances") if isinstance(residual, dict) else residual
    if hits:
        return (
            "breached",
            f"shell commands with egress markers were recorded: {hits}",
        )

    return (
        "verified",
        "a live probe observed the backend refusing web_fetch under "
        "permission_mode overdrive; no network tool call and no shell egress "
        "marker appears anywhere in this run's recorded streams",
    )


# ---------------------------------------------------------------------------
# Is a reported cost of zero a property of the provider, or a defect?
# ---------------------------------------------------------------------------

#: Models OSA's own pricing table prices, transcribed from
#: lib/optimal_system_agent/agent/pricing.ex and the provider catalogs it
#: merges (Providers.OllamaCloud etc.). This is a duplicate of OSA's data and
#: will drift; it is here so `bench/report` stays pure Python and needs no BEAM
#: to tell a subscription apart from a bug. Only entries actually used by a run
#: on disk need to be present -- an unknown model falls through to "unknown",
#: which keeps the softer wording rather than asserting a defect.
KNOWN_MODEL_PRICING: dict[str, tuple[float, float]] = {
    "glm-5.2:cloud": (0.60, 2.20),
    "glm-5.1:cloud": (0.60, 2.20),
    "glm-4.7:cloud": (0.60, 2.20),
    "glm-4.6:cloud": (0.60, 2.20),
    "glm-4.6": (0.60, 2.20),
    "glm-4.5": (0.60, 2.20),
    "claude-3-5-sonnet": (3.0, 15.0),
    "claude-sonnet-4": (3.0, 15.0),
    "claude-opus-4": (15.0, 75.0),
    "gpt-4o": (2.5, 10.0),
    "gpt-4.1": (2.0, 8.0),
}

#: `Pricing.ollama_local?/1` — a tag with a colon naming a local model family
#: and NOT containing "cloud" is genuinely free. Mirrored so the reporter
#: reaches the same verdict OSA does.
_LOCAL_FAMILIES = ("llama", "qwen", "mistral", "gemma", "phi")


def model_pricing(model: str | None) -> tuple[str, tuple[float, float] | None]:
    """`("priced"|"free"|"unknown", rates)` for a model id.

    Mirrors `Agent.Pricing.rates/1` closely enough to answer one question: is a
    reported cost of exactly zero explicable by the price list?
    """
    if not model or model in ("unknown", "osa") or model.startswith("MIXED:"):
        return "unknown", None
    key = model.lower()
    if key.startswith("ollama/"):
        return "free", (0.0, 0.0)
    if ":" in key and "cloud" not in key and any(f in key for f in _LOCAL_FAMILIES):
        return "free", (0.0, 0.0)
    if key in KNOWN_MODEL_PRICING:
        return "priced", KNOWN_MODEL_PRICING[key]
    for family, rates in (("glm", (0.60, 2.20)), ("claude", (3.0, 15.0))):
        if key.startswith(family):
            return "priced", rates
    return "unknown", None


def _applicable_defects(run: "Run") -> list[Defect]:
    out = []
    for d in KNOWN_HARNESS_DEFECTS:
        if d.applies_when is None or d.applies_when(run):
            out.append(d)
    return out


# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------


@dataclass
class Verdict:
    findings: list[Finding] = field(default_factory=list)

    def add(self, severity: str, code: str, message: str, detail: str = "") -> None:
        self.findings.append(Finding(severity, code, message, detail))

    @property
    def blocks(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == BLOCK]

    @property
    def warns(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == WARN]

    @property
    def may_quote_headline_rate(self) -> bool:
        """False means: print counts and an interval, never a bare percentage."""
        return not self.blocks

    def sorted(self) -> list[Finding]:
        return sorted(self.findings, key=lambda f: (_ORDER[f.severity], f.code))

    def to_json(self) -> dict:
        return {
            "may_quote_headline_rate": self.may_quote_headline_rate,
            "block_count": len(self.blocks),
            "warn_count": len(self.warns),
            "findings": [f.to_json() for f in self.sorted()],
        }


# ---------------------------------------------------------------------------
# The rules
# ---------------------------------------------------------------------------


def evaluate(
    run: "Run",
    *,
    controls: dict[str, "Run"] | None = None,
    sibling_runs: list["Run"] | None = None,
    confidence: float = 0.95,
    declared_random_seed: int | None = None,
) -> Verdict:
    """Decide what `run` may claim.

    `controls` maps runner name ("gold"/"empty") to the control Run, if one was
    found for the same instance set. `sibling_runs` are other runs of the same
    instance set with the same config, used to say something about variance.
    """
    v = Verdict()
    n, k = run.n, run.k

    # -- the run has to exist at all ---------------------------------------
    if n == 0:
        v.add(BLOCK, "empty_run", "This run contains zero instances.")
        return v

    ci = interval(k, n, confidence)

    # -- 1. a subset is not a dataset score --------------------------------
    if not run.is_full_dataset:
        size = run.dataset_size
        v.add(
            BLOCK,
            "subset_not_a_dataset_score",
            f"This is {n} of {size} instances. It is NOT a "
            f"{run.dataset} score and must never be quoted as one.",
            detail=(
                "A rate measured on a subset estimates the rate on that subset. "
                "Published leaderboard figures are computed on the full set; "
                "quoting a subset rate beside them compares different "
                "quantities. Say 'n of N instances' every time."
            ),
        )

    # -- 2. too few tasks to have a rate at all ----------------------------
    if n < MIN_N_FOR_RATE:
        need = min_n_for_halfwidth(5.0)
        v.add(
            BLOCK,
            "sample_too_small_for_a_rate",
            f"n={n} is below {MIN_N_FOR_RATE}; a percentage here is noise "
            f"with a decimal point.",
            detail=(
                f"The {int(confidence*100)}% interval is "
                f"{ci.pct_range()} -- {ci.width_pp:.0f} percentage points wide. "
                f"Reaching +/-5pp at a mid-range rate needs about {need} tasks."
            ),
        )

    # -- 3. the interval is too wide to rank anything ----------------------
    if ci.width_pp > MAX_USEFUL_CI_WIDTH_PP:
        v.add(
            BLOCK if n < MIN_N_FOR_RATE else WARN,
            "interval_too_wide_to_rank",
            f"The {int(confidence*100)}% interval spans {ci.width_pp:.0f} "
            f"percentage points ({ci.pct_range()}).",
            detail=(
                "An interval this wide overlaps most of the public "
                "leaderboard, so this run cannot establish that any harness is "
                "better or worse than any other."
            ),
        )

    # -- 4. zero successes is not zero ability -----------------------------
    if k == 0:
        v.add(
            NOTE,
            "zero_successes_is_an_upper_bound",
            f"0/{n} bounds the true rate below "
            f"{rule_of_three(n, confidence)*100:.0f}%, it does not establish 0%.",
        )
    if k == n:
        v.add(
            NOTE,
            "perfect_score_is_a_lower_bound",
            f"{k}/{n} bounds the true rate above {ci.low*100:.0f}%; a clean "
            f"sweep of a small set is expected even from a mediocre agent.",
        )

    # -- 5. how were the instances chosen? ---------------------------------
    if not run.is_full_dataset:
        # Read the run's OWN provenance first. `--seed` remains as an operator
        # override for a set whose selection is declared out of band (an
        # --instances file copied from an earlier seeded draw, say), but a run
        # that recorded config.sampling.seed must not be told it failed to
        # declare a seed -- that finding was firing against every schema-v2
        # sample and training readers to skip it.
        samp = run.sampling
        seed = declared_random_seed if declared_random_seed is not None else run.declared_seed
        if seed is None:
            v.add(
                WARN,
                "selection_not_a_declared_random_sample",
                "The instance set was not declared as a seeded random sample, "
                "so selection bias is unquantified.",
                detail=(
                    "SWE-bench instances vary enormously in difficulty and the "
                    "dataset ships a `difficulty` field. A hand-picked or "
                    "first-N subset can be made to say almost anything. Draw "
                    "the set with `--sample N --sample-seed S` (which records "
                    "config.sampling), pass --seed to declare an out-of-band "
                    "draw, or state the selection rule."
                ),
            )
        else:
            v.add(
                NOTE,
                "selection_is_a_declared_seeded_sample",
                f"Instances were drawn with seed {seed}"
                + (f" by '{samp['method']}'." if samp.get("method") else "."),
                detail=(
                    "Provenance is recorded in config.sampling and the full "
                    "instance list is in config.instance_ids, so the draw is "
                    "reproducible and the set was not chosen after seeing any "
                    "result."
                ),
            )

        # A seeded sample can still be a deliberately unrepresentative one, and
        # that is a separate claim from "selection is undeclared". Say which
        # way it cuts rather than leaving the reader to assume it is neutral.
        if run.sample_is_hard_weighted:
            ms = samp.get("mean_hardness_sample")
            mp = samp.get("mean_hardness_population")
            v.add(
                WARN,
                "sample_deliberately_weighted_hard",
                "This set was drawn hard-weighted on purpose; it is NOT a "
                "representative sample of the dataset.",
                detail=(
                    (
                        f"Mean hardness {ms:.3f} against {mp:.3f} for the full "
                        f"dataset. "
                        if isinstance(ms, (int, float)) and isinstance(mp, (int, float))
                        else ""
                    )
                    + "Weighting formula: "
                    + str(samp.get("weight_formula", "unrecorded"))
                    + " over hardness = "
                    + str(samp.get("hardness_formula", "unrecorded"))
                    + ". The rate measured here is therefore a LOWER bound "
                    "relative to a uniform draw of the same size, and the "
                    "direction of the bias is known even though its magnitude "
                    "is not. Do not correct for it; quote the subset."
                ),
            )
        ids = run.instance_ids
        if len(ids) <= 5:
            v.add(
                WARN,
                "instance_set_is_cherry_pickable",
                f"Only {len(ids)} instances: {', '.join(sorted(ids))}.",
                detail="At this size the result is a smoke test, not a measurement.",
            )

    # -- 6. one run tells you nothing about variance -----------------------
    reps = len(sibling_runs or [])
    if reps < 1:
        v.add(
            WARN,
            "single_run_no_variance_estimate",
            "Only one run of this configuration; run-to-run variance is "
            "unmeasured.",
            detail=(
                "Agent runs are stochastic. Vendors publish means over "
                "repeated trials for this reason (Anthropic averages Claude "
                "Sonnet 4.5's SWE-bench Verified figure over 10 trials). The "
                "interval printed here covers sampling over TASKS only; it "
                "does not cover run-to-run variation on the same tasks."
            ),
        )

    # -- 7. the controls are what make the pipeline believable -------------
    controls = controls or {}
    gold, empty = controls.get("gold"), controls.get("empty")
    if gold is None:
        v.add(
            WARN,
            "no_gold_control",
            "No gold (oracle) control run over this instance set.",
            detail="Without it, a low score cannot be distinguished from a broken pipeline.",
        )
    elif gold.n and gold.k != gold.n:
        v.add(
            BLOCK,
            "gold_control_failed",
            f"The gold control scored {gold.k}/{gold.n}, not 100%. The "
            f"pipeline is broken and no score from it is meaningful.",
        )
    if empty is None:
        v.add(
            WARN,
            "no_empty_control",
            "No empty (no-op) control run over this instance set.",
            detail="Without it, a nonzero score cannot be distinguished from a grading fault.",
        )
    elif empty.k != 0:
        v.add(
            BLOCK,
            "empty_control_scored",
            f"The empty control scored {empty.k}/{empty.n}, not 0%. Grading "
            f"is passing instances that were never touched.",
        )

    # -- 8. infrastructure losses -----------------------------------------
    infra = run.infra_failures
    if infra:
        v.add(
            WARN,
            "infrastructure_failures_present",
            f"{len(infra)} of {n} instances failed for harness reasons, not "
            f"agent reasons.",
            detail=(
                "Reported both ways: as scored (counted against the agent) and "
                "as excluded (n_scorable). Neither is quotable on its own -- "
                "excluding them inflates, counting them deflates. Instances: "
                + ", ".join(sorted(i.instance_id for i in infra)[:12])
            ),
        )

    # -- 9. can we account for what it cost? -------------------------------
    missing_tok = sum(1 for i in run.instances if i.tokens_total is None)
    if missing_tok:
        v.add(
            WARN,
            "token_accounting_incomplete",
            f"{missing_tok} of {n} instances have no token count; totals are "
            f"lower bounds.",
        )
    priced = [i for i in run.instances if i.cost_usd is not None]
    if priced and all(i.cost_usd == 0 for i in priced):
        # "Zero" has two completely different meanings and the old wording
        # asserted the flattering one. If the model IS in the price table, a
        # zero is an accounting failure in OSA, and saying "subscription or
        # local model" hides a live bug behind a caveat.
        status, rates = model_pricing(run.model)
        tok_in = run.aggregate.get("tokens_in_total") or 0
        if status == "priced" and rates:
            implied = (tok_in / 1e6) * rates[0]
            v.add(
                WARN,
                "cost_is_zero_but_model_is_priced",
                f"Reported cost is 0 USD, but `{run.model}` IS priced at "
                f"{{{rates[0]}, {rates[1]}}} USD per 1M tokens. A zero here is "
                f"a DEFECT in cost accounting, not a free run.",
                detail=(
                    f"On input tokens alone this run implies at least "
                    f"${implied:,.2f}. The known cause is OSA-side: the agent "
                    f"loop's state carried `model: nil`, so `Pricing.cost/2` "
                    f"priced every turn at $0.00 and logged '[Pricing] No "
                    f"price for model nil' once per turn "
                    f"(bench/README.md §7.3). Two consequences beyond the "
                    f"report: `max_budget_usd` can never trip, and "
                    f"`provider_context_window/1` returns 0 so compaction "
                    f"thresholds never fire. NO cost figure from this run may "
                    f"be quoted in any direction -- not as a cost, and not as "
                    f"evidence the run was cheap. Note separately that the "
                    f"real billing relationship may still be a subscription, "
                    f"in which case the marginal dollar cost is genuinely "
                    f"zero; that is a question about the invoice, and it does "
                    f"not make the accounting correct."
                ),
            )
        elif status == "free":
            v.add(
                NOTE,
                "cost_is_zero_because_model_is_local",
                f"Reported cost is 0 USD and `{run.model}` is a locally "
                f"served model with no per-token price. Zero is correct here, "
                f"and it does not mean the run consumed no resources.",
                detail=(
                    "Compare tokens and wall-clock, which are measured, rather "
                    "than dollars, which for this provider do not exist."
                ),
            )
        else:
            v.add(
                NOTE,
                "cost_is_zero_and_model_pricing_unknown",
                f"Reported cost is 0 USD and `{run.model}` is not in the "
                f"reporter's price table, so a subscription/local model and a "
                f"broken accounting path cannot be told apart.",
                detail=(
                    "Add the model to honesty.KNOWN_MODEL_PRICING (mirroring "
                    "lib/optimal_system_agent/agent/pricing.ex) to resolve "
                    "this into a defect or a genuine zero. Until then, do not "
                    "present a 0 USD cost-per-resolved-task next to another "
                    "harness's metered API cost. Compare tokens."
                ),
            )
    cache_read = sum(i.tokens_cache_read or 0 for i in run.instances)
    if cache_read == 0 and (run.aggregate.get("tokens_in_total") or 0) > 0:
        v.add(
            NOTE,
            "no_prompt_cache_hits",
            "Zero cached-read tokens across the run; input-token totals are "
            "uncached and not comparable to a cache-enabled harness's figures.",
        )

    # -- 9b. multiple attempts: the headline count is pass@k ---------------
    if run.attempts > 1:
        p1 = run.aggregate.get("pass_at_1")
        v.add(
            BLOCK,
            "headline_is_pass_at_k_not_pass_at_1",
            f"This run made {run.attempts} attempts per instance, so the "
            f"resolved count ({k}/{n}) is pass@{run.attempts}, not pass@1.",
            detail=(
                "The official SWE-bench submission checklist defines pass@1 as "
                "'submits 1 prediction per task instance' and explicitly does "
                "not accept pass@k. Counting an instance as resolved because "
                "ANY attempt succeeded is the single largest source of "
                "inflation in self-reported figures. "
                + (
                    f"The comparable pass@1 estimate for this run is "
                    f"{p1*100:.1f}%. Quote that, or quote pass@"
                    f"{run.attempts} while saying so in the same breath."
                    if p1 is not None
                    else "No pass_at_1 was recorded to fall back on."
                )
            ),
        )
        ka = run.k_all
        if ka is not None:
            v.add(
                NOTE,
                "reliability_pass_hat_k",
                f"Resolved on every one of {run.attempts} attempts: "
                f"{ka}/{n}. That is the reliability figure, and it is the one "
                f"that matters for a harness people depend on.",
            )
    elif run.attempts == 1 and run.aggregate.get("pass_at_k") is not None:
        v.add(
            NOTE,
            "single_attempt_confirmed",
            "One attempt per instance; pass@1 and pass@k coincide.",
        )

    # -- 9c. did the patch filter eat real source files? -------------------
    dropped = run.dropped_source_paths
    if dropped:
        v.add(
            BLOCK,
            "source_files_stripped_from_graded_patch",
            f"{len(dropped)} instance(s) had non-test SOURCE files removed "
            f"from the graded patch by the test-path filter.",
            detail=(
                "runners._is_test_path() substring-matches 'test/', which is "
                "contained in 'src/_pytest/'. Those instances were graded on a "
                "patch with the agent's actual fix deleted, so their failures "
                "are the harness's, not the agent's. Affected: "
                + "; ".join(
                    f"{iid} ({', '.join(paths[:3])})"
                    for iid, paths in list(dropped.items())[:6]
                )
            ),
        )

    # -- 9d. web-lookup posture, stated explicitly either way ---------------
    #
    # The defect below fires whenever this is not "verified". This finding
    # exists so the report always says WHICH of the four states the run is in
    # and on what evidence, instead of leaving a reader to infer it from the
    # presence or absence of a block.
    ag_status, ag_reason = airgap_status(run)
    if ag_status == "verified":
        v.add(
            NOTE,
            "web_lookup_prevention_verified",
            "Web lookup of the published fix was prevented, and the "
            "prevention was probed rather than assumed.",
            detail=(
                ag_reason
                + ". Enforcement is a permissions deny list in the backend's "
                "OSA_SETTINGS (flag) layer, which Permissions.rules/0 reads "
                "and ToolExecutor consults BEFORE any permission-mode "
                "short-circuit, so overdrive does not bypass it. RESIDUAL "
                "SURFACE, stated because it is not zero: shell_execute stays "
                "available and the deny rules cover it only by command "
                "prefix, so an egress path built inside a Python one-liner is "
                "not prevented, only detected after the fact. A network "
                "namespace would close that; it is unavailable on this host "
                "(apparmor_restrict_unprivileged_userns=1, bwrap not setuid) "
                "and both attempts were executed and failed."
            ),
        )
        refused = run.network_tool_use.get("refused_by_tool") or {}
        if refused:
            tried = sorted(run.network_tool_use.get("instances_that_used_one") or [])
            v.add(
                NOTE,
                "web_lookup_attempted_and_refused",
                f"The agent tried to use a denied network tool "
                f"{sum(refused.values())} time(s) — {refused} — across "
                f"{len(tried)} instance(s), and was refused every time.",
                detail=(
                    "This is the airgap doing its job, and it is also a "
                    "finding about the agent: reaching for a web lookup on "
                    f"{len(tried)}/{run.n} instances is how much of the "
                    "earlier, unairgapped number was resting on retrieval "
                    "rather than reasoning. Instances: " + ", ".join(tried)
                ),
            )
    elif ag_status == "unverified":
        v.add(
            BLOCK,
            "airgap_requested_but_not_verified",
            "This run asked for an airgap and did not prove it worked.",
            detail=(
                ag_reason
                + ". A control that is believed rather than measured is worse "
                "than no control: the previous workspace-local deny hook "
                "looked correct, was shipped, and did nothing. Run "
                "bench/swebench/airgap.py's probe against the backend and "
                "record the attestation, or run without the flag and take the "
                "unmitigated block."
            ),
        )
    elif ag_status == "breached":
        v.add(
            BLOCK,
            "airgap_verified_but_breached",
            "The airgap probe passed and network access happened anyway.",
            detail=ag_reason
            + ". Either enforcement regressed during the run or the harness is "
            "mis-recording. Do not quote anything from this run until which "
            "one is established.",
        )

    # -- 10. is this even one measurement? ---------------------------------
    if run.model.startswith("MIXED:"):
        v.add(
            BLOCK,
            "model_changed_mid_run",
            f"Instances in this run used different models ({run.model[6:]}). "
            f"This is not a single measurement.",
        )

    # -- 11. timestamps that do not add up ---------------------------------
    started, finished = run.config.get("started_at"), run.config.get("finished_at")
    if started and finished:
        from datetime import datetime

        try:
            elapsed = (
                datetime.fromisoformat(finished) - datetime.fromisoformat(started)
            ).total_seconds()
            recorded = run.aggregate.get("wall_clock_total_s") or 0.0
            if recorded > elapsed * 1.5 and elapsed > 0:
                v.add(
                    WARN,
                    "config_timestamps_inconsistent_with_work",
                    f"config.json spans {elapsed:.0f}s but {recorded:.0f}s of "
                    f"agent wall-clock is recorded.",
                    detail=(
                        "Almost certainly a --reuse-inference re-grade: "
                        "run_bench.py rewrites started_at on every invocation, "
                        "so the timestamps describe the grading pass, not the "
                        "inference that produced these numbers. The telemetry "
                        "is from an earlier, undated run."
                    ),
                )
        except (ValueError, TypeError):
            pass

    # -- 12. defects we already know about ---------------------------------
    for d in _applicable_defects(run):
        v.add(
            d.severity,
            f"defect:{d.code}",
            f"[{d.direction}] {d.message}",
            detail=d.detail,
        )

    # -- 13. the standing rule --------------------------------------------
    v.add(
        NOTE,
        "cross_harness_comparison_unsupported",
        "This number may not be placed beside another harness's published "
        "SWE-bench figure as a comparison. See bench/report/METHODOLOGY.md.",
    )
    return v


def claim_label(run: "Run", verdict: Verdict) -> str:
    """The only phrase that may be used to describe this run."""
    if verdict.blocks:
        if run.is_full_dataset:
            return "INVALID RUN — not quotable"
        return f"pipeline probe over {run.n} instances — NOT a benchmark score"
    if not run.is_full_dataset:
        return f"subset estimate over {run.n} of {run.dataset_size} instances"
    return f"{run.dataset} pass@1, all {run.n} instances"


def _strip_list_derived_from_test_patch(run) -> bool:
    """Whether this run's harness derived its strip list from `test_patch`.

    Recorded per run rather than read from the working tree: a report over a
    run from last week must reflect the harness THAT RUN used, not whatever is
    checked out now. Absent the marker we assume the old behaviour, because a
    missing field means an old run — never the reverse.
    """
    config = getattr(run, "config", None) or {}
    harness = config.get("harness") or {}
    return bool(harness.get("strip_list_from_test_patch"))
