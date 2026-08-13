"""Failures as the primary output.

The pass rate is a scalar and tells you nothing about what to fix. The
distribution of *why* tasks failed, and a path to the transcript of each one,
is the actual deliverable of a benchmark run used as a diagnostic instrument.

Two ideas do the work here:

  ATTRIBUTION -- each failure is charged to a layer: harness, model, agent
  policy, or environment. Only the harness bucket is directly actionable by us,
  and separating it out is the difference between "we scored 40%" and "eleven
  of those losses were our compaction, go fix compaction".

  EVIDENCE -- every failed instance carries the on-disk paths a human needs to
  actually read what happened. A failure bucket without a transcript pointer
  is a statistic; with one it is a bug report.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from loader import Instance, Run

# Who is responsible for this failure, and therefore who can fix it.
HARNESS = "harness"  # our bug. Directly actionable.
AGENT = "agent"  # OSA's policy/loop: gave up, looped, edited too broadly.
MODEL = "model"  # the model simply could not do it.
ENVIRONMENT = "environment"  # docker, network, provider outage.
UNKNOWN = "unknown"

ACTIONABLE = {HARNESS, AGENT}


@dataclass(frozen=True)
class Bucket:
    code: str
    attribution: str
    label: str
    #: What this bucket usually means, and where to look first.
    diagnosis: str


BUCKETS: dict[str, Bucket] = {
    b.code: b
    for b in [
        Bucket(
            "agent_timeout",
            AGENT,
            "ran out of wall-clock",
            "The loop did not converge inside the budget. Look for repeated "
            "identical tool calls, a compaction that dropped the plan, or a "
            "test command that hangs. Compare turns against max_turns: hitting "
            "the turn cap and hitting the clock are different bugs.",
        ),
        Bucket(
            "no_patch_produced",
            AGENT,
            "finished without editing anything",
            "The most damning bucket. The agent believed it was done while the "
            "working tree was clean. Usual causes: edits written outside the "
            "workspace, a tool that failed silently, an approval that was "
            "refused, or the model answering in prose instead of calling a "
            "tool. Check the transcript for edit tool calls and their results.",
        ),
        Bucket(
            "regression_pass_to_pass_broke",
            AGENT,
            "fixed the issue but broke something else",
            "The edit was too broad, or a plausible-looking refactor changed "
            "behaviour. This is the bucket that improves most from letting the "
            "agent run the existing suite before finishing. Check whether the "
            "agent ran any tests at all.",
        ),
        Bucket(
            "fix_incomplete_fail_to_pass_still_failing",
            MODEL,
            "patch did not fix the issue",
            "Ordinary difficulty: the agent produced a coherent but wrong "
            "patch. Mostly model capability, but check whether it ever "
            "reproduced the bug -- agents that never reproduce fail here far "
            "more often, and that IS a harness-level policy we control.",
        ),
        Bucket(
            "patch_apply_or_eval_failed",
            HARNESS,
            "patch would not apply",
            "Our diff is malformed or was taken against the wrong base. Check "
            "git_diff() output, binary files, CRLF, and whether the workspace "
            "was reset to base_commit cleanly.",
        ),
        Bucket(
            "harness_error",
            HARNESS,
            "the runner itself failed",
            "Our bug. Read agent_error verbatim.",
        ),
        Bucket(
            "agent_error",
            AGENT,
            "the agent reported an error",
            "OSA raised. Read agent_error and the transcript tail.",
        ),
        Bucket(
            "eval_incomplete",
            ENVIRONMENT,
            "grading never finished",
            "Docker or timeout during evaluation. Not an agent result; re-run "
            "before counting it.",
        ),
        Bucket(
            "unresolved_unclassified",
            UNKNOWN,
            "unresolved, no reason recorded",
            "The grader produced no per-instance detail. Usually means the "
            "eval report.json was missing; check bench/swebench/runs/<id>/eval.",
        ),
    ]
}

_FALLBACK = Bucket(UNKNOWN, UNKNOWN, "unclassified", "No diagnosis available.")

#: bench/swebench/diagnose.py records a `failure_fault`; map its vocabulary
#: onto ours so a v2 run's buckets still sort into who-can-fix-it.
_FAULT_TO_ATTRIBUTION = {
    "harness": HARNESS,
    "osa": AGENT,
    "agent": AGENT,
    "model": MODEL,
    "env": ENVIRONMENT,
    "environment": ENVIRONMENT,
    "infra": ENVIRONMENT,
    "unknown": UNKNOWN,
}


def bucket_for(reason: str) -> Bucket:
    return BUCKETS.get(reason, _FALLBACK)


# ---------------------------------------------------------------------------
# Evidence
# ---------------------------------------------------------------------------


def osa_home() -> Path:
    return Path(os.environ.get("OSA_HOME") or (Path.home() / ".osa"))


@dataclass
class Evidence:
    """Where a human goes to read what actually happened."""

    instance_id: str
    session_id: str | None
    transcript: Path | None = None
    updates: Path | None = None
    goal: Path | None = None
    spend: Path | None = None
    eval_log_dir: Path | None = None
    run_log_dir: Path | None = None
    missing: list[str] = field(default_factory=list)

    def to_json(self) -> dict:
        d = {"instance_id": self.instance_id, "session_id": self.session_id}
        for name in ("transcript", "updates", "goal", "spend", "eval_log_dir", "run_log_dir"):
            p = getattr(self, name)
            if p is not None:
                d[name] = str(p)
        if self.missing:
            d["missing"] = self.missing
        return d


def collect_evidence(inst: "Instance", run: "Run") -> Evidence:
    """Resolve every on-disk artefact for one instance attempt."""
    ev = Evidence(instance_id=inst.instance_id, session_id=inst.session_id)
    run_dir = run.path.parent

    # schema v2 records these directly; prefer them over reconstruction.
    if inst.transcript_dir and Path(inst.transcript_dir).exists():
        ev.transcript = Path(inst.transcript_dir)
    if inst.event_log and Path(inst.event_log).exists():
        ev.updates = Path(inst.event_log)

    if ev.transcript is None and inst.session_id:
        sdir = osa_home() / "sessions"
        candidates = {
            "transcript": sdir / f"{inst.session_id}.json",
            "updates": sdir / f"{inst.session_id}.updates.jsonl",
            "goal": sdir / f"{inst.session_id}.goal.json",
            "spend": sdir / f"{inst.session_id}.spend.json",
        }
        for name, p in candidates.items():
            if p.exists():
                setattr(ev, name, p)
            elif name in ("transcript", "updates"):
                ev.missing.append(str(p))
    elif ev.transcript is None:
        ev.missing.append("no session_id recorded; no transcript is recoverable")

    model_dir = (run.config.get("model") or "").replace("/", "__")
    eval_log = (
        run_dir / "eval" / "logs" / "run_evaluation" / run.run_id / model_dir / inst.instance_id
    )
    if eval_log.is_dir():
        ev.eval_log_dir = eval_log
    else:
        ev.missing.append(str(eval_log))

    if (run_dir / "logs").is_dir():
        ev.run_log_dir = run_dir / "logs"
    return ev


@dataclass
class Failure:
    instance: "Instance"
    bucket: Bucket
    evidence: Evidence

    @property
    def summary(self) -> str:
        i = self.instance
        bits = [f"{i.instance_id}: {self.bucket.label}"]
        if i.agent_error:
            bits.append(f"error={i.agent_error[:160]}")
        if i.fail_to_pass_failing:
            bits.append(f"{len(i.fail_to_pass_failing)} F2P still failing")
        if i.pass_to_pass_failing:
            bits.append(f"{len(i.pass_to_pass_failing)} P2P broken")
        return " | ".join(bits)

    def to_json(self) -> dict:
        i = self.instance
        return {
            "instance_id": i.instance_id,
            "repo": i.repo,
            "bucket": self.bucket.code,
            "attribution": self.bucket.attribution,
            "label": self.bucket.label,
            "outcome": i.outcome,
            "agent_status": i.agent_status,
            "agent_error": i.agent_error,
            "wall_clock_s": i.wall_clock_s,
            "turns": i.turns,
            "tool_calls": i.tool_calls,
            "tokens_total": i.tokens_total,
            "patch_bytes": i.patch_bytes,
            "fail_to_pass_failing": i.fail_to_pass_failing[:20],
            "pass_to_pass_failing": i.pass_to_pass_failing[:20],
            "evidence": self.evidence.to_json(),
        }


@dataclass
class FailureAnalysis:
    failures: list[Failure]
    by_bucket: dict[str, int]
    by_attribution: dict[str, int]
    by_repo: dict[str, int]
    leads: list[str]
    transcripts_missing: int
    #: The Bucket object actually used for each code seen in this run.
    #: `bucket_for(code)` only knows the static registry, so a schema-v2 code
    #: like `model_fix_incomplete_fail_to_pass_still_failing` renders as
    #: "unknown / unclassified" through it even though `analyse()` built a
    #: perfectly good Bucket for it. Callers should look here first.
    bucket_objects: dict[str, "Bucket"] = field(default_factory=dict)

    def bucket(self, code: str) -> "Bucket":
        return self.bucket_objects.get(code) or bucket_for(code)

    def to_json(self) -> dict:
        return {
            "total_failures": len(self.failures),
            "by_bucket": self.by_bucket,
            "by_attribution": self.by_attribution,
            "by_repo": self.by_repo,
            "transcripts_missing": self.transcripts_missing,
            "diagnostic_leads": self.leads,
            "failures": [f.to_json() for f in self.failures],
        }


def _leads(failures: list[Failure], run: "Run") -> list[str]:
    """Aggregate patterns worth acting on, stated as instructions."""
    out: list[str] = []
    n = run.n
    if not failures:
        return out
    counts: dict[str, int] = {}
    for f in failures:
        counts[f.bucket.code] = counts.get(f.bucket.code, 0) + 1

    def frac(code: str) -> float:
        return counts.get(code, 0) / n if n else 0.0

    if frac("agent_timeout") >= 0.15:
        out.append(
            f"{counts['agent_timeout']}/{n} tasks hit the wall-clock budget. "
            f"Before raising agent_timeout_s, check turns against max_turns "
            f"({run.config.get('max_turns')}): if turns are far below the cap, "
            f"individual tool calls are slow, not the loop."
        )
    if frac("no_patch_produced") >= 0.10:
        out.append(
            f"{counts['no_patch_produced']}/{n} tasks ended with a clean working "
            f"tree. That is a harness-shaped failure, not a model one -- read "
            f"the transcripts for edit calls whose results were errors."
        )
    if frac("regression_pass_to_pass_broke") >= 0.10:
        out.append(
            f"{counts['regression_pass_to_pass_broke']}/{n} tasks broke existing "
            f"tests. Check how many of those transcripts contain any test run "
            f"at all; if few do, the fix is a policy change (run the suite "
            f"before finishing), not a model upgrade."
        )
    if counts.get("patch_apply_or_eval_failed") or counts.get("harness_error"):
        out.append(
            "Some losses are ours outright (patch would not apply / runner "
            "error). Fix these before reading the rate at all -- they are not "
            "measurements of anything."
        )
    long_runs = [f for f in failures if f.instance.wall_clock_s > 900]
    if len(long_runs) >= 3:
        out.append(
            f"{len(long_runs)} failures ran over 15 minutes. Long failing runs "
            f"are the best material for context-compaction bugs: check whether "
            f"the plan survived compaction in those transcripts."
        )
    zero_tools = [f for f in failures if (f.instance.tool_calls or 0) == 0]
    if zero_tools:
        out.append(
            f"{len(zero_tools)} failures made ZERO tool calls "
            f"({', '.join(f.instance.instance_id for f in zero_tools[:5])}). "
            f"The agent never started. Suspect prompt delivery, permission "
            f"mode, or provider errors rather than task difficulty."
        )
    return out


def analyse(run: "Run") -> FailureAnalysis:
    failures: list[Failure] = []
    for inst in run.instances:
        if inst.counted_resolved:
            continue
        b = bucket_for(inst.failure_reason)
        # schema v2 ships bench/swebench's own classification. Prefer it, but
        # keep our attribution vocabulary so the report stays coherent, and
        # keep our diagnosis text, which theirs does not carry.
        if inst.failure_bucket and inst.failure_bucket != b.code:
            known = BUCKETS.get(inst.failure_bucket)
            b = known or Bucket(
                code=inst.failure_bucket,
                attribution=_FAULT_TO_ATTRIBUTION.get(
                    (inst.failure_fault or "").lower(), UNKNOWN
                ),
                label=inst.failure_bucket.replace("_", " "),
                diagnosis=(
                    "Classified by bench/swebench/diagnose.py"
                    + (f" as fault={inst.failure_fault}." if inst.failure_fault else ".")
                    + " See failure_evidence in results.json."
                ),
            )
        failures.append(Failure(inst, b, collect_evidence(inst, run)))

    failures.sort(key=lambda f: (f.bucket.attribution, f.bucket.code, f.instance.instance_id))

    by_bucket: dict[str, int] = {}
    by_attr: dict[str, int] = {}
    by_repo: dict[str, int] = {}
    for f in failures:
        by_bucket[f.bucket.code] = by_bucket.get(f.bucket.code, 0) + 1
        by_attr[f.bucket.attribution] = by_attr.get(f.bucket.attribution, 0) + 1
        by_repo[f.instance.repo] = by_repo.get(f.instance.repo, 0) + 1

    missing = sum(1 for f in failures if f.evidence.transcript is None)

    return FailureAnalysis(
        failures=failures,
        by_bucket=dict(sorted(by_bucket.items(), key=lambda kv: -kv[1])),
        by_attribution=dict(sorted(by_attr.items(), key=lambda kv: -kv[1])),
        by_repo=dict(sorted(by_repo.items(), key=lambda kv: -kv[1])),
        leads=_leads(failures, run),
        transcripts_missing=missing,
        bucket_objects={f.bucket.code: f.bucket for f in failures},
    )
