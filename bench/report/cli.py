#!/usr/bin/env python3
"""bench/report — turn bench/swebench run artefacts into a defensible report.

  python bench/report/cli.py summarise bench/swebench/runs/osa-smoke2
  python bench/report/cli.py summarise <run> --json --out report.json
  python bench/report/cli.py manifest  <run> --out manifest.json
  python bench/report/cli.py failures  <run>
  python bench/report/cli.py compare   <run-a> <run-b>
  python bench/report/cli.py gate      <run>      # exit 1 if not quotable

Standard library only, plus nothing. It reads bench/swebench output and never
writes into it.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import failures as fail_mod  # noqa: E402
import honesty  # noqa: E402
import manifest as manifest_mod  # noqa: E402
import render as render_mod  # noqa: E402
from loader import Run, SchemaError  # noqa: E402
from stats import interval, two_proportion  # noqa: E402


def _load(p: str) -> Run:
    try:
        return Run.load(Path(p))
    except SchemaError as e:
        raise SystemExit(f"error: {e}") from None


def _find_controls(run: Run) -> dict[str, Run]:
    """Look for gold/empty runs over the *same instance set* next to this one.

    Same set, not merely same directory: a gold control over different
    instances validates nothing about this run.
    """
    out: dict[str, Run] = {}
    runs_dir = run.path.parent.parent
    if not runs_dir.is_dir():
        return out
    for cand in sorted(runs_dir.glob("*/results.json")):
        if cand == run.path:
            continue
        try:
            other = Run.load(cand)
        except SchemaError:
            continue
        if other.runner in ("gold", "empty") and other.id_set == run.id_set:
            out.setdefault(other.runner, other)
    return out


def _find_siblings(run: Run) -> list[Run]:
    """Other runs of the same runner+model over the same instance set."""
    out: list[Run] = []
    runs_dir = run.path.parent.parent
    if not runs_dir.is_dir():
        return out
    for cand in sorted(runs_dir.glob("*/results.json")):
        if cand == run.path:
            continue
        try:
            other = Run.load(cand)
        except SchemaError:
            continue
        if (
            other.runner == run.runner
            and other.model == run.model
            and other.id_set == run.id_set
        ):
            out.append(other)
    return out


def _analyse(run: Run, args) -> tuple[honesty.Verdict, fail_mod.FailureAnalysis, dict]:
    controls = {} if getattr(args, "no_controls", False) else _find_controls(run)
    siblings = _find_siblings(run)
    verdict = honesty.evaluate(
        run,
        controls=controls,
        sibling_runs=siblings,
        confidence=args.confidence,
        declared_random_seed=getattr(args, "seed", None),
    )
    return verdict, fail_mod.analyse(run), controls


def _emit(text: str, out: str | None) -> None:
    if out:
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        Path(out).write_text(text)
        print(f"wrote {out}", file=sys.stderr)
    else:
        sys.stdout.write(text)


# ---------------------------------------------------------------------------


def cmd_summarise(args) -> int:
    run = _load(args.run)
    verdict, analysis, controls = _analyse(run, args)

    if args.json:
        ci = interval(run.k, run.n, args.confidence, args.method)
        doc = {
            "run_id": run.run_id,
            "claim_label": honesty.claim_label(run, verdict),
            "n": run.n,
            "k": run.k,
            "n_scorable": run.n_scorable,
            "is_full_dataset_run": run.is_full_dataset,
            "rate": ci.to_json(),
            "may_quote_headline_rate": verdict.may_quote_headline_rate,
            "validity": verdict.to_json(),
            "failures": analysis.to_json(),
            "controls": {
                name: {"run_id": c.run_id, "k": c.k, "n": c.n}
                for name, c in controls.items()
            },
            "cost": {
                k: run.aggregate.get(k)
                for k in (
                    "wall_clock_total_s",
                    "tokens_in_total",
                    "tokens_out_total",
                    "tokens_per_resolved",
                    "cost_usd_total",
                    "cost_usd_per_resolved",
                )
            },
            "config": run.config,
        }
        _emit(json.dumps(doc, indent=2) + "\n", args.out)
    else:
        _emit(
            render_mod.render(
                run,
                verdict=verdict,
                analysis=analysis,
                controls=controls,
                confidence=args.confidence,
                method=args.method,
            ),
            args.out,
        )
    return 0


def cmd_failures(args) -> int:
    run = _load(args.run)
    analysis = fail_mod.analyse(run)
    if args.json:
        _emit(json.dumps(analysis.to_json(), indent=2) + "\n", args.out)
        return 0
    lines = [f"{len(analysis.failures)} failure(s) in {run.run_id}", ""]
    for attr, c in analysis.by_attribution.items():
        lines.append(f"  {attr:12s} {c}")
    lines.append("")
    for f in analysis.failures:
        lines.append(f"- {f.summary}")
        if f.evidence.transcript:
            lines.append(f"    transcript: {f.evidence.transcript}")
        else:
            lines.append("    transcript: MISSING")
    if analysis.leads:
        lines += ["", "Leads:"] + [f"  {i}. {l}" for i, l in enumerate(analysis.leads, 1)]
    _emit("\n".join(lines) + "\n", args.out)
    return 0


def cmd_manifest(args) -> int:
    run = _load(args.run)
    m = manifest_mod.build(run, with_docker=not args.no_docker)
    if args.out:
        m.write(Path(args.out))
    else:
        sys.stdout.write(json.dumps(m.to_json(), indent=2) + "\n")
    return 0


def cmd_compare(args) -> int:
    a, b = _load(args.run_a), _load(args.run_b)
    shared = a.id_set & b.id_set
    lines = [
        f"# Comparison — `{a.run_id}` vs `{b.run_id}`",
        "",
        f"- `{a.run_id}`: {a.k}/{a.n}  model `{a.model}`",
        f"- `{b.run_id}`: {b.k}/{b.n}  model `{b.model}`",
        "",
    ]
    if a.id_set != b.id_set:
        lines += [
            f"> ⚠ **Different instance sets.** {len(shared)} instances in common, "
            f"{len(a.id_set - b.id_set)} only in A, {len(b.id_set - a.id_set)} "
            f"only in B. A difference in rate here mixes a difference in agent "
            f"with a difference in task difficulty and is not interpretable. "
            f"Re-run both over the same set.",
            "",
        ]
    r = two_proportion(a.k, a.n, b.k, b.n, args.confidence)
    if r["diff"] is None:
        lines += [r["note"]]
    else:
        lines += [
            f"Difference (A − B): **{r['diff_pp']:+.1f} pp**, "
            f"{int(args.confidence*100)}% CI "
            f"[{r['low']*100:+.1f}, {r['high']*100:+.1f}] pp ({r['method']}).",
            "",
            f"**{r['note']}.**",
            "",
        ]
        if not r["significant"]:
            lines += [
                "On this evidence the two runs are indistinguishable. Do not "
                "report one as better than the other.",
                "",
            ]
    if shared and a.id_set == b.id_set:
        a_by = {i.instance_id: i.resolved for i in a.instances}
        b_by = {i.instance_id: i.resolved for i in b.instances}
        flips = [i for i in sorted(shared) if a_by.get(i) != b_by.get(i)]
        lines += [
            f"## Instances that changed verdict ({len(flips)})",
            "",
        ]
        for i in flips:
            lines.append(
                f"- `{i}`: A={'resolved' if a_by[i] else 'failed'} → "
                f"B={'resolved' if b_by[i] else 'failed'}"
            )
        lines += [
            "",
            "Note that flips in both directions on the same configuration are "
            "run-to-run noise, and are the best available estimate of it.",
            "",
        ]
    _emit("\n".join(lines) + "\n", args.out)
    return 0


def cmd_gate(args) -> int:
    """CI-friendly: exit non-zero when a run may not be quoted as a score."""
    run = _load(args.run)
    verdict, _, _ = _analyse(run, args)
    for f in verdict.sorted():
        print(f"{f.severity:5s} {f.code}: {f.message}")
    if verdict.blocks:
        print(
            f"\nNOT QUOTABLE as a rate: {len(verdict.blocks)} blocking finding(s).",
            file=sys.stderr,
        )
        return 1
    print("\nQuotable, with the caveats above attached.", file=sys.stderr)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="bench/report",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--confidence", type=float, default=0.95)
    ap.add_argument(
        "--method", default="wilson", choices=["wilson", "clopper-pearson"]
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("run", help="run directory or results.json")
        p.add_argument("--out", default=None)
        p.add_argument("--json", action="store_true")
        p.add_argument("--no-controls", action="store_true")
        p.add_argument(
            "--seed",
            type=int,
            default=None,
            help="declare that the instance set was drawn with this random seed",
        )

    s = sub.add_parser("summarise", help="the full report")
    common(s)
    s.set_defaults(fn=cmd_summarise)

    s = sub.add_parser("failures", help="failure distribution and evidence paths")
    common(s)
    s.set_defaults(fn=cmd_failures)

    s = sub.add_parser("manifest", help="reproducibility manifest")
    common(s)
    s.add_argument("--no-docker", action="store_true", help="skip image digest lookup")
    s.set_defaults(fn=cmd_manifest)

    s = sub.add_parser("gate", help="exit 1 if the run may not be quoted")
    common(s)
    s.set_defaults(fn=cmd_gate)

    s = sub.add_parser("compare", help="two runs, with a difference interval")
    s.add_argument("run_a")
    s.add_argument("run_b")
    s.add_argument("--out", default=None)
    s.set_defaults(fn=cmd_compare)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
