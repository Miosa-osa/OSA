"""Read the run artefacts produced by bench/swebench. Read-only, always.

The schema is owned by `bench/swebench/report.py` (SCHEMA_VERSION = 1). This
module treats it as a foreign contract: it validates what it depends on, warns
loudly when it sees a version it was not written against, and never writes back.

If bench/swebench bumps its schema, `SUPPORTED_SCHEMA` here is the one line to
change -- after re-reading their report.py, not instead of it.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

#: v1: the original flat schema.
#: v2: adds per-instance failure_bucket/failure_fault/failure_evidence,
#:     osa_signals, transcript_dir/event_log, dropped_test_paths, and
#:     multi-attempt (pass@k) aggregates plus a sampling provenance block.
SUPPORTED_SCHEMA = {1, 2}

#: Instance outcomes that mean "the agent was given a fair chance and failed".
#: Everything else is an infrastructure event and must not be scored as an
#: agent failure -- see `Run.infra_failures`.
AGENT_FAILURE_OUTCOMES = {"unresolved", "empty_patch"}
INFRA_FAILURE_OUTCOMES = {"eval_error", "incomplete"}

#: failure_reason values that indicate the harness, not the agent, lost the task.
INFRA_FAILURE_REASONS = {
    "harness_error",
    "patch_apply_or_eval_failed",
    "eval_incomplete",
}


class SchemaError(RuntimeError):
    pass


@dataclass
class Instance:
    """One task attempt, as recorded by bench/swebench."""

    instance_id: str
    resolved: bool
    outcome: str
    failure_reason: str
    wall_clock_s: float
    tokens_in: int | None
    tokens_out: int | None
    tokens_cache_read: int | None
    tokens_cache_write: int | None
    cost_usd: float | None
    tool_calls: int | None
    turns: int | None
    patch_bytes: int
    agent_status: str | None
    agent_error: str | None
    model: str | None
    session_id: str | None
    fail_to_pass_failing: list[str] = field(default_factory=list)
    pass_to_pass_failing: list[str] = field(default_factory=list)
    # -- schema v2 --------------------------------------------------------
    #: bench/swebench's own bucket/fault classification (diagnose.py). We
    #: prefer it over our own when present; ours remains the fallback so a v1
    #: results.json still reports.
    failure_bucket: str | None = None
    failure_fault: str | None = None
    failure_evidence: Any = None
    osa_signals: dict = field(default_factory=dict)
    transcript_dir: str | None = None
    event_log: str | None = None
    #: Paths git_diff() removed from the patch as "tests". A non-test source
    #: file appearing here is the _is_test_path defect firing.
    dropped_test_paths: list[str] = field(default_factory=list)
    attempts_n: int = 1
    resolved_any: bool | None = None
    resolved_all: bool | None = None
    per_attempt: list[dict] = field(default_factory=list)
    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def tokens_total(self) -> int | None:
        if self.tokens_in is None or self.tokens_out is None:
            return None
        return self.tokens_in + self.tokens_out

    @property
    def is_infra_failure(self) -> bool:
        return (
            self.outcome in INFRA_FAILURE_OUTCOMES
            or self.failure_reason in INFRA_FAILURE_REASONS
        )

    @property
    def repo(self) -> str:
        """django__django-12345 -> django/django."""
        head = self.instance_id.rsplit("-", 1)[0]
        return head.replace("__", "/", 1) if "__" in head else head

    @classmethod
    def from_json(cls, d: dict) -> "Instance":
        known = {f for f in cls.__dataclass_fields__ if f != "raw"}
        return cls(
            raw={k: v for k, v in d.items() if k not in known},
            **{
                "instance_id": d["instance_id"],
                "resolved": bool(d.get("resolved")),
                "outcome": d.get("outcome", "unknown"),
                "failure_reason": d.get("failure_reason", "") or "",
                "wall_clock_s": float(d.get("wall_clock_s") or 0.0),
                "tokens_in": d.get("tokens_in"),
                "tokens_out": d.get("tokens_out"),
                "tokens_cache_read": d.get("tokens_cache_read"),
                "tokens_cache_write": d.get("tokens_cache_write"),
                "cost_usd": d.get("cost_usd"),
                "tool_calls": d.get("tool_calls"),
                "turns": d.get("turns"),
                "patch_bytes": int(d.get("patch_bytes") or 0),
                "agent_status": d.get("agent_status"),
                "agent_error": d.get("agent_error"),
                "model": d.get("model"),
                "session_id": d.get("session_id"),
                "fail_to_pass_failing": list(d.get("fail_to_pass_failing") or []),
                "pass_to_pass_failing": list(d.get("pass_to_pass_failing") or []),
                "failure_bucket": d.get("failure_bucket"),
                "failure_fault": d.get("failure_fault"),
                "failure_evidence": d.get("failure_evidence"),
                "osa_signals": d.get("osa_signals") or {},
                "transcript_dir": d.get("transcript_dir"),
                "event_log": d.get("event_log"),
                "dropped_test_paths": list(d.get("dropped_test_paths") or []),
                "attempts_n": int(d.get("attempts_n") or 1),
                "resolved_any": d.get("resolved_any"),
                "resolved_all": d.get("resolved_all"),
                "per_attempt": list(d.get("per_attempt") or []),
            },
        )

    @property
    def counted_resolved(self) -> bool:
        """How bench/swebench counts this row in `instances_resolved`.

        On a multi-attempt run that is `resolved_any` -- i.e. pass@k, which the
        official leaderboard forbids as a reported score. honesty.py gates on
        it; this property just tells the truth about what was counted.
        """
        return bool(self.resolved_any) if self.attempts_n > 1 else self.resolved


@dataclass
class Run:
    """One results.json."""

    path: Path
    config: dict
    aggregate: dict
    harness_report: dict
    instances: list[Instance]
    schema_version: int

    # -- identity ----------------------------------------------------------
    @property
    def run_id(self) -> str:
        return self.config.get("run_id", self.path.parent.name)

    @property
    def runner(self) -> str:
        return self.config.get("runner", "unknown")

    @property
    def model(self) -> str:
        models = {i.model for i in self.instances if i.model}
        if len(models) == 1:
            return next(iter(models))
        if len(models) > 1:
            # A run that changed model halfway is not one measurement.
            return "MIXED:" + ",".join(sorted(models))
        return self.config.get("model") or "unknown"

    @property
    def dataset(self) -> str:
        return self.config.get("dataset_name", "unknown")

    @property
    def dataset_size(self) -> int | None:
        return self.config.get("dataset_size")

    # -- counts ------------------------------------------------------------
    @property
    def n(self) -> int:
        return len(self.instances)

    @property
    def attempts(self) -> int:
        """Attempts per instance. >1 means the headline count is pass@k."""
        return int(
            self.config.get("attempts") or self.aggregate.get("attempts") or 1
        )

    @property
    def k(self) -> int:
        """Resolved count as bench/swebench counts it.

        On a multi-attempt run this is pass@k (resolved on ANY attempt), which
        matches their `instances_resolved`. It is deliberately NOT silently
        converted to pass@1 -- honesty.py blocks quoting it instead.
        """
        return sum(1 for i in self.instances if i.counted_resolved)

    @property
    def k_pass1_mean(self) -> float | None:
        """Mean per-attempt resolved count -- the pass@1 estimate."""
        r = self.aggregate.get("pass_at_1")
        return r * self.n if r is not None and self.n else None

    @property
    def k_all(self) -> int | None:
        """Resolved on EVERY attempt (pass^k) -- the reliability figure."""
        if self.attempts <= 1:
            return None
        return sum(1 for i in self.instances if i.resolved_all)

    @property
    def dropped_source_paths(self) -> dict[str, list[str]]:
        """Instances where the test-path filter removed a non-test source file.

        `src/_pytest/...` and `django/test/...` are source. Anything here was
        silently deleted from the graded patch.
        """
        out: dict[str, list[str]] = {}
        for i in self.instances:
            bad = [
                p
                for p in i.dropped_test_paths
                if "/_pytest/" in p or p.startswith("django/test/")
            ]
            if bad:
                out[i.instance_id] = bad
        return out

    @property
    def infra_failures(self) -> list[Instance]:
        return [i for i in self.instances if i.is_infra_failure]

    @property
    def n_scorable(self) -> int:
        """n excluding instances the harness itself lost.

        Reported alongside, never instead of, `n`. Dropping infra failures
        from the denominator is how a flaky harness quietly inflates a rate,
        so both numbers always travel together.
        """
        return self.n - len(self.infra_failures)

    @property
    def is_full_dataset(self) -> bool:
        return self.dataset_size is not None and self.n == self.dataset_size

    # -- selection provenance ----------------------------------------------
    @property
    def sampling(self) -> dict:
        """`config.sampling` — schema v2's selection provenance block.

        Written by `run_bench.stratified_sample()` and carrying the seed, the
        weighting formula, and the resulting repo/difficulty mix next to the
        population's. Empty when the instances came from `--instances`,
        `--instance-ids` or `--limit`, in which case selection really is
        undeclared.
        """
        s = self.config.get("sampling")
        return s if isinstance(s, dict) else {}

    @property
    def declared_seed(self) -> int | None:
        """The seed the sample was actually drawn with, per the run's own record.

        Read from the artefact rather than from a CLI flag: a reporter that
        only believes `--seed` fires "selection is not a declared random
        sample" against a run whose full provenance is on disk, which teaches
        readers to ignore the finding.
        """
        v = self.sampling.get("seed")
        return v if isinstance(v, int) else None

    @property
    def sample_is_hard_weighted(self) -> bool:
        return bool(self.sampling.get("hard_weighted"))

    @property
    def airgap(self) -> dict:
        """`config.airgap` — the probe attestation, if the run installed one.

        `bench/swebench/airgap.py` writes this only after observing a live
        backend refuse a denied tool. Absent means no airgap; present with
        `enforced: false` means one was requested and did not work, which is
        worse than not trying and is reported as such.
        """
        a = self.config.get("airgap")
        return a if isinstance(a, dict) else {}

    @property
    def network_tool_use(self) -> dict:
        n = self.aggregate.get("network_tool_use")
        return n if isinstance(n, dict) else {}

    @property
    def instance_ids(self) -> list[str]:
        return [i.instance_id for i in self.instances]

    @property
    def id_set(self) -> frozenset[str]:
        return frozenset(self.instance_ids)

    # -- sums --------------------------------------------------------------
    def _sum(self, attr: str) -> tuple[int | float | None, int]:
        """Sum a field; also return how many instances were missing it.

        The missing count is the point. A token total built from 3 of 40
        instances is not a token total.
        """
        vals = [getattr(i, attr) for i in self.instances]
        present = [v for v in vals if v is not None]
        missing = len(vals) - len(present)
        return (sum(present) if present else None), missing

    @classmethod
    def load(cls, path: Path) -> "Run":
        path = Path(path)
        if path.is_dir():
            path = path / "results.json"
        try:
            doc = json.loads(path.read_text())
        except FileNotFoundError:
            raise SchemaError(f"no results.json at {path}") from None
        except json.JSONDecodeError as e:
            raise SchemaError(f"{path} is not valid JSON: {e}") from None

        sv = doc.get("schema_version")
        if sv not in SUPPORTED_SCHEMA:
            raise SchemaError(
                f"{path}: schema_version {sv!r}, this reporter understands "
                f"{sorted(SUPPORTED_SCHEMA)}. Re-read bench/swebench/report.py "
                f"before widening SUPPORTED_SCHEMA."
            )
        for key in ("config", "aggregate", "instances"):
            if key not in doc:
                raise SchemaError(f"{path}: missing required key {key!r}")

        return cls(
            path=path,
            config=doc["config"],
            aggregate=doc["aggregate"],
            harness_report=doc.get("harness_report", {}),
            instances=[Instance.from_json(d) for d in doc["instances"]],
            schema_version=sv,
        )


def discover(root: Path) -> list[Path]:
    """Find every results.json under a runs/ directory."""
    root = Path(root)
    if root.is_file():
        return [root]
    return sorted(root.glob("*/results.json")) + sorted(root.glob("results.json"))


def load_all(paths: Iterable[Path]) -> list[Run]:
    runs: list[Run] = []
    for p in paths:
        runs.append(Run.load(Path(p)))
    return runs
