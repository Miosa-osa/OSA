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
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import diagnose  # noqa: E402
import evaluate  # noqa: E402
import report as report_mod  # noqa: E402
import workspace as ws  # noqa: E402
from runners import RunResult, Task, build_runner, test_patch_files  # noqa: E402

DEFAULT_DATASET = "princeton-nlp/SWE-bench_Verified"


def log(msg: str) -> None:
    print(f"[bench {datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def load_dataset_rows(name: str, split: str) -> list[dict]:
    from datasets import load_dataset

    if name.endswith(".json") or name.endswith(".jsonl"):
        return [json.loads(l) for l in Path(name).read_text().splitlines() if l.strip()]
    return list(load_dataset(name, split=split))


#: SWE-bench Verified ships a human-assigned effort estimate. Higher = harder.
DIFFICULTY_RANK = {
    "<15 min fix": 0.0,
    "15 min - 1 hour": 0.45,
    "1-4 hours": 0.8,
    ">4 hours": 1.0,
}


def hardness(inst: dict) -> float:
    """A 0..1 difficulty score, used only to weight sampling.

    Four independent signals, because any one of them is gameable: the human
    effort estimate, how many files the gold fix touches, how much of the repo
    the instance's PASS_TO_PASS set covers (a large set means many ways to
    break something unrelated), and the size of the gold diff.

    This is never used for grading -- only to decide which instances to look
    at, and it is recorded in the config so the choice is auditable.
    """
    d = DIFFICULTY_RANK.get(str(inst.get("difficulty", "")), 0.4)

    patch = inst.get("patch") or ""
    files = patch.count("diff --git ")
    f = min(files / 4.0, 1.0)  # 4+ files edited saturates

    try:
        p2p = len(json.loads(inst.get("PASS_TO_PASS") or "[]"))
    except (json.JSONDecodeError, TypeError):
        p2p = 0
    p = min(p2p / 250.0, 1.0)

    size = min(len(patch) / 6000.0, 1.0)

    return round(0.40 * d + 0.25 * f + 0.20 * p + 0.15 * size, 4)


def stratified_sample(rows: list[dict], n: int, seed: int, bias_hard: bool) -> tuple[list[dict], dict]:
    """Pick `n` instances: proportional across repos, weighted toward the hard end.

    Two separate concerns, deliberately kept separate:

    *Representative* means the repo mix matches the dataset's. Taking the first
    N rows, or all of one repo, produces a number that says nothing -- and
    django alone is 231 of the 500, so any accidental bias lands there.

    *Hard-weighted* means that within each repo, harder instances are more
    likely to be drawn. That is on purpose: this benchmark exists to find
    things to fix, and easy instances that pass tell us nothing. The weight is
    `0.25 + hardness`, so an easy instance is still ~4x less likely than the
    hardest rather than impossible -- a sample of only the worst instances
    would not be representative of anything either.

    Returns (chosen, provenance) where provenance is recorded verbatim in
    config.json so nobody has to guess how the subset was built.
    """
    import random

    rng = random.Random(seed)
    by_repo: dict[str, list[dict]] = {}
    for r in rows:
        by_repo.setdefault(r["repo"], []).append(r)

    total = len(rows)
    # Largest-remainder apportionment, so the repo mix matches the population
    # as closely as an integer split allows.
    exact = {repo: len(rs) * n / total for repo, rs in by_repo.items()}
    quota = {repo: int(v) for repo, v in exact.items()}
    left = n - sum(quota.values())
    for repo in sorted(exact, key=lambda k: -(exact[k] - quota[k])):
        if left <= 0:
            break
        quota[repo] += 1
        left -= 1

    chosen: list[dict] = []
    for repo in sorted(by_repo):
        pool = sorted(by_repo[repo], key=lambda r: r["instance_id"])
        want = min(quota.get(repo, 0), len(pool))
        if want <= 0:
            continue
        if bias_hard:
            # Squared, because a linear weight barely moved the difficulty mix:
            # hardness clusters in 0.1-0.5, so `0.25 + h` spanned only ~2x and
            # the sample came out as easy as the population. `(0.10 + h)**2`
            # spans ~20x, which actually shifts the mix, while still leaving
            # every instance reachable -- a sample of nothing but the hardest
            # instances would not be representative either.
            weights = [(0.10 + hardness(r)) ** 2 for r in pool]
            picked = []
            for _ in range(want):
                tot = sum(weights)
                if tot <= 0:
                    break
                x, acc = rng.random() * tot, 0.0
                for i, w in enumerate(weights):
                    acc += w
                    if acc >= x:
                        picked.append(pool[i])
                        weights[i] = 0.0  # without replacement
                        break
            chosen.extend(picked)
        else:
            chosen.extend(rng.sample(pool, want))

    chosen.sort(key=lambda r: r["instance_id"])
    hs = [hardness(r) for r in chosen]
    all_hs = [hardness(r) for r in rows]
    provenance = {
        "method": "stratified-by-repo"
        + ("+hard-weighted" if bias_hard else "+uniform"),
        "seed": seed,
        "n_requested": n,
        "n_selected": len(chosen),
        "population": total,
        "hard_weighted": bias_hard,
        "weight_formula": "(0.10 + hardness)**2" if bias_hard else "uniform",
        "hardness_formula": (
            "0.40*difficulty + 0.25*min(files_in_gold_patch/4,1) "
            "+ 0.20*min(len(PASS_TO_PASS)/250,1) + 0.15*min(len(patch)/6000,1)"
        ),
        "mean_hardness_sample": round(sum(hs) / len(hs), 4) if hs else None,
        "mean_hardness_population": round(sum(all_hs) / len(all_hs), 4),
        "repo_mix_sample": _repo_mix(chosen),
        "repo_mix_population": _repo_mix(rows),
        "difficulty_mix_sample": _difficulty_mix(chosen),
        "difficulty_mix_population": _difficulty_mix(rows),
    }
    return chosen, provenance


def _repo_mix(rows: list[dict]) -> dict[str, int]:
    out: dict[str, int] = {}
    for r in rows:
        out[r["repo"]] = out.get(r["repo"], 0) + 1
    return dict(sorted(out.items(), key=lambda kv: -kv[1]))


def _difficulty_mix(rows: list[dict]) -> dict[str, int]:
    out: dict[str, int] = {}
    for r in rows:
        k = str(r.get("difficulty", "unknown"))
        out[k] = out.get(k, 0) + 1
    return dict(sorted(out.items()))


def select(rows: list[dict], args) -> tuple[list[dict], dict]:
    by_id = {r["instance_id"]: r for r in rows}
    provenance: dict = {"method": "explicit"}

    if args.instances:
        wanted = [
            l.strip()
            for l in Path(args.instances).read_text().splitlines()
            if l.strip() and not l.startswith("#")
        ]
        provenance = {"method": "instance-list", "source": args.instances,
                      "n_selected": len(wanted), "population": len(rows)}
    elif args.instance_ids:
        wanted = args.instance_ids
        provenance = {"method": "explicit-ids", "n_selected": len(wanted),
                      "population": len(rows)}
    else:
        pool = list(rows)
        filters = {}
        if args.repo:
            pool = [r for r in pool if r["repo"] == args.repo]
            filters["repo"] = args.repo
        if args.difficulty:
            pool = [r for r in pool if r.get("difficulty", "") == args.difficulty]
            filters["difficulty"] = args.difficulty

        if args.sample:
            chosen, provenance = stratified_sample(
                pool, min(args.sample, len(pool)), args.sample_seed,
                bias_hard=(args.sample_bias == "hard"),
            )
            provenance["prefilters"] = filters
            return chosen, provenance

        wanted = [r["instance_id"] for r in pool]
        if args.limit:
            # Honest about what this is: the first N rows in dataset order is
            # NOT a sample. Use --sample for anything you intend to quote.
            wanted = wanted[: args.limit]
            provenance = {"method": "head-of-dataset-order (NOT a random sample)",
                          "prefilters": filters, "n_selected": len(wanted),
                          "population": len(rows)}
        else:
            provenance = {"method": "all-matching", "prefilters": filters,
                          "n_selected": len(wanted), "population": len(rows)}

    missing = [i for i in wanted if i not in by_id]
    if missing:
        raise SystemExit(f"instance ids not in dataset: {missing}")
    return [by_id[i] for i in wanted], provenance


def free_gb(path: Path) -> float:
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 1e9


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runner", default="gold",
                    choices=["gold", "gold-apply", "empty", "osa"],
                    help="gold-apply is the control that exercises workspace "
                         "prep and patch extraction; plain gold bypasses both")
    ap.add_argument("--run-id", default=None, help="defaults to <runner>-<timestamp>")
    ap.add_argument("--dataset", default=DEFAULT_DATASET)
    ap.add_argument("--split", default="test")

    sel = ap.add_argument_group("instance selection")
    sel.add_argument("--instances", help="file with one instance_id per line")
    sel.add_argument("--instance-ids", nargs="*", default=None)
    sel.add_argument("--limit", type=int, default=None,
                     help="first N rows in dataset order — NOT a sample; use --sample")
    sel.add_argument("--repo", default=None)
    sel.add_argument("--difficulty", default=None, help='e.g. "<15 min fix"')
    sel.add_argument("--sample", type=int, default=None,
                     help="draw N instances stratified across repos (see --sample-bias)")
    sel.add_argument("--sample-seed", type=int, default=20260813)
    sel.add_argument("--sample-bias", default="hard", choices=["hard", "uniform"],
                     help="'hard' over-weights multi-file / many-PASS_TO_PASS / "
                          "high-effort instances, because easy passes teach nothing")

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
    run.add_argument("--eval-workers", type=int, default=4,
                     help="parallelism of the OFFICIAL grading harness")
    run.add_argument("--infer-workers", type=int, default=2,
                     help="instances run concurrently against the agent. Modest "
                          "by default: each worker holds a container, a "
                          "workspace and an OSA session, and a backend under "
                          "contention changes the very latencies being measured")
    run.add_argument("--attempts", type=int, default=1,
                     help="independent attempts per instance -> pass@k / pass^k")
    run.add_argument("--f2p-hint", action="store_true",
                     help="put the FAIL_TO_PASS ids in run_tests.sh. OFF by "
                          "default: it is an advantage leaderboard agents do "
                          "not get and it inflates the score")
    run.add_argument("--min-free-gb", type=float, default=40.0,
                     help="abort before preparing an instance if the disk is "
                          "below this — instance images are 3-5 GB each")
    run.add_argument("--prune-images", action="store_true",
                     help="delete this run's instance images after grading")
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
    chosen, sampling = select(rows, args)
    instance_ids = [r["instance_id"] for r in chosen]
    log(f"{len(instance_ids)} instance(s) selected from {len(rows)} "
        f"via {sampling.get('method')}")
    if sampling.get("mean_hardness_sample") is not None:
        log(f"  mean hardness {sampling['mean_hardness_sample']} vs "
            f"{sampling['mean_hardness_population']} for the full dataset")
        log(f"  repo mix: {sampling['repo_mix_sample']}")

    log(f"disk: {free_gb(HERE):.0f} GB free; instance images are 3-5 GB each")

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
        # How the subset was built, recorded verbatim so the number can never
        # be quoted without its qualification.
        "sampling": sampling,
        "attempts": args.attempts,
        "agent_timeout_s": args.agent_timeout,
        "max_turns": args.max_turns,
        "test_bridge": not args.no_test_bridge,
        "f2p_hint": args.f2p_hint,
        "infer_workers": args.infer_workers,
        "eval_workers": args.eval_workers,
        "namespace": args.namespace,
        "swebench_version": swebench.__version__,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "host": {"platform": platform.platform(), "python": platform.python_version()},
    }
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")

    attempt_docs: list[dict] = []
    for attempt in range(1, args.attempts + 1):
        # k=1 keeps the historical flat layout so existing runs stay readable;
        # k>1 gets a subdirectory per attempt.
        adir = out if args.attempts == 1 else out / f"attempt{attempt}"
        adir.mkdir(parents=True, exist_ok=True)
        arun_id = run_id if args.attempts == 1 else f"{run_id}-a{attempt}"
        if args.attempts > 1:
            log(f"===== attempt {attempt}/{args.attempts} =====")

        inference = run_inference(
            args=args, chosen=chosen, dataset_by_id=dataset_by_id,
            out=adir, run_id=arun_id, model_name=model_name,
        )
        if args.skip_eval:
            continue

        log("grading with the official swebench harness (Docker)…")
        eval_dir = adir / "eval"
        report_path = evaluate.run_evaluation(
            python=python,
            dataset_name=args.dataset,
            split=args.split,
            predictions_path=adir / "predictions.jsonl",
            run_id=arun_id,
            instance_ids=instance_ids,
            report_dir=eval_dir,
            max_workers=args.eval_workers,
            timeout=args.eval_timeout,
            namespace="none" if args.namespace == "none" else args.namespace,
            cache_level=args.cache_level,
        )
        harness_report = evaluate.load_report(report_path)
        outcomes = evaluate.per_instance_outcomes(harness_report)

        doc = report_mod.build(
            config=config, inference=inference, outcomes=outcomes,
            harness_report=harness_report, report_dir=eval_dir,
            run_id=arun_id, model=model_name,
        )
        attempt_docs.append(doc)
        a = doc["aggregate"]
        log(f"attempt {attempt}: RESOLVED {a['instances_resolved']}/"
            f"{a['instances_attempted']} ({(a['resolve_rate'] or 0) * 100:.1f}%)")

    if args.skip_eval:
        log(f"inference only; predictions under {out}")
        return 0

    # ---------------- report ----------------
    config["finished_at"] = datetime.now(timezone.utc).isoformat()
    results_doc = report_mod.merge_attempts(attempt_docs, config)
    rj, sm = report_mod.write(results_doc, out)

    n_dossiers = diagnose.write_failure_dossiers(results_doc, out / "failures")
    a = results_doc["aggregate"]
    diag = a.get("diagnosis") or {}
    if a.get("attempts", 1) > 1:
        log(f"pass@1 {(a['pass_at_1'] or 0) * 100:.1f}%  (PRIMARY)   "
            f"pass@{a['attempts']} {(a['pass_at_k'] or 0) * 100:.1f}%   "
            f"pass^{a['attempts']} {(a['pass_hat_k'] or 0) * 100:.1f}%")
    else:
        log(f"RESOLVED {a['instances_resolved']}/{a['instances_attempted']} "
            f"({(a['resolve_rate'] or 0) * 100:.1f}%)  pass@1, single attempt")
    log(f"failure fault split: {diag.get('by_fault')}")
    for bug in a.get("probable_osa_bugs") or []:
        log(f"  PROBABLE OSA BUG: {bug['bucket']} x{bug['count']} "
            f"({', '.join(bug['instances'][:5])})")
    log(f"{n_dossiers} failure dossier(s): {out / 'failures'}")
    log(f"results: {rj}")
    log(f"summary: {sm}")

    if args.prune_images:
        freed = prune_instance_images(instance_ids, args.namespace)
        log(f"pruned {freed} instance image(s); {free_gb(HERE):.0f} GB free")
    return 0


