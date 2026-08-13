#!/usr/bin/env python3
"""SWE-bench runner for OSA.

Four phases, each resumable:

  select    pick instances from the dataset
  prepare   materialise each instance as an editable host workspace
  infer     run the agent, extract a patch  -> predictions.jsonl + inference.jsonl
  evaluate  hand the patches to the official swebench harness -> report.json
  report    merge everything                -> results.json + summary.md

Run `--runner gold` first on any new machine: it should score 100%, and if it
does not, the harness is broken rather than the agent.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import evaluate  # noqa: E402
import report as report_mod  # noqa: E402
import workspace as ws  # noqa: E402
from runners import RunResult, Task, build_runner  # noqa: E402

DEFAULT_DATASET = "princeton-nlp/SWE-bench_Verified"


def log(msg: str) -> None:
    print(f"[bench {datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def load_dataset_rows(name: str, split: str) -> list[dict]:
    from datasets import load_dataset

    if name.endswith(".json") or name.endswith(".jsonl"):
        return [json.loads(l) for l in Path(name).read_text().splitlines() if l.strip()]
    return list(load_dataset(name, split=split))


def select(rows: list[dict], args) -> list[dict]:
    by_id = {r["instance_id"]: r for r in rows}
    if args.instances:
        wanted = [
            l.strip()
            for l in Path(args.instances).read_text().splitlines()
            if l.strip() and not l.startswith("#")
        ]
    elif args.instance_ids:
        wanted = args.instance_ids
    else:
        wanted = [r["instance_id"] for r in rows]
        if args.repo:
            wanted = [i for i in wanted if by_id[i]["repo"] == args.repo]
        if args.difficulty:
            wanted = [
                i for i in wanted if by_id[i].get("difficulty", "") == args.difficulty
            ]
        if args.limit:
            wanted = wanted[: args.limit]

    missing = [i for i in wanted if i not in by_id]
    if missing:
        raise SystemExit(f"instance ids not in dataset: {missing}")
    return [by_id[i] for i in wanted]


def default_tests_for(instance: dict) -> str:
    """The FAIL_TO_PASS node ids, for the workspace's run_tests.sh default."""
    try:
        ids = json.loads(instance["FAIL_TO_PASS"])
    except (json.JSONDecodeError, KeyError, TypeError):
        return ""
    # Only the file part is safe to hand to a bare pytest invocation across all
    # repos (django uses its own runner with dotted paths).
    return " ".join(f"'{i}'" for i in ids[:10])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runner", default="gold", choices=["gold", "empty", "osa"])
    ap.add_argument("--run-id", default=None, help="defaults to <runner>-<timestamp>")
    ap.add_argument("--dataset", default=DEFAULT_DATASET)
    ap.add_argument("--split", default="test")

    sel = ap.add_argument_group("instance selection")
    sel.add_argument("--instances", help="file with one instance_id per line")
    sel.add_argument("--instance-ids", nargs="*", default=None)
    sel.add_argument("--limit", type=int, default=None)
    sel.add_argument("--repo", default=None)
    sel.add_argument("--difficulty", default=None, help='e.g. "<15 min fix"')

    osa = ap.add_argument_group("osa runner")
    osa.add_argument("--osa-mode", default="http", choices=["http", "cli"])
    osa.add_argument("--osa-url", default=os.environ.get("OSA_BENCH_URL", "http://127.0.0.1:19801"))
    osa.add_argument("--osa-repo", default=str(HERE.parent.parent))
    osa.add_argument("--osa-token", default=os.environ.get("OSA_BENCH_TOKEN"))
    osa.add_argument("--model", default=None)
    osa.add_argument("--provider", default=None)
    osa.add_argument("--max-turns", type=int, default=60)
    osa.add_argument("--max-budget-usd", type=float, default=None)

    run = ap.add_argument_group("execution")
    run.add_argument("--agent-timeout", type=int, default=1800, help="per task, seconds")
    run.add_argument("--eval-timeout", type=int, default=1800, help="per instance, seconds")
    run.add_argument("--eval-workers", type=int, default=4)
    run.add_argument("--namespace", default="swebench", help='"none" to build locally')
    run.add_argument("--cache-level", default="env", choices=["none", "base", "env", "instance"])
    run.add_argument("--no-test-bridge", action="store_true",
                     help="do not give the agent a container to run tests in")
    run.add_argument("--keep-workspaces", action="store_true")
    run.add_argument("--skip-eval", action="store_true", help="inference only")
    run.add_argument("--reuse-inference", action="store_true",
                     help="re-grade and re-report an existing run without re-running the agent")

    args = ap.parse_args()

    run_id = args.run_id or f"{args.runner}-{time.strftime('%Y%m%d-%H%M%S')}"
    out = HERE / "runs" / run_id
    out.mkdir(parents=True, exist_ok=True)
    venv_python = HERE / ".venv" / "bin" / "python"
    python = venv_python if venv_python.exists() else Path(sys.executable)

    log(f"run_id={run_id}  out={out}")

    rows = load_dataset_rows(args.dataset, args.split)
    dataset_by_id = {r["instance_id"]: r for r in rows}
    chosen = select(rows, args)
    instance_ids = [r["instance_id"] for r in chosen]
    log(f"{len(instance_ids)} instance(s) selected from {len(rows)}")

    import swebench

    model_name = f"osa-{args.runner}" if args.runner != "osa" else (args.model or "osa")
    config = {
        "run_id": run_id,
        "runner": args.runner,
        "transport": args.osa_mode if args.runner == "osa" else None,
        "model": model_name,
        "dataset_name": args.dataset,
        "split": args.split,
        "dataset_size": len(rows),
        "instance_ids": instance_ids,
        "agent_timeout_s": args.agent_timeout,
        "max_turns": args.max_turns,
        "test_bridge": not args.no_test_bridge,
        "namespace": args.namespace,
        "swebench_version": swebench.__version__,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "host": {"platform": platform.platform(), "python": platform.python_version()},
    }
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")

    inference_path = out / "inference.jsonl"
    predictions_path = out / "predictions.jsonl"

    # ---------------- inference ----------------
    if args.reuse_inference and inference_path.exists():
        log("reusing existing inference.jsonl")
        inference = [json.loads(l) for l in inference_path.read_text().splitlines() if l.strip()]
    else:
        runner = build_runner(
            args.runner,
            dataset_by_id=dataset_by_id,
            opts={
                "mode": args.osa_mode,
                "base_url": args.osa_url,
                "auth_token": args.osa_token,
                "model": args.model,
                "provider": args.provider,
                "max_turns": args.max_turns,
                "max_budget_usd": args.max_budget_usd,
                "timeout_s": args.agent_timeout,
                "repo_root": Path(args.osa_repo),
                "log_dir": out / "logs",
                "with_test_bridge": not args.no_test_bridge,
                "run_id": run_id,
            },
        )
        runner.prepare()

        results: list[RunResult] = []
        ws_root = out / "workspaces"
        try:
            for n, inst in enumerate(chosen, 1):
                iid = inst["instance_id"]
                log(f"({n}/{len(chosen)}) {iid} — preparing workspace")
                prepared = None
                try:
                    prepared = ws.prepare(
                        inst,
                        ws_root,
                        namespace="" if args.namespace == "none" else args.namespace,
                        with_container=not args.no_test_bridge,
                        default_tests=default_tests_for(inst),
                    )
                    task = Task(
                        instance_id=iid,
                        repo=inst["repo"],
                        base_commit=inst["base_commit"],
                        problem_statement=inst["problem_statement"],
                        version=str(inst.get("version", "")),
                        workspace=prepared.path,
                        container=prepared.container,
                        timeout_s=args.agent_timeout,
                    )
                    log(f"({n}/{len(chosen)}) {iid} — running {args.runner}")
                    res = runner.run(task)
                except Exception as e:  # noqa: BLE001
                    res = RunResult(
                        instance_id=iid,
                        status="runner_error",
                        error=f"{type(e).__name__}: {e}",
                    )
                finally:
                    if prepared:
                        prepared.teardown(keep_files=args.keep_workspaces)
                log(f"({n}/{len(chosen)}) {iid} — {res.status}, "
                    f"{res.wall_clock_s:.1f}s, {len(res.patch)}B patch")
                results.append(res)
        finally:
            runner.close()

        with inference_path.open("w") as fh:
            for r in results:
                fh.write(json.dumps(r.to_json()) + "\n")
        evaluate.write_predictions(predictions_path, results, model_name)
        inference = [r.to_json() for r in results]

    if args.skip_eval:
        log(f"inference only; predictions at {predictions_path}")
        return 0

    # ---------------- evaluation ----------------
    log("grading with the official swebench harness (Docker)…")
    eval_dir = out / "eval"
    report_path = evaluate.run_evaluation(
        python=python,
        dataset_name=args.dataset,
        split=args.split,
        predictions_path=predictions_path,
        run_id=run_id,
        instance_ids=instance_ids,
        report_dir=eval_dir,
        max_workers=args.eval_workers,
        timeout=args.eval_timeout,
        namespace="none" if args.namespace == "none" else args.namespace,
        cache_level=args.cache_level,
    )
    harness_report = evaluate.load_report(report_path)
    outcomes = evaluate.per_instance_outcomes(harness_report)

    # ---------------- report ----------------
    config["finished_at"] = datetime.now(timezone.utc).isoformat()
    results_doc = report_mod.build(
        config=config,
        inference=inference,
        outcomes=outcomes,
        harness_report=harness_report,
        report_dir=eval_dir,
        run_id=run_id,
        model=model_name,
    )
    rj, sm = report_mod.write(results_doc, out)
    a = results_doc["aggregate"]
    log(f"RESOLVED {a['instances_resolved']}/{a['instances_attempted']} "
        f"({(a['resolve_rate'] or 0) * 100:.1f}%)")
    log(f"results: {rj}")
    log(f"summary: {sm}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
