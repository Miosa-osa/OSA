"""Turn a run into the document we are willing to show someone.

Ordering is an argument. The validity gate comes before the number, and the
failure distribution comes before the cost table, because that is the order in
which the information matters when a benchmark is being used to decide what to
fix rather than what to boast about.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import failures as fail_mod
import honesty
from stats import interval, min_n_for_halfwidth

if TYPE_CHECKING:
    from loader import Run

_SEV_MARK = {honesty.BLOCK: "BLOCK", honesty.WARN: "WARN ", honesty.NOTE: "note "}


def _na(v, suffix="", fmt="{}"):
    return "n/a" if v is None else fmt.format(v) + suffix


def _table(headers: list[str], rows: list[list[str]]) -> list[str]:
    if not rows:
        return ["_none_", ""]
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return out + [""]


def render(
    run: "Run",
    *,
    verdict: honesty.Verdict,
    analysis: "fail_mod.FailureAnalysis",
    controls: dict[str, "Run"] | None = None,
    confidence: float = 0.95,
    method: str = "wilson",
    max_failures_listed: int = 60,
) -> str:
    controls = controls or {}
    ci = interval(run.k, run.n, confidence, method)
    label = honesty.claim_label(run, verdict)
    L: list[str] = []

    L += [
        f"# Benchmark report — `{run.run_id}`",
        "",
        f"**What this is:** {label}",
        "",
    ]

    # ---- 1. the gate, before the number ---------------------------------
    if verdict.blocks:
        L += [
            "## ⛔ This run may not be quoted as a score",
            "",
            "The following are disqualifying. The resolved *count* below is "
            "real; the *rate* is not a benchmark result, and this document "
            "deliberately does not present one as a headline.",
            "",
        ]
        for f in verdict.blocks:
            L += [f"- **{f.code}** — {f.message}"]
            if f.detail:
                L += [f"  <br/>{f.detail}"]
        L += [""]

    # ---- 2. the number, in the only form it is allowed to take ----------
    L += ["## Result", ""]
    if verdict.may_quote_headline_rate:
        L += [
            f"**{run.k} / {run.n} resolved — {ci.pct()}**",
            "",
            f"{int(confidence*100)}% confidence interval: **{ci.pct_range()}** "
            f"({ci.width_pp:.1f} pp wide, {ci.method}).",
            "",
        ]
    else:
        L += [
            f"**{run.k} of {run.n} instances resolved.**",
            "",
            f"A percentage is withheld on purpose. For the record the interval "
            f"is {ci.pct_range()} at {int(confidence*100)}% confidence — "
            f"{ci.width_pp:.0f} percentage points wide, which is why quoting "
            f"the midpoint would be misleading rather than merely imprecise.",
            "",
        ]
    if run.infra_failures:
        alt = interval(run.k, run.n_scorable, confidence, method)
        L += [
            f"Excluding the {len(run.infra_failures)} instance(s) lost to "
            f"harness or infrastructure faults: {run.k}/{run.n_scorable} "
            f"(CI {alt.pct_range()}). Both denominators are shown because "
            f"choosing one is an editorial act.",
            "",
        ]
    if not run.is_full_dataset:
        need = min_n_for_halfwidth(5.0)
        L += [
            f"> Measured on {run.n} of {run.dataset_size} instances in "
            f"`{run.dataset}`. A ±5 pp estimate needs roughly {need} tasks.",
            "",
        ]

    # ---- 3. failures first ----------------------------------------------
    L += ["## Failure distribution", ""]
    if not analysis.failures:
        L += ["_Every attempted instance resolved._", ""]
    else:
        L += ["**By who can fix it**", ""]
        L += _table(
            ["attribution", "count", "share of all attempts"],
            [
                [a, str(c), f"{c/run.n*100:.0f}%"]
                for a, c in analysis.by_attribution.items()
            ],
        )
        actionable = sum(
            c for a, c in analysis.by_attribution.items() if a in fail_mod.ACTIONABLE
        )
        L += [
            f"**{actionable} of {len(analysis.failures)} failures are "
            f"attributable to OSA or to this harness** rather than to raw "
            f"model capability. Those are the ones worth reading.",
            "",
            "**By cause**",
            "",
        ]
        L += _table(
            ["bucket", "count", "attribution", "what it usually means"],
            [
                [
                    f"`{code}`",
                    str(c),
                    analysis.bucket(code).attribution,
                    analysis.bucket(code).label,
                ]
                for code, c in analysis.by_bucket.items()
            ],
        )
        if len(analysis.by_repo) > 1:
            L += ["**By repository**", ""]
            L += _table(
                ["repo", "failures"],
                [[r, str(c)] for r, c in list(analysis.by_repo.items())[:15]],
            )

    # ---- 4. leads --------------------------------------------------------
    if analysis.leads:
        L += ["## What to look at first", ""]
        L += [f"{i}. {lead}" for i, lead in enumerate(analysis.leads, 1)]
        L += [""]

    # ---- 5. every failure, with a path to its transcript -----------------
    if analysis.failures:
        L += [
            "## Failures in detail",
            "",
            "Each row points at the artefacts needed to diagnose it. A failure "
            "bucket without a transcript is a statistic; with one it is a bug "
            "report.",
            "",
        ]
        if analysis.transcripts_missing:
            L += [
                f"> ⚠ {analysis.transcripts_missing} of "
                f"{len(analysis.failures)} failures have no recoverable "
                f"transcript. Note that `osa_runner.clear_session_files()` "
                f"deletes `~/.osa/sessions/<session_id>.*` at the start of "
                f"every attempt, so re-running the same `--run-id` destroys "
                f"the evidence from the previous run. Use a fresh run id when "
                f"the transcripts matter.",
                "",
            ]
        rows = []
        for f in analysis.failures[:max_failures_listed]:
            i = f.instance
            ev = f.evidence
            rows.append(
                [
                    f"`{i.instance_id}`",
                    f"`{f.bucket.code}`",
                    f"{i.wall_clock_s:.0f}s",
                    _na(i.turns),
                    _na(i.tool_calls),
                    f"`{ev.transcript}`" if ev.transcript else "—",
                ]
            )
        L += _table(
            ["instance", "bucket", "wall", "turns", "tools", "transcript"], rows
        )
        if len(analysis.failures) > max_failures_listed:
            L += [
                f"_{len(analysis.failures) - max_failures_listed} further "
                f"failures omitted; see the JSON output for all of them._",
                "",
            ]
        L += ["<details><summary>Per-failure diagnosis</summary>", ""]
        for f in analysis.failures[:max_failures_listed]:
            L += [
                f"**`{f.instance.instance_id}`** — {f.bucket.label} "
                f"({f.bucket.attribution})",
                "",
                f"- {f.summary}",
                f"- diagnosis: {f.bucket.diagnosis}",
            ]
            ev = f.evidence
            for name in ("transcript", "updates", "goal", "eval_log_dir"):
                p = getattr(ev, name)
                if p:
                    L += [f"- {name}: `{p}`"]
            if f.instance.pass_to_pass_failing:
                L += [
                    "- broke: "
                    + ", ".join(f"`{t}`" for t in f.instance.pass_to_pass_failing[:6])
                ]
            L += [""]
        L += ["</details>", ""]

    # ---- 6. controls -----------------------------------------------------
    L += ["## Pipeline controls", ""]
    rows = []
    for name, expected in (("gold", "100%"), ("empty", "0%")):
        c = controls.get(name)
        if c is None:
            rows.append([name, "— not run —", expected, "UNVALIDATED"])
        else:
            ok = (c.k == c.n) if name == "gold" else (c.k == 0)
            rows.append(
                [
                    f"`{c.run_id}`",
                    f"{c.k}/{c.n}",
                    expected,
                    "pass" if ok else "**FAIL**",
                ]
            )
    L += _table(["control", "observed", "expected", "verdict"], rows)
    L += [
        "The gold control proves the grader accepts a correct patch; the empty "
        "control proves it rejects no patch. Note that the gold runner returns "
        "the dataset patch directly and never exercises workspace preparation "
        "or `git_diff()`, so a passing gold control does **not** validate patch "
        "extraction.",
        "",
    ]

    # ---- 7. cost ---------------------------------------------------------
    a = run.aggregate
    L += ["## What the result cost", ""]
    L += _table(
        ["metric", "value"],
        [
            ["wall-clock total", _na(a.get("wall_clock_total_s"), " s")],
            ["wall-clock mean / task", _na(a.get("wall_clock_mean_s"), " s")],
            ["tokens in", _na(a.get("tokens_in_total"))],
            ["tokens out", _na(a.get("tokens_out_total"))],
            ["tokens / resolved task", _na(a.get("tokens_per_resolved"))],
            ["cached-read tokens", str(sum(i.tokens_cache_read or 0 for i in run.instances))],
            ["cost total", _na(a.get("cost_usd_total"), " USD")],
            ["cost / resolved task", _na(a.get("cost_usd_per_resolved"), " USD")],
            ["tool calls mean / task", _na(a.get("tool_calls_mean"))],
            ["turns mean / task", _na(a.get("turns_mean"))],
        ],
    )

    # ---- 8. config fingerprint ------------------------------------------
    c = run.config
    L += ["## Configuration fingerprint", ""]
    L += _table(
        ["field", "value"],
        [
            ["dataset", f"`{c.get('dataset_name')}` split `{c.get('split')}`"],
            ["runner / transport", f"{c.get('runner')} / {c.get('transport')}"],
            ["model", f"`{run.model}`"],
            ["attempts per instance", "1 (no reranking, no test-time compute)"],
            ["max turns", str(c.get("max_turns"))],
            ["agent timeout", f"{c.get('agent_timeout_s')} s"],
            ["test bridge", str(c.get("test_bridge"))],
            ["permission mode", "overdrive (approvals disabled)"],
            ["grader", f"official `swebench` v{c.get('swebench_version')}"],
            ["started / finished", f"{c.get('started_at')} / {c.get('finished_at')}"],
        ],
    )

    # ---- 9. everything else the reader is owed ---------------------------
    others = [f for f in verdict.sorted() if f.severity != honesty.BLOCK]
    if others:
        L += ["## Caveats", ""]
        for f in others:
            L += [f"- **{_SEV_MARK[f.severity].strip()}** `{f.code}` — {f.message}"]
            if f.detail:
                L += [f"  <br/>{f.detail}"]
        L += [""]

    L += [
        "## What this number cannot be used to claim",
        "",
        "- It cannot be compared with any other harness's published SWE-bench "
        "figure. Scaffold alone moves the same model by 8–15 points; see "
        "`bench/report/METHODOLOGY.md`.",
        "- It cannot be quoted without its denominator and its interval.",
        "- It is one sample from a stochastic process. Run-to-run variance on "
        "the same tasks is not captured by the interval above.",
        "",
        "Generated by `bench/report`. Methodology and citations: "
        "`bench/report/METHODOLOGY.md`.",
    ]
    return "\n".join(L) + "\n"
