#!/usr/bin/env python3
"""Fold N *wave* runs of the same arm into one run directory.

WHY THIS EXISTS
---------------
The full SWE-bench Verified set cannot be evaluated in one `run_bench.py`
invocation on this machine, and the reason is disk, not code. Measured on this
host (see `run_full.py`), an instance image costs ~2.4 GB of *marginal* disk
once the shared base and env layers are present; 500 of them is ~1.2 TB against
449 GB free. So the set is processed in waves, each wave prunes its own images,
and the results are stitched back together here.

The stitching is deliberately NOT a re-implementation of the aggregation. It
rebuilds the merged document by calling `report.build()` on the concatenated
inference records and a merged eval tree — the same function `run_bench.py`
calls — so a merged 500 and a hypothetical single-shot 500 differ only in how
the containers were scheduled.

WHAT IT MUST NOT DO
-------------------
It must not make a partial run look complete. `dataset_size` stays 500 and `n`
is whatever actually ran, so `report/loader.py:is_full_dataset` (n ==
dataset_size) is TRUE only when every instance is really present, and the
`subset_not_a_dataset_score` BLOCK keeps firing until then.

USAGE
  merge_waves.py --out full500-osa --run-id full500-osa \
                 --waves runs/w00-osa runs/w01-osa ...
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import diagnose  # noqa: E402
import report as report_mod  # noqa: E402

#: Keys in the official harness report that are plain counts, and the id lists
#: they are derived from. Merging recomputes the count from the merged list
#: rather than adding the per-wave counts, so a duplicated instance cannot
#: inflate a total without also showing up in the list.
COUNT_OF = {
    "total_instances": "submitted_ids",
    "submitted_instances": "submitted_ids",
    "completed_instances": "completed_ids",
    "resolved_instances": "resolved_ids",
    "unresolved_instances": "unresolved_ids",
    "empty_patch_instances": "empty_patch_ids",
    "error_instances": "error_ids",
}
ID_LISTS = [
    "completed_ids", "incomplete_ids", "empty_patch_ids",
    "submitted_ids", "resolved_ids", "unresolved_ids", "error_ids",
]


def _wave_report(wave: Path) -> tuple[dict, str]:
    """The official harness report for a wave, plus that wave's eval run_id."""
    cands = sorted((wave / "eval").glob("*.json"))
    if not cands:
        raise SystemExit(f"{wave}: no harness report under eval/")
    # "<model>.<run_id>.json"
    p = cands[0]
    run_id = p.name.rsplit(".", 2)[-2]
    return json.loads(p.read_text()), run_id


def _link_tree(src: Path, dst: Path) -> None:
    """Hardlink a directory tree; fall back to copy across devices.

    Hardlinks because the per-instance eval logs are the bulky part and a
    merged 500-instance tree would otherwise duplicate every one of them.
    """
    dst.mkdir(parents=True, exist_ok=True)
    for root, _dirs, files in os.walk(src):
        rel = Path(root).relative_to(src)
        (dst / rel).mkdir(parents=True, exist_ok=True)
        for f in files:
            s, d = Path(root) / f, dst / rel / f
            if d.exists():
                continue
            try:
                os.link(s, d)
            except OSError:
                shutil.copy2(s, d)


