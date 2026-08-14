"""The fixed cost probe: the SAME tasks every time, so cost is paired.

WHAT THIS IS FOR
----------------
OSA currently burns 3-8M input tokens per Terminal-Bench task at a ~140:1
input:output ratio, where the competitive field sits at 0.7-1.3M and 56-85:1.
Until that is fixed we cannot afford to re-run a whole benchmark after every
optimisation attempt. So we need a cheap standing instrument that answers one
question: **did this change reduce token burn, and by how much.**

The only way that question has an answer is if the task list NEVER MOVES.
A cost comparison over a different set of tasks is not a comparison at all —
task cost on this benchmark spans two orders of magnitude (0.6M to 15.5M input
tokens on measured OSA runs), so re-sampling the set can manufacture or erase a
2x "improvement" without touching the harness. Hence: the list lives in this
file, it is versioned, and `probeset.py check` fails if a run's task set does
not match it exactly.

WHAT IT IS NOT
--------------
Not a pass-rate measurement. Eight tasks cannot estimate a rate, and this set is
deliberately *not* representative — it is stratified to include the expensive
tail, because that is where the token problem lives. `report.py` refuses to call
it a full-dataset run and the summary carries the warning.

REPORTED COLUMNS
----------------
`input_tokens/task`, `in:out ratio`, `cache_hit_rate`, `$/task` — the same four
columns the field publishes (goose's Harbor README table; every Harbor installed
adapter parses `cache_read`/`cache_write` and Harbor's `AgentContext` has a
first-class `n_cache_tokens`). Computed in `report.py:build`.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent


@dataclass(frozen=True)
class ProbeSet:
    name: str
    dataset_key: str
    tasks: tuple[str, ...]
    #: Why each task is in the set. One entry per task, same order — a set
    #: whose membership cannot be justified per-item is a set that will drift.
    rationale: dict[str, str] = field(default_factory=dict)
    #: Measured OSA figures for this exact list, if we have them. The point of
    #: recording them here is that the FIRST re-run has something to be paired
    #: against instead of starting a new series.
    baseline: dict | None = None
    notes: tuple[str, ...] = ()


#: Baseline is the union of the `osa-hard6` and `osa-hard-long4` runs in
#: `runs/`, which between them cover all eight tasks. Those were separate jobs
#: on the Terminal-Bench **2.0** copies of the tasks — recorded as such, because
#: none of the eight is in `datasets.DIFF_TB20_TB21` (checked; that is one of
#: the selection criteria) so the 2.0 figures are a legitimate baseline for the
#: 2.1 run. If any of these tasks is ever modified upstream, the baseline is
#: void and must be re-measured, not adjusted.
_TB_BASELINE = {
    "source_runs": ["osa-hard6", "osa-hard-long4"],
    "measured_on": "terminal-bench 2.0 task content",
    "n_tasks": 8,
    # WAS RECORDED AS 4. It is 5, and it always was: re-deriving the union of
    # the two source runs from disk gives cancel-async-tasks,
    # feal-differential-cryptanalysis, fix-code-vulnerability,
    # password-recovery and path-tracing passing. The independently-run
    # `baseline-recheck-*` pair on 2.1 content solves the SAME five. A baseline
    # solve count that is one low makes every later run look like it gained a
    # task it did not gain, which is the direction of error that flatters us.
    "resolved": 5,
    "resolved_tasks": [
        "cancel-async-tasks",
        "feal-differential-cryptanalysis",
        "fix-code-vulnerability",
        "password-recovery",
        "path-tracing",
    ],
    # Re-derived from the trial files rather than copied forward: the totals
    # recorded here were 36_977_510 / 4_622_188.8, which is 4,960 tokens short
    # of what the eight trials actually sum to.
    "input_tokens_total": 36_982_470,
    "output_tokens_total": 250_806,
    "input_tokens_per_task": 4_622_808.8,
    "in_out_ratio": 147.5,
    "cache_hit_rate": None,  # OSA reported no cache counter at all
    "cost_usd_per_task": None,  # local Ollama; no price attached
    "wall_clock_total_s": 4988.5,
    "per_task_input_tokens": {
        "feal-differential-cryptanalysis": 626_876,
        "cancel-async-tasks": 801_522,
        "sparql-university": 1_111_957,
        "fix-code-vulnerability": 1_225_866,
        "password-recovery": 1_440_110,
        "dna-assembly": 2_453_241,
        "make-mips-interpreter": 13_772_310,
        "path-tracing": 15_550_588,
    },
}

#: The arms of the workspace-denial comparison, all eight tasks, all priced at
#: the SAME rates ($0.60/M in, $2.20/M out for glm-5.2:cloud — `bench/report/
#: honesty.py:MODEL_RATES`). The dollars in `_TB_BASELINE` above are `None`
#: because those runs attached no price; these are re-priced from token counts,
#: which is the only way a $ figure survives the 2026-08-14 pricing fix that
#: removed a 2.487x overstatement. Do not mix a stored `cost_usd` from a
#: pre-fix run into this table.
#:
#: Arm 1 and arm 2 differ ONLY in the OSA build. Arm 2 and arm 3 differ only in
#: whether `3fe329e4` (the session workspace was not an allowed path anywhere)
#: is in the artefact.
_TB_ARMS = {
    "pre_fix": {
        "run": ["baseline-recheck-hard6", "baseline-recheck-long4"],
        "note": "pre-workspace-fix build; 2.1 task content",
        "resolved": 5,
        "input_tokens_per_task": 4_654_997.4,
        "in_out_ratio": 146.7,
        "cost_usd_per_task": 2.8628,
    },
    "post_fix_containers_broken": {
        "run": ["probe-postfix-20260814"],
        "note": (
            "pricing/telemetry fixes in, workspace fix NOT in: 22 path denials "
            "still observed across all 8 tasks"
        ),
        "resolved": 5,
        "input_tokens_per_task": 2_821_177.0,
        "in_out_ratio": 162.3,
        "cost_usd_per_task": 1.7310,
    },
    # ---- the verification-adequacy ablation, 2026-08-15 -------------------
    #
    # These two arms are the SAME artefact (sha256 8cb0e2b3...), the same
    # pinned commit (a18732dd), the same eight tasks and the same
    # `-n 2` schedule. They differ in ONE runtime flag,
    # `OSA_VERIFICATION_ADEQUACY`, which disables clause 3 of
    # `Agent.Loop.VerificationGate` (adequacy) and nothing else. Nothing was
    # rebuilt between them -- rebuilding from a pre-gate commit would have
    # moved the workspace fix, the doom-loop work and the tool-perf changes at
    # the same time, which is how the earlier attempt to price this failed.
    #
    # Arrival was proved, not assumed: every trial's driver log carries
    # `[ablation] OSA_VERIFICATION_ADEQUACY=0 (-> osagent serve)`, the `off`
    # arm logged ZERO `inadequate_test` gate firings against nine in the `on`
    # arm, and clause 2 (`unchecked_write`, deliberately NOT covered by the
    # flag) still fired in the `off` arm -- so the gate was live and only the
    # one clause was disabled.
    "adequacy_on": {
        "run": ["probe-workspacefix-a18732dd"],
        "note": "the same run as `containers_fixed`, relabelled as the ON arm",
        "resolved": 6,
        "input_tokens_per_task": 5_814_330.0,
        "in_out_ratio": 195.4,
        "cost_usd_per_task": 3.5541,
    },
    "adequacy_off": {
        "run": ["probe-adequacy-off-a18732dd"],
        "note": (
            "OSA_VERIFICATION_ADEQUACY=0. -6.4% input tokens over all eight "
            "tasks but -22.7% over the six that finished inside their agent "
            "timeout and -31.3% over the four short tasks where the clause "
            "actually fired: the gate's cost is real and concentrated in the "
            "cheap tail, which is ~14% of the bill. The 6/8 -> 5/8 is "
            "make-mips-interpreter dying to AgentTimeoutError at 1838s "
            "against an 1800s ceiling it cleared by 29s in the ON arm -- a "
            "clock race, not a lost solve; both arms failed exactly the same "
            "two tasks on the model."
        ),
        "resolved": 5,
        "input_tokens_per_task": 5_441_540.0,
        "in_out_ratio": 169.1,
        "cost_usd_per_task": 3.3357,
    },
}

_TB_TASKS = (
    "feal-differential-cryptanalysis",
    "cancel-async-tasks",
    "sparql-university",
    "fix-code-vulnerability",
    "password-recovery",
    "dna-assembly",
    "make-mips-interpreter",
    "path-tracing",
)

_TB_RATIONALE = {
    "feal-differential-cryptanalysis": (
        "Cheapest measured task with a baseline (0.63M in). Anchors the low "
        "end so a change that only helps long tasks is visible as such."
    ),
    "cancel-async-tasks": (
        "Async-debugging; short (31 turns). Different failure surface from "
        "everything else here."
    ),
    "sparql-university": (
        "Data/semantic-web query. Included BECAUSE OSA FAILS IT — a probe set "
        "of only-passing tasks measures the cheap path and hides the cost of "
        "flailing, which is where the token burn actually is."
    ),
    "fix-code-vulnerability": "Security fix; mid-cost (1.23M), passing.",
    "password-recovery": "Forensics/cracking; mid-cost (1.44M), passing.",
    "dna-assembly": "Bioinformatics; 2.45M, failing. Second failure case.",
    "make-mips-interpreter": (
        "LONG/EXPENSIVE, failing: 13.8M input, 154 turns, 28 min. Half the "
        "reason this set exists. A cost change that does not move this task "
        "has not moved our bill."
    ),
    "path-tracing": (
        "LONG/EXPENSIVE, passing: 15.6M input, 175 turns, 30 min. The "
        "passing counterpart to make-mips-interpreter, so 'got cheaper' can "
        "be told apart from 'gave up sooner'."
    ),
}

#: Harbor-Index probe. Chosen for SOURCE-BENCHMARK diversity (the whole point of
#: Harbor-Index is that its 80 tasks come from many benchmarks) and to avoid the
#: LLM-judged families, which cannot be graded without an Anthropic key.
#: NO BASELINE: OSA has never run this dataset. The first run establishes one.
_HI_TASKS = (
    "gso-speedup-pandas-merge",
    "swebenchverified-fix-django-union-queryset-order",
    "swebenchpro-fix-teleport-mtls-ca-limit",
    "featurebench-add-feature-xarray-backend-chunks",
    "scicode-gaussian-beam-through-lens",
    "spider2-dbt-airport-arrivals",
    "usaco-assign-cows-to-barns",
    "tb-make-doom-for-mips",
)

_HI_RATIONALE = {
    "gso-speedup-pandas-merge": "GSO — software optimisation, measured by speedup.",
    "swebenchverified-fix-django-union-queryset-order": "SWE-bench Verified issue fix.",
    "swebenchpro-fix-teleport-mtls-ca-limit": "SWE-bench Pro — harder issue fix.",
    "featurebench-add-feature-xarray-backend-chunks": "FeatureBench — feature addition, not repair.",
    "scicode-gaussian-beam-through-lens": "SciCode — scientific implementation.",
    "spider2-dbt-airport-arrivals": "Spider2-dbt — data analytics/SQL.",
    "usaco-assign-cows-to-barns": "USACO — pure algorithms, cheap, anchors the low end.",
    "tb-make-doom-for-mips": (
        "The LONG/EXPENSIVE member: a Terminal-Bench task, and the one whose "
        "2.x sibling cost OSA 13.8M input tokens."
    ),
}


PROBE_SETS: dict[str, ProbeSet] = {
    "tb2.1": ProbeSet(
        name="tb-cost-probe-v1",
        dataset_key="tb2.1",
        tasks=_TB_TASKS,
        rationale=_TB_RATIONALE,
        baseline=_TB_BASELINE,
        notes=(
            "Stratified, NOT representative: two tasks (make-mips-interpreter, "
            "path-tracing) are 79% of the baseline input tokens. That is "
            "deliberate — the bill is concentrated there — but it means the "
            "set-level mean is dominated by two tasks and the PER-TASK table "
            "must be read alongside it.",
            "4 of 8 pass and 4 fail on the baseline. Keep it that way: if an "
            "optimisation flips a task to passing the token figures stop being "
            "paired for that task, and that has to be called out rather than "
            "absorbed into the mean.",
            "None of the eight is in datasets.DIFF_TB20_TB21, so the identical "
            "list can be run on tb2.0 and tb2.1 and the difference attributed "
            "to the harness rather than to changed tasks.",
        ),
    ),
    # The same eight tasks, on the superseded content, for a version-paired
    # comparison. Same name so `check` treats them as one series.
    "tb2.0": ProbeSet(
        name="tb-cost-probe-v1",
        dataset_key="tb2.0",
        tasks=_TB_TASKS,
        rationale=_TB_RATIONALE,
        baseline=_TB_BASELINE,
        notes=("Superseded task content. Only for the 2.0-vs-2.1 delta.",),
    ),
    "harbor-index": ProbeSet(
        name="harbor-index-cost-probe-v1",
        dataset_key="harbor-index",
        tasks=_HI_TASKS,
        rationale=_HI_RATIONALE,
        baseline=None,
        notes=(
            "NO BASELINE YET. The first run of this set establishes one; until "
            "then it reports absolute figures with nothing to be paired "
            "against, and no claim of improvement can be made from it.",
            "Avoids the hle-/omnimath-/gaia2-/widesearch- families, which are "
            "LLM-judge graded and ungradeable without an Anthropic key.",
        ),
    ),
}


def get(dataset_key: str) -> ProbeSet:
    if dataset_key not in PROBE_SETS:
        raise SystemExit(
            f"no fixed probe set is defined for dataset '{dataset_key}'. "
            f"Defined for: {', '.join(sorted(PROBE_SETS))}.\n"
            "A probe set is a COMMITMENT to a task list; it is not something "
            "to invent at the command line. Add one to probeset.py, with a "
            "per-task rationale, if this dataset needs one."
        )
    return PROBE_SETS[dataset_key]


def check_run(results_path: Path) -> tuple[bool, str]:
    """Did this run actually cover the probe set, exactly?"""
    doc = json.loads(results_path.read_text())
    cfg = doc.get("config") or {}
    key = cfg.get("dataset_key")
    if key not in PROBE_SETS:
        return False, f"run's dataset '{key}' has no probe set"
    ps = PROBE_SETS[key]
    got = {t["task_name"].split("/")[-1] for t in doc.get("tasks") or []}
    want = set(ps.tasks)
    if got == want:
        return True, f"matches {ps.name} ({len(want)} tasks)"
    return False, (
        f"task set does not match {ps.name}: "
        f"missing={sorted(want - got)} extra={sorted(got - want)}"
    )


_COLS = (
    ("input_tokens_per_task", "input tok/task", "{:,.0f}"),
    ("output_tokens_per_task", "output tok/task", "{:,.0f}"),
    ("in_out_ratio", "in:out", "{:.1f}:1"),
    ("cache_hit_rate", "cache hit", "{:.1%}"),
    ("cost_usd_per_task", "$/task", "${:.4f}"),
    ("wall_clock_mean_s", "wall s/task", "{:.0f}"),
    ("tasks_resolved", "solved", "{:.0f}"),
)


def _fmt(v, spec):
    return "n/a" if v is None else spec.format(v)


def compare(a_path: Path, b_path: Path) -> str:
    """Two probe runs, paired. A is the older/baseline, B the new one."""
    a = json.loads(a_path.read_text())
    b = json.loads(b_path.read_text())
    aa, ba = a["aggregate"], b["aggregate"]

    a_ids = {t["task_name"].split("/")[-1] for t in a["tasks"]}
    b_ids = {t["task_name"].split("/")[-1] for t in b["tasks"]}

    out = [
        f"# Cost probe — `{a['config']['run_id']}` -> `{b['config']['run_id']}`",
        "",
    ]
    if a_ids != b_ids:
        out += [
            "> ⚠ **The two runs did not cover the same tasks** "
            f"(only in A: {sorted(a_ids - b_ids)}; only in B: "
            f"{sorted(b_ids - a_ids)}). The figures below are NOT paired and "
            "any difference mixes a change in the harness with a change in "
            "the task mix. Re-run.",
            "",
        ]
    out += ["| metric | before | after | change |", "|---|---|---|---|"]
    for key, label, spec in _COLS:
        x, y = aa.get(key), ba.get(key)
        if x is None or y is None or not x:
            delta = "n/a"
        else:
            delta = f"{(y - x) / x * 100:+.1f}%"
        out.append(f"| {label} | {_fmt(x, spec)} | {_fmt(y, spec)} | {delta} |")

    out += ["", "## Per task (input tokens)", "",
            "| task | before | after | change | before/after verdict |",
            "|---|---|---|---|---|"]
    a_by = {t["task_name"].split("/")[-1]: t for t in a["tasks"]}
    b_by = {t["task_name"].split("/")[-1]: t for t in b["tasks"]}
    for name in sorted(a_ids & b_ids):
        ta, tb = a_by[name], b_by[name]
        x, y = ta.get("tokens_in"), tb.get("tokens_in")
        d = f"{(y - x) / x * 100:+.1f}%" if x and y else "n/a"
        verdict = (
            f"{'pass' if ta['resolved'] else 'fail'} -> "
            f"{'pass' if tb['resolved'] else 'fail'}"
        )
        flag = "" if ta["resolved"] == tb["resolved"] else "  **unpaired**"
        out.append(
            f"| `{name}` | {_fmt(x, '{:,.0f}')} | {_fmt(y, '{:,.0f}')} | {d} "
            f"| {verdict}{flag} |"
        )
    out += [
        "",
        "A task whose verdict changed is **not** a paired cost observation: "
        "solving a task and giving up on it cost different amounts for reasons "
        "that have nothing to do with the optimisation under test.",
        "",
    ]
    return "\n".join(out)


def _union_over_probe(run_dirs: list[Path], tasks: tuple[str, ...]) -> dict:
    """Fold one or more runs into a single arm over exactly the probe tasks.

    Several arms were run as two jobs (a `hard6` and a `long4`), so an arm is
    the UNION of its source runs restricted to the probe list. Anything outside
    the list is dropped; a task present in two source runs takes the later one.
    """
    rows: dict[str, dict] = {}
    for d in run_dirs:
        p = Path(d)
        p = p if p.is_file() else p / "results.json"
        for t in json.loads(p.read_text())["tasks"]:
            name = t["task_name"].split("/")[-1]
            if name in tasks:
                rows[name] = t
    return rows


#: $/M input, $/M output. Kept here as well as in `bench/report/honesty.py` so
#: a re-price is explicit at the point of comparison rather than inherited.
GLM_RATES = (0.60, 2.20)


def _price(tok_in: float, tok_out: float, rates=GLM_RATES) -> float:
    return tok_in * rates[0] / 1e6 + tok_out * rates[1] / 1e6


def arm_stats(rows: dict[str, dict]) -> dict:
    """The four published columns for one arm, priced from tokens.

    `input` is uncached + cache reads + cache writes — every token sent in, the
    same definition `report.build` and `bench/report/loader.py` use. `$` is
    RE-DERIVED from those token counts at `GLM_RATES` and never read from the
    run's stored `cost_usd`, because runs on either side of the 2026-08-14
    pricing fix stored dollars computed at rates up to 3x apart and averaging
    those together is how a pricing bug becomes a published cost trend.
    """
    n = len(rows) or 1
    tin = tout = 0
    cread = cwrite = 0
    have_cache = False
    resolved = []
    for name, t in rows.items():
        r, w = t.get("tokens_cache_read"), t.get("tokens_cache_write")
        if r is not None or w is not None:
            have_cache = True
        cread += r or 0
        cwrite += w or 0
        tin += (t.get("tokens_in") or 0) + (r or 0) + (w or 0)
        tout += t.get("tokens_out") or 0
        if t["resolved"]:
            resolved.append(name)
    return {
        "n": len(rows),
        "resolved": len(resolved),
        "resolved_tasks": sorted(resolved),
        "input_tokens_per_task": round(tin / n, 1),
        "output_tokens_per_task": round(tout / n, 1),
        "in_out_ratio": round(tin / tout, 1) if tout else None,
        # `None` and 0.0 are different claims. Ollama's OpenAI-shaped response
        # carries no cache counter at all on some builds (absence) and a literal
        # zero on others (measured, and correctly zero: there is no cache to
        # hit). Whichever it is, it is not a regression.
        "cache_hit_rate": (round(cread / tin, 4) if have_cache and tin else None),
        "cost_usd_per_task": round(_price(tin, tout) / n, 4),
        "cost_basis": f"re-priced at ${GLM_RATES[0]}/M in, ${GLM_RATES[1]}/M out",
    }


def arms_table(arm_paths: dict[str, list[Path]], dataset_key: str = "tb2.1") -> str:
    """The paired multi-arm table, every arm priced identically."""
    ps = get(dataset_key)
    stats = {
        label: arm_stats(_union_over_probe(paths, ps.tasks))
        for label, paths in arm_paths.items()
    }
    out = [
        f"# `{ps.name}` — {len(stats)} arms, {len(ps.tasks)} fixed tasks",
        "",
        f"All arms priced at the SAME rates ({GLM_RATES[0]}/M in, "
        f"{GLM_RATES[1]}/M out), re-derived from token counts. Stored "
        "`cost_usd` is ignored: it straddles the 2026-08-14 pricing fix.",
        "",
        "| arm | n | solved | input tok/task | in:out | cache hit | $/task |",
        "|---|---|---|---|---|---|---|",
    ]
    for label, s in stats.items():
        hit = "n/a" if s["cache_hit_rate"] is None else f"{s['cache_hit_rate']:.1%}"
        out.append(
            f"| {label} | {s['n']} | {s['resolved']}/{s['n']} "
            f"| {s['input_tokens_per_task']:,.0f} | {s['in_out_ratio']}:1 "
            f"| {hit} | ${s['cost_usd_per_task']:.4f} |"
        )
    labels = list(stats)
    if len(labels) >= 2:
        a, b = stats[labels[0]], stats[labels[-1]]
        d = (b["input_tokens_per_task"] - a["input_tokens_per_task"]) / a[
            "input_tokens_per_task"
        ]
        out += [
            "",
            f"`{labels[0]}` -> `{labels[-1]}`: input tokens/task {d:+.1%}, "
            f"solved {a['resolved']}/{a['n']} -> {b['resolved']}/{b['n']}.",
        ]
        if b["resolved"] < a["resolved"]:
            out += [
                "",
                "> ⚠ **SOLVE RATE DROPPED.** Fewer tokens with fewer solves is "
                "not a cost win; the arms are no longer paired on the tasks "
                "that changed verdict.",
            ]
    return "\n".join(out)


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("show", help="print a probe set and why each task is in it")
    p.add_argument("dataset_key", nargs="?", default="tb2.1")
    p = sub.add_parser("check", help="does a run cover its probe set exactly")
    p.add_argument("run")
    p = sub.add_parser("compare", help="two probe runs, paired")
    p.add_argument("run_a")
    p.add_argument("run_b")
    p = sub.add_parser(
        "arms", help="N arms, all priced at the same rates. label=run[,run] ..."
    )
    p.add_argument("arm", nargs="+", metavar="LABEL=RUN[,RUN]")
    p.add_argument("--dataset-key", default="tb2.1")

    args = ap.parse_args(argv)

    def results(p: str) -> Path:
        q = Path(p)
        return q if q.is_file() else q / "results.json"

    if args.cmd == "show":
        ps = get(args.dataset_key)
        print(f"{ps.name}  (dataset {ps.dataset_key}, {len(ps.tasks)} tasks)\n")
        for t in ps.tasks:
            print(f"  {t}\n      {ps.rationale.get(t, '(no rationale recorded)')}")
        if ps.notes:
            print("\nNotes:")
            for n in ps.notes:
                print(f"  - {n}")
        if ps.baseline:
            print("\nBaseline:")
            print(json.dumps(ps.baseline, indent=2))
        else:
            print("\nBaseline: NONE — the first run establishes it.")
        return 0

    if args.cmd == "check":
        ok, msg = check_run(results(args.run))
        print(("OK: " if ok else "MISMATCH: ") + msg)
        return 0 if ok else 1

    if args.cmd == "compare":
        print(compare(results(args.run_a), results(args.run_b)))
        return 0

    if args.cmd == "arms":
        arms: dict[str, list[Path]] = {}
        for spec in args.arm:
            if "=" not in spec:
                raise SystemExit(f"expected LABEL=RUN[,RUN], got {spec!r}")
            label, runs = spec.split("=", 1)
            arms[label] = [results(r) for r in runs.split(",")]
        print(arms_table(arms, args.dataset_key))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
