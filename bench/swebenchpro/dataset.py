"""The SWE-bench Pro dataset, and the one derivation that must not be guessed.

## What this dataset is

`ScaleAI/SWE-bench_Pro`, split `test`, 731 instances over 11 repositories in 4
languages (go 280, python 266, js 165, ts 20). It is the *public* half of the
benchmark. Two properties make it worth the setup cost over SWE-bench Verified:

  * It is not saturated. Verified's own difficulty labels put 194 of its 500
    instances under 15 minutes of human work and only 3 over four hours, so it
    structurally cannot measure long-horizon behaviour. Pro's gold patches
    touch a median of 4 files and 7.8k characters (measured on this dataset,
    see `stats()`), against roughly one file on Verified.

  * The contamination control is a licensing argument rather than a secret.
    The public set is drawn from copyleft (GPL/AGPL) repositories, so a lab
    that trained on the solutions has a problem that is not ours to police;
    the held-out commercial set lives with Scale under commercial-use
    agreements and is not published at all. There is no gate and no token on
    the public half -- `ScaleAI/SWE-bench_Pro` is `gated=False`.

## The one thing to get right

The grader reverts a specific set of files before scoring. Guessing that set
from filenames is how the SWE-bench Verified runner in `bench/swebench` once
destroyed 19 of 500 gold patches (see `runners.test_patch_files`). Pro gives
us the grader's own command verbatim, so we read it instead of inferring it:
`graded_away_paths()`.
"""

from __future__ import annotations

import json
import re
import statistics
from pathlib import Path

#: The public split. There is no `validation`, and no other split.
DATASET = "ScaleAI/SWE-bench_Pro"
SPLIT = "test"

#: Docker Hub account holding the prebuilt per-instance images. Every instance
#: carries its own `dockerhub_tag`; `image_for()` only prefixes it. Verified
#: against `harness/helper_code/image_uri.get_dockerhub_image_uri` for all 731
#: rows -- the dataset column and the harness's computation agree exactly, so
#: reading the column is safe and avoids importing the harness here.
DOCKERHUB_USER = "jefzda"
DOCKERHUB_REPO = "sweap-images"


def load_rows(name: str = DATASET, split: str = SPLIT) -> list[dict]:
    """Rows as plain dicts. Accepts a local .json/.jsonl path for offline work."""
    if name.endswith(".json") or name.endswith(".jsonl"):
        return [
            json.loads(l) for l in Path(name).read_text().splitlines() if l.strip()
        ]
    from datasets import load_dataset

    return [dict(r) for r in load_dataset(name, split=split)]


def image_for(inst: dict, user: str = DOCKERHUB_USER) -> str:
    return f"{user}/{DOCKERHUB_REPO}:{inst['dockerhub_tag']}"


# ---------------------------------------------------------------------------
# The grader's revert list
# ---------------------------------------------------------------------------

#: The last line of `before_repo_set_cmd`, which the official grader executes
#: verbatim after applying our patch:
#:     git checkout <fix_commit> -- <path> [<path> ...]
_CHECKOUT_RE = re.compile(r"^git\s+checkout\s+([0-9a-f]{6,40})\s+--\s+(.+)$")

#: `diff --git a/<path> b/<path>`, for the cross-check only.
_DIFF_PATH_RE = re.compile(r"^diff --git a/.* b/(.*)$", re.MULTILINE)


class RevertListError(RuntimeError):
    """The grader's revert command was not in the shape we parse.

    Raised rather than defaulted, because every fallback here is a silent
    scoring bug: too few paths and the recorded patch contains edits the
    grader threw away, too many and we delete the agent's real work.
    """


def graded_away_paths(inst: dict) -> list[str]:
    """Exactly the files the official grader restores from the fix commit.

    This is the Pro analogue of `bench/swebench/runners.test_patch_files`, and
    it exists for the same reason: the set of files an agent cannot usefully
    edit must be *read from what the grader does*, never inferred from a path
    heuristic. On Verified, inferring it (`"test/" in path`) matched
    `src/_pytest/` and `django/test/client.py` and silently deleted 19 of 500
    gold patches, which was then charged to the agent as "produced no patch".

    Pro makes this easier than Verified did. `swe_bench_pro_eval.create_entryscript`
    builds the container's script as:

        git reset --hard <base_commit>
        git checkout <base_commit>
        git apply -v /workspace/patch.diff
        <last line of before_repo_set_cmd>      # <- git checkout <fix> -- <tests>
        bash run_script.sh <selected_test_files_to_run>

    so the revert list is not derived at all: it is the tail of a field the
    dataset ships. We parse that line and, as a standing cross-check, compare
    it with the file list of `test_patch`. Across all 731 public instances the
    two sets are identical, which is the evidence that neither derivation has
    drifted; a future instance where they disagree is reported through
    `revert_list_agrees()` rather than quietly resolved in favour of one.
    """
    last = (inst.get("before_repo_set_cmd") or "").strip().split("\n")[-1].strip()
    m = _CHECKOUT_RE.match(last)
    if not m:
        raise RevertListError(
            f"{inst.get('instance_id')}: before_repo_set_cmd does not end in a "
            f"`git checkout <sha> -- <paths>` line, so the grader's revert set "
            f"cannot be read. Last line was: {last!r}"
        )
    return sorted(set(m.group(2).split()))


def revert_list_agrees(inst: dict) -> bool:
    """Whether the grader's revert list matches the test_patch file list.

    True for all 731 public instances as of harness `main`. Recorded per run so
    that a dataset revision which breaks the invariant shows up on the report
    instead of shifting the score.
    """
    try:
        a = set(graded_away_paths(inst))
    except RevertListError:
        return False
    return a == set(_DIFF_PATH_RE.findall(inst.get("test_patch") or ""))