def run_inference(*, args, chosen, dataset_by_id, out: Path, run_id: str,
                  model_name: str) -> list[dict]:
    """One attempt at every instance. Returns the inference records.

    Instances run on a bounded thread pool. Each worker owns its own workspace
    directory, its own test container and its own OSA session, so they do not
    interact -- but they DO share one OSA backend, which is why the default is
    deliberately small. Concurrency here buys wall-clock, and pays for it in
    the fidelity of the per-task latency numbers.
    """
    inference_path = out / "inference.jsonl"
    predictions_path = out / "predictions.jsonl"

    if args.reuse_inference and inference_path.exists():
        log("reusing existing inference.jsonl")
        return [
            json.loads(l) for l in inference_path.read_text().splitlines() if l.strip()
        ]

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
            "transcript_dir": out / "transcripts",
        },
    )
    runner.prepare()

    ws_root = out / "workspaces"
    total = len(chosen)
    done = 0
    lock = threading.Lock()

    def one(n: int, inst: dict) -> RunResult:
        nonlocal done
        iid = inst["instance_id"]
        prepared = None
        try:
            if free_gb(HERE) < args.min_free_gb:
                raise RuntimeError(
                    f"only {free_gb(HERE):.0f} GB free, below --min-free-gb "
                    f"{args.min_free_gb}; refusing to pull another 3-5 GB image"
                )
            prepared = ws.prepare(
                inst,
                ws_root,
                namespace="" if args.namespace == "none" else args.namespace,
                with_container=not args.no_test_bridge,
                f2p_hint=args.f2p_hint,
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
                graded_away_paths=test_patch_files(inst.get("test_patch", "")),
            )
            res = runner.run(task)
        except Exception as e:  # noqa: BLE001 - one bad instance must not end the run
            res = RunResult(
                instance_id=iid, status="runner_error",
                error=f"{type(e).__name__}: {e}",
            )
        finally:
            if prepared:
                prepared.teardown(keep_files=args.keep_workspaces)
        with lock:
            done += 1
            log(f"({done}/{total}) {iid} — {res.status}, "
                f"{res.wall_clock_s:.1f}s, {len(res.patch)}B patch")
        return res

    workers = max(1, args.infer_workers)
    log(f"inference: {total} instance(s) on {workers} worker(s)")
    try:
        if workers == 1:
            results = [one(n, inst) for n, inst in enumerate(chosen, 1)]
        else:
            with ThreadPoolExecutor(max_workers=workers) as pool:
                futures = {
                    pool.submit(one, n, inst): inst["instance_id"]
                    for n, inst in enumerate(chosen, 1)
                }
                by_id = {}
                for fut in as_completed(futures):
                    r = fut.result()
                    by_id[r.instance_id] = r
            # Keep the selection order, not the completion order, so two runs
            # of the same subset produce diffable files.
            results = [by_id[i["instance_id"]] for i in chosen]
    finally:
        runner.close()

    with inference_path.open("w") as fh:
        for r in results:
            fh.write(json.dumps(r.to_json()) + "\n")
    evaluate.write_predictions(predictions_path, results, model_name)
    return [r.to_json() for r in results]


def prune_instance_images(instance_ids: list[str], namespace: str) -> int:
    """Drop this run's instance images. They are 3-5 GB each.

    Only instance images are removed -- the shared base and env layers are what
    make the next run fast, and they are a small fraction of the total.
    """
    removed = 0
    for iid in instance_ids:
        image = ws.instance_image(
            iid, namespace="" if namespace == "none" else namespace
        )
        # `docker rmi` on a missing image does not reliably exit non-zero, so
        # its status cannot be used as the count. Check presence first, or the
        # log reports images freed that never existed.
        if not ws.image_present(image):
            continue
        subprocess.run(["docker", "rmi", "-f", image], capture_output=True)
        if not ws.image_present(image):
            removed += 1
    return removed


if __name__ == "__main__":
    sys.exit(main())
