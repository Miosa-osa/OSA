#!/usr/bin/env python3
"""SWE-bench Pro runner for OSA.

Phases, each resumable:

  select    pick instances from the 731-instance public split
  prepare   materialise each instance as an editable host workspace (/app)
  infer     run the agent, extract a patch  -> patches.json + inference.jsonl
  evaluate  hand the patches to the OFFICIAL harness -> eval_results.json
  report    merge everything                -> results.json + summary.md

Run the controls first on any new machine, and run BOTH of them:

    ./run_bench.py --runner gold-apply --sample 5 --run-id ctrl-gold
    ./run_bench.py --runner empty      --instances runs/ctrl-gold/instances.txt

`gold-apply` must score ~100% and `empty` exactly 0%. If either misses, the
harness is broken and any OSA number from it means nothing.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Ours goes first and stays first; `shared` appends bench/swebench behind it.
# Both packages define runners/evaluate/workspace, so path order is load-bearing.
sys.path.insert(0, str(HERE))

import dataset as ds  # noqa: E402
import evaluate  # noqa: E402
import shared  # noqa: E402
import workspace as ws  # noqa: E402
from runners import RunResult, Task, build_runner  # noqa: E402

# Shared with the Verified runner on purpose -- see evaluate.py's docstring.
airgap = shared.sb_airgap
diagnose = shared.sb_diagnose
report_mod = shared.sb_report


def log(msg: str) -> None:
    print(f"[swebp {datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def select(rows: list[dict], args) -> tuple[list[dict], dict]:
    by_id = {r["instance_id"]: r for r in rows}

    if args.instances:
        wanted = [
            l.strip() for l in Path(args.instances).read_text().splitlines()
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
        if args.language:
            pool = [r for r in pool if r.get("repo_language") == args.language]
            filters["repo_language"] = args.language

        if args.sample:
            chosen, provenance = ds.stratified_sample(
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
        raise SystemExit(f"instance ids not in dataset: {missing[:5]}")
    return [by_id[i] for i in wanted], provenance


def build_argparser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--runner", default="gold-apply",
                    choices=["gold", "gold-apply", "empty", "osa"],
                    help="gold-apply is the control that exercises workspace "
                         "prep and patch extraction; plain gold bypasses both")
    ap.add_argument("--run-id", default=None, help="defaults to <runner>-<timestamp>")
    ap.add_argument("--dataset", default=ds.DATASET,
                    help="HF id, or a local .jsonl dumped from it")
    ap.add_argument("--split", default=ds.SPLIT)

    sel = ap.add_argument_group("instance selection")
    sel.add_argument("--instances", help="file with one instance_id per line")
    sel.add_argument("--instance-ids", nargs="*", default=None)
    sel.add_argument("--limit", type=int, default=None,
                     help="first N rows in dataset order — NOT a sample; use --sample")
    sel.add_argument("--repo", default=None, help='e.g. "flipt-io/flipt"')
    sel.add_argument("--language", default=None, choices=["go", "python", "js", "ts"])
    sel.add_argument("--sample", type=int, default=None,
                     help="draw N instances stratified across repos")
    sel.add_argument("--sample-seed", type=int, default=20260814)
    sel.add_argument("--sample-bias", default="hard", choices=["hard", "uniform"])

    osa = ap.add_argument_group("osa runner")
    osa.add_argument("--osa-mode", default="http", choices=["http", "cli"])
    osa.add_argument("--osa-url",
                     default=os.environ.get("OSA_BENCH_URL", "http://127.0.0.1:19801"))
    osa.add_argument("--osa-repo", default=str(HERE.parent.parent))
    osa.add_argument("--osa-token", default=os.environ.get("OSA_BENCH_TOKEN"))
    osa.add_argument("--model", default=None)
    osa.add_argument("--provider", default=None)
    osa.add_argument("--max-turns", type=int, default=120,
                     help="higher than the Verified default: Pro's gold fixes "
                          "touch a median of 4 files, so a 60-turn cap "
                          "measures the cap")
    osa.add_argument("--max-budget-usd", type=float, default=None)
    osa.add_argument("--context-mode", default="full", choices=list(("full", "no-spec")),
                     help="'full' gives the agent problem_statement + "
                          "requirements + interface (the leaderboard setting). "
                          "'no-spec' withholds the latter two -- the published "
                          "ablation puts that at roughly a third of the score, "
                          "which makes it a direct probe of context assembly.")

    run = ap.add_argument_group("execution")
    run.add_argument("--agent-timeout", type=int, default=3600,
                     help="per task, seconds")
    run.add_argument("--eval-workers", type=int, default=2,
                     help="parallelism of the OFFICIAL grading harness. Each "
                          "worker runs a full repo test suite in its own "
                          "container; 2 is deliberate on a workstation")
    run.add_argument("--infer-workers", type=int, default=2)
    run.add_argument("--attempts", type=int, default=1,
                     help="independent attempts per instance -> pass@k / pass^k")
    run.add_argument("--test-file-hint", action="store_true",
                     help="put selected_test_files_to_run in run_tests.sh. OFF "
                          "by default: naming the graded files is an advantage "
                          "leaderboard agents do not get")
    run.add_argument("--min-free-gb", type=float, default=60.0,
                     help="abort before preparing an instance if the disk is "
                          "below this — instance images are 2-3 GB each (measured)")
    run.add_argument("--prune-images", action="store_true",
                     help="delete this run's instance images after grading")
    run.add_argument("--dockerhub-user", default=ds.DOCKERHUB_USER)
    run.add_argument("--no-test-bridge", action="store_true",
                     help="do not give the agent a container to run tests in")
    run.add_argument("--keep-workspaces", action="store_true")
    run.add_argument("--skip-eval", action="store_true", help="inference only")
    run.add_argument("--reuse-inference", action="store_true",
                     help="re-grade and re-report an existing run")
    run.add_argument("--eval-network", action="store_true",
                     help="allow the GRADING containers network access. Off by "
                          "default; several of these suites fetch modules at "
                          "test time, which makes the grade depend on the "
                          "internet rather than on the patch")

    air = ap.add_argument_group("web-lookup prevention")
    air.add_argument("--airgap", action="store_true",
                     help="require that the backend refuses web_search/web_fetch/"
                          "download/browser/github. The run ABORTS unless a live "
                          "differential probe observes the refusal.")
    air.add_argument("--write-airgap-settings", metavar="PATH", default=None,
                     help="write the OSA_SETTINGS deny-list file and exit")
    air.add_argument("--airgap-probe-timeout", type=int, default=240)
    return ap


def main() -> int:
    args = build_argparser().parse_args()

    if args.write_airgap_settings:
        p = Path(args.write_airgap_settings)
        airgap.write_settings(p)
        log(f"wrote {p}")
        log(f"start the benchmark backend with:  OSA_SETTINGS={p.resolve()} "
            f"OSA_HTTP_PORT=<port> mix osa.serve")
        return 0

    harness_dir = HERE / "harness"
    if not (harness_dir / "swe_bench_pro_eval.py").exists():
        log(f"official harness missing at {harness_dir}; run ./setup.sh first")
        return 2

    run_id = args.run_id or f"{args.runner}-{time.strftime('%Y%m%d-%H%M%S')}"
    out = HERE / "runs" / run_id
    out.mkdir(parents=True, exist_ok=True)
    venv_python = HERE / ".venv" / "bin" / "python"
    python = venv_python if venv_python.exists() else Path(sys.executable)

    log(f"run_id={run_id}  out={out}")

    rows = ds.load_rows(args.dataset, args.split)
    dataset_by_id = {r["instance_id"]: r for r in rows}
    chosen, sampling = select(rows, args)
    instance_ids = [r["instance_id"] for r in chosen]
    (out / "instances.txt").write_text("\n".join(instance_ids) + "\n")
    log(f"{len(instance_ids)} instance(s) selected from {len(rows)} "
        f"via {sampling.get('method')}")
    if sampling.get("mean_hardness_sample") is not None:
        log(f"  mean hardness {sampling['mean_hardness_sample']} vs "
            f"{sampling['mean_hardness_population']} for the full dataset")
        log(f"  language mix: {sampling.get('language_mix_sample')}")

    # The dataset must be on disk as JSON for the official harness, which reads
    # a CSV/JSONL rather than the HF dataset. Dumping the *whole* split (not
    # just the subset) keeps the grader's index identical between runs.
    raw_path = HERE / "data" / "swebench_pro_public.jsonl"
    if not raw_path.exists():
        raw_path.parent.mkdir(parents=True, exist_ok=True)
        with raw_path.open("w") as fh:
            for r in ds.load_rows(ds.DATASET, ds.SPLIT):
                fh.write(json.dumps(r) + "\n")
        log(f"wrote {raw_path}")

    log(f"disk: {ws.free_gb(HERE):.0f} GB free; instance images are 2-3 GB each")

    # A dataset revision that breaks the revert-list invariant would silently
    # change what is scored. Checked on the selected subset, every run.
    disagree = [r["instance_id"] for r in chosen if not ds.revert_list_agrees(r)]
    if disagree:
        log(f"WARNING: {len(disagree)} instance(s) where the grader's revert "
            f"list disagrees with test_patch: {disagree[:3]}")

    model_name = f"osa-{args.runner}" if args.runner != "osa" else (args.model or "osa")
    config = {
        "run_id": run_id,
        "benchmark": "SWE-bench_Pro",
        "runner": args.runner,
        "transport": args.osa_mode if args.runner == "osa" else None,
        "model": model_name,
        "dataset_name": ds.DATASET,
        "split": ds.SPLIT,
        "dataset_size": len(rows),
        "instance_ids": instance_ids,
        "sampling": sampling,
        "context_mode": args.context_mode if args.runner == "osa" else None,
        "attempts": args.attempts,
        "agent_timeout_s": args.agent_timeout,
        "max_turns": args.max_turns,
        "test_bridge": not args.no_test_bridge,
        "test_file_hint": args.test_file_hint,
        "infer_workers": args.infer_workers,
        "eval_workers": args.eval_workers,
        "eval_block_network": not args.eval_network,
        "dockerhub_user": args.dockerhub_user,
        "harness_repo": "github.com/scaleapi/SWE-bench_Pro-os",
        "harness_commit": evaluate.harness_commit(harness_dir),
        "revert_list_disagreements": disagree,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "host": {"platform": platform.platform(), "python": platform.python_version()},
    }

    # ---------------- web-lookup prevention, proved before anything runs ----
    #
    # The order matters. Probing AFTER the run would produce a number first and
    # ask whether it was earned second, and the number would get quoted. So the
    # probe is a precondition: either a live backend is observed refusing a
    # denied tool, or this exits without spending a single instance.
    #
    # Pro needs this at least as much as Verified does. Every public instance
    # is a merged commit in a public repository and the prompt names both the
    # repo and the base commit, so one web search returns the answer.
    if args.airgap:
        if args.runner != "osa" or args.osa_mode != "http":
            log("--airgap requires --runner osa --osa-mode http")
            return 2
        log(f"probing {args.osa_url} for web-lookup prevention…")
        att = airgap.probe(base_url=args.osa_url, auth_token=args.osa_token,
                           timeout_s=args.airgap_probe_timeout)
        config["airgap"] = att
        (out / "airgap-probe.json").write_text(json.dumps(att, indent=2) + "\n")
        if not att.get("enforced"):
            log("AIRGAP NOT ENFORCED — refusing to run.")
            log(f"  {att.get('error') or 'the probe saw no refusal'}")
            log(f"  full attestation: {out / 'airgap-probe.json'}")
            return 3
        log("airgap ENFORCED: denied tool refused, control tool still works")

    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")

    attempt_docs: list[dict] = []
    for attempt in range(1, args.attempts + 1):
        adir = out if args.attempts == 1 else out / f"attempt{attempt}"
        adir.mkdir(parents=True, exist_ok=True)
        arun_id = run_id if args.attempts == 1 else f"{run_id}-a{attempt}"
        if args.attempts > 1:
            log(f"===== attempt {attempt}/{args.attempts} =====")

        inference = run_inference(
            args=args, chosen=chosen, dataset_by_id=dataset_by_id,
            harness_dir=harness_dir, out=adir, run_id=arun_id,
        )
        if args.skip_eval:
            continue

        log("grading with the OFFICIAL SWE-bench Pro harness (Docker)…")
        eval_dir = adir / "eval"
        evaluate.run_evaluation(
            python=python,
            harness_dir=harness_dir,
            raw_sample_path=raw_path,
            patches_path=adir / "patches.json",
            output_dir=eval_dir,
            num_workers=args.eval_workers,
            dockerhub_user=args.dockerhub_user,
            block_network=not args.eval_network,
        )
        outcomes, details = evaluate.collect(
            eval_output_dir=eval_dir,
            prefix=arun_id,
            instances=chosen,
            submitted_patch_bytes={
                i["instance_id"]: i.get("patch_bytes", 0) for i in inference
            },
        )
        evaluate.write_swebench_layout(
            report_dir=eval_dir, run_id=arun_id, model=model_name, details=details,
        )
        log(f"outcomes: {evaluate.summary(outcomes)}")

        harness_report = {
            "benchmark": "SWE-bench_Pro",
            "harness_commit": config["harness_commit"],
            "total_instances": len(rows),
            "submitted_instances": len(inference),
            "completed_instances": sum(
                1 for v in outcomes.values() if v in ("resolved", "unresolved")
            ),
            "resolved_instances": sum(1 for v in outcomes.values() if v == "resolved"),
            "unresolved_instances": sum(1 for v in outcomes.values() if v == "unresolved"),
            "empty_patch_instances": sum(1 for v in outcomes.values() if v == "empty_patch"),
            "error_instances": sum(1 for v in outcomes.values() if v == "eval_error"),
            "incomplete_instances": sum(1 for v in outcomes.values() if v == "incomplete"),
        }

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
        log(f"inference only; patches under {out}")
        return 0

    config["finished_at"] = datetime.now(timezone.utc).isoformat()
    results_doc = report_mod.merge_attempts(attempt_docs, config)
    rj, sm = report_mod.write(results_doc, out)

    n_dossiers = diagnose.write_failure_dossiers(results_doc, out / "failures")
    a = results_doc["aggregate"]
    diag = a.get("diagnosis") or {}
    if a.get("attempts", 1) > 1:
        log(f"pass@1 {(a['pass_at_1'] or 0) * 100:.1f}%  (PRIMARY)   "
            f"pass@{a['attempts']} {(a['pass_at_k'] or 0) * 100:.1f}%")
    else:
        log(f"RESOLVED {a['instances_resolved']}/{a['instances_attempted']} "
            f"({(a['resolve_rate'] or 0) * 100:.1f}%)  pass@1, single attempt")
    log(f"failure fault split: {diag.get('by_fault')}")
    for bug in a.get("probable_osa_bugs") or []:
        log(f"  PROBABLE OSA BUG: {bug['bucket']} x{bug['count']}")
    log(f"{n_dossiers} failure dossier(s): {out / 'failures'}")
    log(f"results: {rj}")
    log(f"summary: {sm}")

    if args.prune_images:
        freed = ws.prune_images(chosen, args.dockerhub_user)
        log(f"pruned {freed} instance image(s); {ws.free_gb(HERE):.0f} GB free")
    return 0


def run_inference(*, args, chosen, dataset_by_id, harness_dir: Path,
                  out: Path, run_id: str) -> list[dict]:
    """One attempt at every instance. Returns the inference records."""
    inference_path = out / "inference.jsonl"
    patches_path = out / "patches.json"

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
            "context_mode": args.context_mode,
        },
    )
    runner.prepare()

    ws_root = out / "workspaces"
    total = len(chosen)
    done = 0
    lock = threading.Lock()

    def one(inst: dict) -> RunResult:
        nonlocal done
        iid = inst["instance_id"]
        prepared = None
        try:
            if ws.free_gb(HERE) < args.min_free_gb:
                raise RuntimeError(
                    f"only {ws.free_gb(HERE):.0f} GB free, below --min-free-gb "
                    f"{args.min_free_gb}; refusing to pull another 2-3 GB image"
                )
            prepared = ws.prepare(
                inst, ws_root, harness_dir,
                with_container=not args.no_test_bridge,
                test_file_hint=args.test_file_hint,
                dockerhub_user=args.dockerhub_user,
            )
            task = Task(
                instance_id=iid,
                repo=inst["repo"],
                base_commit=inst["base_commit"],
                problem_statement=inst["problem_statement"],
                version=str(inst.get("repo_language", "")),
                workspace=prepared.path,
                container=prepared.container,
                timeout_s=args.agent_timeout,
                # Read from the grader's own command, never guessed. See
                # dataset.graded_away_paths.
                graded_away_paths=ds.graded_away_paths(inst),
            )
            res = runner.run(task)
            res.raw.setdefault("preexisting_untracked", prepared.preexisting_untracked)
        except Exception as e:  # noqa: BLE001 - one bad instance must not end the run
            res = RunResult(instance_id=iid, status="runner_error",
                            error=f"{type(e).__name__}: {e}")
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
            results = [one(inst) for inst in chosen]
        else:
            with ThreadPoolExecutor(max_workers=workers) as pool:
                futures = {pool.submit(one, inst): inst["instance_id"] for inst in chosen}
                by_id = {}
                for fut in as_completed(futures):
                    r = fut.result()
                    by_id[r.instance_id] = r
            # Selection order, not completion order, so two runs diff cleanly.
            results = [by_id[i["instance_id"]] for i in chosen]
    finally:
        runner.close()

    with inference_path.open("w") as fh:
        for r in results:
            fh.write(json.dumps(r.to_json()) + "\n")
    evaluate.write_patches(patches_path, results, prefix=run_id)
    return [r.to_json() for r in results]


if __name__ == "__main__":
    sys.exit(main())