def selected_test_files(inst: dict) -> list[str]:
    """`selected_test_files_to_run`, the argument the grader passes run_script.sh.

    Stored as a Python-literal string in the dataset (the official harness uses
    `eval()` on it). We accept JSON first and fall back to `ast.literal_eval`,
    which handles the single-quoted rows without executing anything.
    """
    return _literal_list(inst.get("selected_test_files_to_run"))


def fail_to_pass(inst: dict) -> list[str]:
    return _literal_list(inst.get("fail_to_pass"))


def pass_to_pass(inst: dict) -> list[str]:
    return _literal_list(inst.get("pass_to_pass"))


def _literal_list(v) -> list[str]:
    if v is None or v == "":
        return []
    if isinstance(v, list):
        return [str(x) for x in v]
    try:
        return [str(x) for x in json.loads(v)]
    except (json.JSONDecodeError, TypeError):
        import ast

        try:
            parsed = ast.literal_eval(v)
        except (ValueError, SyntaxError):
            return []
        return [str(x) for x in parsed] if isinstance(parsed, (list, tuple)) else []


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------


def hardness(inst: dict) -> float:
    """A 0..1 weight used only to bias sampling. Never used for scoring.

    Pro ships no human effort estimate (Verified's `difficulty` column has no
    counterpart here), so the signals are all structural: how many files the
    gold fix touches, how big it is, how large the regression surface is, and
    how much specification the instance carries. The last one is deliberate --
    `requirements` and `interface` are the fields the published ablation shows
    the score is most sensitive to, so instances that lean on them are the ones
    that actually probe context construction.
    """
    patch = inst.get("patch") or ""
    files = min(patch.count("diff --git ") / 8.0, 1.0)
    size = min(len(patch) / 20000.0, 1.0)
    p2p = min(len(pass_to_pass(inst)) / 300.0, 1.0)
    spec = min((len(inst.get("requirements") or "") + len(inst.get("interface") or "")) / 8000.0, 1.0)
    return round(0.35 * files + 0.25 * size + 0.20 * p2p + 0.20 * spec, 4)


def stratified_sample(
    rows: list[dict], n: int, seed: int, bias_hard: bool
) -> tuple[list[dict], dict]:
    """`n` instances, apportioned across repos in the dataset's own proportions.

    Same shape as `bench/swebench/run_bench.stratified_sample`, and for the same
    reason: taking the first N rows is not a sample, and one repo dominating the
    draw makes the number a statement about that repo. Pro's repo mix is far
    flatter than Verified's (no repo exceeds 96/731, where django alone was
    231/500), but the language mix is not -- go and python are 75% of it -- so
    the apportionment is what keeps a small draw from being all Go.

    Returns (chosen, provenance); provenance is written verbatim into
    config.json so the subset can never be quoted without its qualification.
    """
    import random

    rng = random.Random(seed)
    by_repo: dict[str, list[dict]] = {}
    for r in rows:
        by_repo.setdefault(r["repo"], []).append(r)

    total = len(rows)
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
        if not bias_hard:
            chosen.extend(rng.sample(pool, want))
            continue
        weights = [(0.10 + hardness(r)) ** 2 for r in pool]
        for _ in range(want):
            tot = sum(weights)
            if tot <= 0:
                break
            x, acc = rng.random() * tot, 0.0
            for i, w in enumerate(weights):
                acc += w
                if acc >= x:
                    chosen.append(pool[i])
                    weights[i] = 0.0  # without replacement
                    break

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
            "0.35*min(files/8,1) + 0.25*min(len(patch)/20000,1) "
            "+ 0.20*min(len(pass_to_pass)/300,1) "
            "+ 0.20*min(len(requirements)+len(interface))/8000,1)"
        ),
        "mean_hardness_sample": round(statistics.mean(hs), 4) if hs else None,
        "mean_hardness_population": round(statistics.mean(all_hs), 4),
        "repo_mix_sample": _mix(chosen, "repo"),
        "repo_mix_population": _mix(rows, "repo"),
        "language_mix_sample": _mix(chosen, "repo_language"),
        "language_mix_population": _mix(rows, "repo_language"),
    }
    return chosen, provenance


def _mix(rows: list[dict], key: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for r in rows:
        out[str(r.get(key))] = out.get(str(r.get(key)), 0) + 1
    return dict(sorted(out.items(), key=lambda kv: -kv[1]))


def stats(rows: list[dict]) -> dict:
    """Descriptive numbers for the README and for sanity-checking a fresh pull."""
    files = [(r.get("patch") or "").count("diff --git ") for r in rows]
    sizes = [len(r.get("patch") or "") for r in rows]
    return {
        "instances": len(rows),
        "repos": _mix(rows, "repo"),
        "languages": _mix(rows, "repo_language"),
        "gold_patch_files_median": statistics.median(files),
        "gold_patch_files_mean": round(statistics.mean(files), 2),
        "gold_patch_chars_median": statistics.median(sizes),
        "with_requirements": sum(1 for r in rows if (r.get("requirements") or "").strip()),
        "with_interface": sum(1 for r in rows if (r.get("interface") or "").strip()),
        "revert_list_disagreements": [
            r["instance_id"] for r in rows if not revert_list_agrees(r)
        ],
    }


if __name__ == "__main__":  # pragma: no cover - operator convenience
    print(json.dumps(stats(load_rows()), indent=2))