def merge(waves: list[Path], out: Path, run_id: str,
          dataset_size: int | None = None,
          sampling: dict | None = None) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    eval_dir = out / "eval"

    inference: list[dict] = []
    seen: set[str] = set()
    merged_report: dict = {k: [] for k in ID_LISTS}
    merged_report["schema_version"] = 2
    configs: list[dict] = []
    airgaps: list[dict] = []
    wave_prov: list[dict] = []

    for wave in waves:
        cfg = json.loads((wave / "config.json").read_text())
        configs.append(cfg)
        model = cfg["model"]
        hrep, wave_eval_id = _wave_report(wave)

        rows = [
            json.loads(l) for l in (wave / "inference.jsonl").read_text().splitlines()
            if l.strip()
        ]
        # A wave re-run under the same id would otherwise be counted twice.
        fresh = [r for r in rows if r["instance_id"] not in seen]
        dropped = len(rows) - len(fresh)
        seen.update(r["instance_id"] for r in fresh)
        inference.extend(fresh)

        for k in ID_LISTS:
            merged_report[k].extend(
                i for i in (hrep.get(k) or []) if i not in set(merged_report[k])
            )

        # Re-home this wave's per-instance eval logs under the merged run_id so
        # `report._instance_detail(report_dir, run_id, model, iid)` finds them.
        src = wave / "eval" / "logs" / "run_evaluation" / wave_eval_id / model.replace("/", "__")
        if src.is_dir():
            _link_tree(
                src,
                eval_dir / "logs" / "run_evaluation" / run_id / model.replace("/", "__"),
            )

        if cfg.get("airgap"):
            airgaps.append({"wave": wave.name, **{
                k: cfg["airgap"].get(k) for k in
                ("probed_at", "enforced", "tool_calls_seen")
            }})
        wave_prov.append({
            "wave": wave.name,
            "n": len(fresh),
            "duplicates_dropped": dropped,
            "eval_run_id": wave_eval_id,
            "started_at": cfg.get("started_at"),
            "finished_at": cfg.get("finished_at"),
            "osa_git": (cfg.get("osa_git") or {}).get("head"),
        })

    for count_key, list_key in COUNT_OF.items():
        merged_report[count_key] = len(merged_report[list_key])

    base = configs[0]
    config = dict(base)
    config["run_id"] = run_id
    config["instance_ids"] = [r["instance_id"] for r in inference]
    if dataset_size is not None:
        config["dataset_size"] = dataset_size
    config["merged_from_waves"] = wave_prov
    if sampling is not None:
        # The per-wave runs came from `--instances`, which records no selection
        # provenance -- correctly, since a wave on its own is an arbitrary list.
        # The *union* is not arbitrary: it is a prefix of a seeded shuffle of
        # the whole dataset, which is a declared uniform random sample. Saying
        # so here is what stops the gate reporting selection bias as
        # unquantified when it is in fact quantified.
        s = dict(sampling)
        s["n_selected"] = len(inference)
        config["sampling"] = s
    config["started_at"] = min(c.get("started_at") or "" for c in configs) or None
    config["finished_at"] = datetime.now(timezone.utc).isoformat()
    if airgaps:
        # Every wave probed independently. Keep them all: one enforced probe
        # does not vouch for a wave that ran hours later against a restarted
        # backend, and a single false here must be visible.
        config["airgap"] = dict(base.get("airgap") or {})
        config["airgap"]["per_wave"] = airgaps
        config["airgap"]["enforced"] = all(a.get("enforced") for a in airgaps)

    # OSA's git head must be one program, or the number is two measurements.
    heads = {w["osa_git"] for w in wave_prov if w["osa_git"]}
    config["osa_git_heads_across_waves"] = sorted(heads)

    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    with (out / "inference.jsonl").open("w") as fh:
        for r in inference:
            fh.write(json.dumps(r) + "\n")
    # The official submission file, concatenated in the same order.
    with (out / "predictions.jsonl").open("w") as fh:
        for wave in waves:
            pp = wave / "predictions.jsonl"
            if pp.exists():
                for l in pp.read_text().splitlines():
                    if l.strip():
                        fh.write(l + "\n")
    eval_dir.mkdir(parents=True, exist_ok=True)
    (eval_dir / f"{base['model']}.{run_id}.json").write_text(
        json.dumps(merged_report, indent=2) + "\n"
    )

    import evaluate  # noqa: E402  (late: it imports swebench)
    outcomes = evaluate.per_instance_outcomes(merged_report)
    doc = report_mod.build(
        config=config, inference=inference, outcomes=outcomes,
        harness_report=merged_report, report_dir=eval_dir,
        run_id=run_id, model=base["model"],
    )
    doc = report_mod.merge_attempts([doc], config)
    report_mod.write(doc, out)
    diagnose.write_failure_dossiers(doc, out / "failures")
    return doc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--waves", nargs="+", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--dataset-size", type=int, default=None)
    a = ap.parse_args()
    waves = [Path(w) if Path(w).is_absolute() else HERE / w for w in a.waves]
    missing = [w for w in waves if not (w / "inference.jsonl").exists()]
    if missing:
        raise SystemExit(f"waves without inference.jsonl: {missing}")
    out = Path(a.out) if Path(a.out).is_absolute() else HERE / "runs" / a.out
    doc = merge(waves, out, a.run_id, a.dataset_size)
    agg = doc["aggregate"]
    print(
        f"merged {len(waves)} wave(s) -> {out}\n"
        f"  {agg['instances_resolved']}/{agg['instances_attempted']} resolved "
        f"({(agg['resolve_rate'] or 0) * 100:.1f}%) pass@1"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
