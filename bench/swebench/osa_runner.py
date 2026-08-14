"""Drive OSA headlessly, one SWE-bench instance per session.

Two transports, both real entry points that already exist in OSA:

  http (default)
      `osa serve` / `mix osa.serve` exposes the headless backend. We open the
      SSE stream *first* (otherwise the terminal `done` frame can be missed),
      then POST /api/v1/orchestrate. This transport is the one that gives us
      real telemetry: `cost_update` frames carry the full usage breakdown and
      `tool_call` frames let us count tool invocations.
      Entry points: channels/http/api/orchestrate_routes.ex,
      channels/http/api/agent_routes.ex.

  cli
      `mix osa.run --format stream-json` — genuinely synchronous, no daemon,
      but it emits no usage frames, so token/cost numbers come only from the
      on-disk spend sidecar. Source checkouts only (Mix tasks are not in the
      release).
      Entry point: lib/mix/tasks/osa.run.ex.

Both read `~/.osa/sessions/<id>.spend.json` afterwards as the authoritative
cross-check on tokens and cost.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path
from queue import Empty, Queue

import requests

from runners import RunResult, Task, git_diff

# The prompt is deliberately plain. SWE-bench measures the harness+model, and a
# heavily tuned prompt measures the prompt instead; anything clever here should
# be moved into OSA itself where it benefits real users too.
PROMPT = """\
You are working in a checkout of the `{repo}` repository at commit {base_commit}.
The working directory is already set to the repository root.

Resolve the following issue reported against this repository:

<issue>
{problem_statement}
</issue>

Requirements:
- Edit the source files in this repository so the issue is fixed.
- Do NOT modify or add any test files. The graders use their own tests, and any
  changes you make under tests/ will be discarded.
- Do not create new git commits, branches, or stashes. Leave your work as
  uncommitted changes in the working tree.
- Make the smallest change that correctly fixes the root cause.
{test_hint}
When you are done, briefly state which files you changed and why.
"""

TEST_HINT = """\
- You can run the project's own test suite against your edits with
  `./run_tests.sh <test paths>` from the repository root. Use it to check your
  work.

"""


# --- cost: prefer the whole agent tree --------------------------------------
#
# Subagent/fleet children bill to their OWN spend sidecars. `cost_usd` is the
# parent session's figure alone, so any delegating run under-reports -- and
# $/task is the published headline. The Elixir side now carries `tree_cost_usd`
# (parent + descendants) and `tree_cost_complete` on the sidecar, on
# Loop.get_state's :spend map and on the :cost_update event.
#
# Read-side preference ONLY. The sidecar's own `cost_usd` field must not be
# rewritten with a tree total: `tree_spend/1` sums that field across
# descendants, so a tree total stored there makes every ancestor double-count
# its grandchildren.


def _tree_cost(primary: dict, fallback: dict, session_key: str = "cost_usd"):
    """tree_cost_usd if present, else the parent-only figure. Never summed."""
    for src, key in ((primary, "tree_cost_usd"), (primary, session_key),
                     (fallback, "tree_cost_usd"), (fallback, "cost_usd")):
        v = (src or {}).get(key)
        if v is not None:
            return v
    return None


def _cost_complete(primary: dict, fallback: dict) -> bool | None:
    """False => the cost is a LOWER BOUND. None => pre-field run, unknowable."""
    for src in (primary, fallback):
        v = (src or {}).get("tree_cost_complete")
        if v is not None:
            return bool(v)
        if (src or {}).get("cost_complete") is not None:
            return bool(src["cost_complete"])
    # No tree figure at all: the number is the parent alone. It is not "complete"
    # in the tree sense and must not be presented as if it were.
    if (primary or {}).get("tree_cost_usd") is None and (fallback or {}).get(
        "tree_cost_usd"
    ) is None:
        return None
    return True


# --- turn-error attribution ------------------------------------------------
#
# OSA emits `turn_error` on the agent_response/cost_update frame when a turn
# ended on an error instead of an answer. Four OSA-internal fault kinds
# (encoding faults, :request_shape -- "This is a bug in OSA" -- :tool_use_mismatch
# and :duplicate_tool_use) used to be emitted as `kind: :llm_error`; they are
# now stamped with an additive `owner` field.
#
# `unknown` is deliberately its own status rather than being folded into
# `provider` or into plain "ok": an unattributed fault counted as the model's is
# exactly the bias being removed here, and older runs carry no `owner` at all.
_OWNER_STATUS = {
    "osa": "osa_internal_error",
    "provider": "provider_error",
    "unknown": "turn_error_unattributed",
}


def _turn_error_owner(turn_error) -> str:
    """`osa` | `provider` | `unknown` from an additive, possibly absent field."""
    if isinstance(turn_error, dict):
        owner = turn_error.get("owner")
        if isinstance(owner, str) and owner.lstrip(":") in ("osa", "provider"):
            return owner.lstrip(":")
    return "unknown"


def _sanitize(sid: str) -> str:
    return re.sub(r"[^A-Za-z0-9_\-]", "_", sid)


def _osa_home() -> Path:
    return Path(os.environ.get("OSA_HOME") or (Path.home() / ".osa"))


def read_spend(session_id: str) -> dict:
    """Read `~/.osa/sessions/<id>.spend.json`.

    Returns {} when absent. Note that a present sidecar with cost_usd == 0 and
    non-zero tokens is legitimate -- subscription and local providers have no
    per-token price. Absent is "unknown"; zero is "no bill".
    """
    p = _osa_home() / "sessions" / f"{_sanitize(session_id)}.spend.json"
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def clear_session_files(session_id: str, archive_to: Path | None = None) -> None:
    """Reset this session's on-disk state, ARCHIVING it rather than deleting it.

    The reset itself is required: OSA's spend sidecar is cumulative and never
    reset for a session id, so without this a re-run reports the sum of both
    runs' tokens.

    But the previous implementation `unlink()`ed the transcript, and the
    transcript is the primary diagnostic artefact this whole exercise exists to
    produce. Re-running the same run-id -- exactly what you do when you are
    chasing a failure -- destroyed the evidence of the failure you were
    chasing. So the old files are moved aside into the run directory first, and
    only then removed from OSA's session store.
    """
    sdir = _osa_home() / "sessions"
    if not sdir.is_dir():
        return
    stem = _sanitize(session_id)
    dest = None
    if archive_to is not None:
        dest = archive_to / "_superseded" / stem
    for p in sdir.glob(f"{stem}.*"):
        try:
            if dest is not None:
                dest.mkdir(parents=True, exist_ok=True)
                shutil.copy2(p, dest / p.name)
        except OSError:
            pass
        try:
            p.unlink()
        except OSError:
            pass


#: Substrings that mark a tool result OSA truncated or spilled to a sidecar
#: file rather than handing the model the whole thing. If the model then fails,
#: it may have failed on a partial observation -- an OSA problem, not a model
#: problem, and the distinction is the reason this collector exists.
TRUNCATION_MARKERS = (
    "[truncated",
    "... (truncated",
    "output truncated",
    "result truncated",
    "/.osa/tool-results/",
)

#: A quiet stretch this long with no frame at all is worth flagging: several
#: long-run ceilings (a 10-minute per-tool wrapper, a 5-minute orchestrator
#: deadline, a stall detector) were only just removed, and a run that dies in a
#: silent phase looks exactly like this from outside.
STALL_SECONDS = 120.0


class _SignalCollector:
    """Mine the SSE stream for signs that OSA, not the model, was the problem.

    Everything here is descriptive. It records what happened; deciding whether
    a given failure was OSA's fault is `diagnose.py`'s job, so that the rule
    can be changed without re-running the benchmark.
    """

    def __init__(self) -> None:
        self.tool_failures = 0
        self.tool_failure_names: dict[str, int] = {}
        self.tool_names: dict[str, int] = {}
        self.truncated_results = 0
        self.compactions = 0
        self.max_utilization = 0.0
        self.max_estimated_tokens = 0
        self.context_window_reported = None
        self.hit_blocking_limit = False
        self.above_compact = False
        self.errors: list[str] = []
        self.slowest_tool_ms = 0
        self.max_gap_s = 0.0
        self.last_agent_response = ""
        self.turn_recap: dict = {}
        self._last_t = time.monotonic()
        self._t0 = self._last_t

    def observe(self, ev: dict) -> None:
        now = time.monotonic()
        gap = now - self._last_t
        if gap > self.max_gap_s:
            self.max_gap_s = gap
        self._last_t = now

        etype = ev.get("type") or ev.get("_event")

        if etype == "tool_call":
            name = ev.get("name") or "?"
            if ev.get("phase") == "start":
                self.tool_names[name] = self.tool_names.get(name, 0) + 1
            elif ev.get("phase") == "end":
                ms = ev.get("duration_ms")
                if isinstance(ms, int):
                    self.slowest_tool_ms = max(self.slowest_tool_ms, ms)
                if ev.get("success") is False:
                    self.tool_failures += 1
                    self.tool_failure_names[name] = (
                        self.tool_failure_names.get(name, 0) + 1
                    )
        elif etype == "tool_result":
            body = ev.get("result")
            if isinstance(body, str) and any(
                m in body[:4000] or m in body[-2000:] for m in TRUNCATION_MARKERS
            ):
                self.truncated_results += 1
            if ev.get("success") is False:
                err = str(ev.get("error") or body or "")[:300]
                if err:
                    self.errors.append(f"tool_result: {err}")
        elif etype == "context_pressure":
            u = ev.get("utilization")
            if isinstance(u, (int, float)):
                self.max_utilization = max(self.max_utilization, float(u))
            est = ev.get("estimated_tokens")
            if isinstance(est, int):
                self.max_estimated_tokens = max(self.max_estimated_tokens, est)
            mt = ev.get("max_tokens")
            if isinstance(mt, int):
                # Keep the LAST reading; 0 means OSA could not resolve the
                # window at all, which disables its own compaction thresholds.
                self.context_window_reported = mt
            self.hit_blocking_limit |= bool(ev.get("at_blocking_limit"))
            self.above_compact |= bool(ev.get("above_compact"))
        elif etype == "system_event":
            sub = str(ev.get("event") or "")
            if "compact" in sub:
                self.compactions += 1
            if sub in ("error", "agent_error") or ev.get("outcome") == "error":
                self.errors.append(f"{sub}: {str(ev.get('message') or ev)[:300]}")
        elif etype in ("error", "agent_error"):
            self.errors.append(str(ev.get("message") or ev.get("error") or ev)[:300])
        elif etype == "agent_response":
            r = ev.get("response")
            if isinstance(r, str):
                self.last_agent_response = r
        elif etype == "turn_recap":
            self.turn_recap = {
                k: ev.get(k) for k in ("tool_calls", "tools_used", "elapsed_ms")
            }

    def finish(self) -> dict:
        return {
            "tool_failures": self.tool_failures,
            "tool_failure_names": dict(
                sorted(self.tool_failure_names.items(), key=lambda kv: -kv[1])
            ),
            "tool_names": dict(sorted(self.tool_names.items(), key=lambda kv: -kv[1])),
            "truncated_results": self.truncated_results,
            "compactions": self.compactions,
            "max_utilization": round(self.max_utilization, 2),
            "max_estimated_tokens": self.max_estimated_tokens,
            "context_window_reported": self.context_window_reported,
            "hit_blocking_limit": self.hit_blocking_limit,
            "above_compact": self.above_compact,
            "slowest_tool_ms": self.slowest_tool_ms,
            "max_event_gap_s": round(self.max_gap_s, 1),
            "stalled": self.max_gap_s >= STALL_SECONDS,
            "errors": self.errors[:20],
            "error_count": len(self.errors),
            "turn_recap": self.turn_recap,
            # The final message is often the only place the agent says it gave
            # up, or that a tool it needed never worked.
            "final_message_tail": self.last_agent_response[-1200:],
        }


def _free_port() -> int:
    """An ephemeral port the OS says is free right now."""
    import socket

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


_PERMISSION_LOCK = threading.Lock()


def seed_permission_mode(session_id: str, mode: str = "overdrive") -> None:
    """Pre-set a session's sticky permission mode in `~/.osa/permission_mode.json`.

    Needed only by the CLI transport, which starts a fresh BEAM per task and so
    has no live process to send a `permission_mode` command to. OSA rehydrates
    its ETS table from this file on first use, so writing the entry first has
    the same effect.

    Read-modify-write under a lock because instances run concurrently, and this
    file is shared with the user's real daemon -- clobbering it would change
    permission behaviour outside the benchmark.
    """
    p = _osa_home() / "permission_mode.json"
    with _PERMISSION_LOCK:
        try:
            data = json.loads(p.read_text()) if p.exists() else {}
            if not isinstance(data, dict):
                data = {}
        except (json.JSONDecodeError, OSError):
            return
        data[_sanitize(session_id)] = mode
        try:
            tmp = p.with_suffix(".json.bench-tmp")
            tmp.write_text(json.dumps(data))
            tmp.replace(p)
        except OSError:
            pass


def unseed_permission_modes(prefix: str) -> int:
    """Drop this run's entries from the shared sticky-permission store.

    The store has no eviction, so a benchmark that left its entries behind
    would grow the user's real permission file by one row per instance, for
    ever. Cleaning up is the harness's job, not OSA's.
    """
    p = _osa_home() / "permission_mode.json"
    with _PERMISSION_LOCK:
        try:
            data = json.loads(p.read_text()) if p.exists() else {}
            if not isinstance(data, dict):
                return 0
        except (json.JSONDecodeError, OSError):
            return 0
        drop = [k for k in data if k.startswith(prefix)]
        if not drop:
            return 0
        for k in drop:
            data.pop(k, None)
        try:
            tmp = p.with_suffix(".json.bench-tmp")
            tmp.write_text(json.dumps(data))
            tmp.replace(p)
        except OSError:
            return 0
        return len(drop)


class OsaRunner:
    name = "osa"

    def __init__(
        self,
        *,
        mode: str = "http",
        base_url: str = "http://127.0.0.1:19801",
        auth_token: str | None = None,
        model: str | None = None,
        provider: str | None = None,
        max_turns: int = 60,
        max_budget_usd: float | None = None,
        timeout_s: int = 1800,
        repo_root: Path | None = None,
        log_dir: Path | None = None,
        with_test_bridge: bool = True,
        run_id: str = "adhoc",
        transcript_dir: Path | None = None,
    ):
        if mode not in ("http", "cli"):
            raise SystemExit(f"--osa-mode must be http or cli, got {mode!r}")
        self.mode = mode
        self.base_url = base_url.rstrip("/")
        self.auth_token = auth_token
        self.model = model
        self.provider = provider
        self.max_turns = max_turns
        self.max_budget_usd = max_budget_usd
        self.timeout_s = timeout_s
        self.repo_root = repo_root
        self.log_dir = log_dir
        self.with_test_bridge = with_test_bridge
        self.run_id = run_id
        self.transcript_dir = transcript_dir
        # `requests.Session` is not thread-safe, and instances now run
        # concurrently (`--infer-workers`). One session per thread; connection
        # pooling still works, it is just not shared across workers.
        self._local = threading.local()
        self._backend: dict = {}

    @property
    def _session(self) -> requests.Session:
        s = getattr(self._local, "session", None)
        if s is None:
            s = requests.Session()
            self._local.session = s
        return s

    # -- lifecycle ---------------------------------------------------------

    def _headers(self) -> dict:
        h = {"Content-Type": "application/json"}
        if self.auth_token:
            h["Authorization"] = f"Bearer {self.auth_token}"
        return h

    def prepare(self) -> None:
        if self.mode == "cli":
            if not self.repo_root or not (self.repo_root / "mix.exs").exists():
                raise SystemExit(
                    "--osa-mode cli needs --osa-repo pointing at an OSA source checkout"
                )
            return
        try:
            r = self._session.get(f"{self.base_url}/health", timeout=10)
            r.raise_for_status()
            # cost_update frames do not reliably carry the model name, so pin
            # what the backend reports at start of run and record that instead.
            self._backend = r.json()
            if not self.model:
                self.model = self._backend.get("model")
            if not self.provider:
                self.provider = self._backend.get("provider")
        except requests.RequestException as e:
            raise SystemExit(
                f"OSA backend not reachable at {self.base_url} ({e}).\n"
                f"Start one on a non-default port so it does not collide with your\n"
                f"everyday daemon, e.g.:\n"
                f"  cd {self.repo_root or '/path/to/OSA'} && "
                f"OSA_HTTP_PORT=19801 mix osa.serve"
            ) from e

    def close(self) -> None:
        # Per-thread sessions are closed by GC when the worker threads exit;
        # only this thread's is reachable from here.
        s = getattr(self._local, "session", None)
        if s is not None:
            s.close()
        unseed_permission_modes(f"swebench-{_sanitize(self.run_id)}-")

    # -- transcript capture ------------------------------------------------

    def _capture_transcript(self, session_id: str) -> dict:
        """Copy OSA's own session files into the run directory.

        `~/.osa/sessions/` is shared mutable state that later runs overwrite, so
        a failure cannot be diagnosed from it weeks later. Failures are the
        deliverable here, so the transcript travels with the result.
        """
        if not self.transcript_dir:
            return {}
        src = _osa_home() / "sessions"
        if not src.is_dir():
            return {}
        dest = self.transcript_dir / session_id
        dest.mkdir(parents=True, exist_ok=True)
        copied = []
        for p in src.glob(f"{_sanitize(session_id)}.*"):
            try:
                shutil.copy2(p, dest / p.name)
                copied.append(p.name)
            except OSError:
                pass
        return {"transcript_dir": str(dest), "transcript_files": sorted(copied)}

    # -- prompt ------------------------------------------------------------

    def _prompt(self, task: Task) -> str:
        return PROMPT.format(
            repo=task.repo,
            base_commit=task.base_commit,
            problem_statement=task.problem_statement.strip(),
            test_hint=TEST_HINT if (self.with_test_bridge and task.container) else "",
        )

    # -- entry point -------------------------------------------------------

    def run(self, task: Task) -> RunResult:
        # The run_id must be in the session id. OSA's spend sidecar is keyed by
        # session and is deliberately never reset, so a stable id would make a
        # second run of the same instance report the sum of both runs.
        session_id = _sanitize(f"swebench-{self.run_id}-{task.instance_id}")
        clear_session_files(session_id, archive_to=self.transcript_dir)
        t0 = time.monotonic()
        try:
            if self.mode == "http":
                telemetry = self._run_http(task, session_id)
            else:
                telemetry = self._run_cli(task, session_id)
            status, error = telemetry.pop("status"), telemetry.pop("error", None)
        except Exception as e:  # noqa: BLE001 - a runner must never raise
            telemetry, status, error = {}, "runner_error", f"{type(e).__name__}: {e}"

        wall = time.monotonic() - t0

        dropped_tests: list[str] = []
        try:
            patch, dropped_tests = git_diff(
                task.workspace, strip_paths=task.graded_away_paths
            )
        except subprocess.CalledProcessError as e:
            patch = ""
            status, error = "runner_error", f"git diff failed: {e.stderr!r}"

        if status == "ok" and not patch.strip():
            # An agent that edited ONLY test files looks identical to one that
            # did nothing, unless we say so -- and they are very different
            # mistakes, so they get different buckets.
            status = "tests_only_patch" if dropped_tests else "empty_patch"

        # `<id>.spend.json` is OSA's own cumulative per-session ledger and is
        # the authoritative number. The summed SSE frames are the cross-check;
        # they are recorded alongside so a divergence is visible rather than
        # silently resolved.
        spend = read_spend(session_id)
        summed = telemetry.get("usage_sum") or {}

        def pick(spend_key: str, sse_key: str):
            if spend_key in spend:
                return spend[spend_key]
            return summed.get(sse_key)

        return RunResult(
            instance_id=task.instance_id,
            patch=patch,
            status=status,
            error=error,
            wall_clock_s=wall,
            tokens_in=pick("input_tokens", "input_tokens"),
            tokens_out=pick("output_tokens", "output_tokens"),
            tokens_cache_read=pick("cache_read_tokens", "cache_read_input_tokens"),
            tokens_cache_write=pick(
                "cache_creation_tokens", "cache_creation_input_tokens"
            ),
            # `cost_usd` on the sidecar is the PARENT session only; a run that
            # delegates bills its children to their own sidecars, so quoting it
            # under-reports. `tree_cost_usd` is parent + descendants. Absent on
            # sidecars written before the field existed, hence the fallback.
            cost_usd=_tree_cost(spend, telemetry),
            # False => `cost_usd` above is a LOWER BOUND (a descendant's spend
            # could not be read). Any report quoting the number must say so.
            cost_complete=_cost_complete(spend, telemetry),
            tool_calls=telemetry.get("tool_calls"),
            turns=telemetry.get("turns"),
            model=telemetry.get("model") or self.model,
            session_id=session_id,
            raw={
                "spend_sidecar": spend,
                "sse_usage_sum": summed,
                "provider": self.provider,
                "transport": self.mode,
                "backend_version": self._backend.get("version"),
                "dropped_test_paths": dropped_tests,
                "event_log": str(self._event_log_path(task.instance_id) or ""),
                # OSA-side pathologies (tool failures, stalls, compaction,
                # truncation, early stop) mined from the event stream. This is
                # what separates "the model wrote a wrong patch" from "OSA got
                # in its own way", which is the whole point of the exercise.
                "osa_signals": telemetry.get("signals") or {},
                **self._capture_transcript(session_id),
            },
        )

    # -- http transport ----------------------------------------------------

    def _run_http(self, task: Task, session_id: str) -> dict:
        events: Queue = Queue()
        stop = threading.Event()
        reader = threading.Thread(
            target=self._sse_reader, args=(session_id, events, stop), daemon=True
        )
        reader.start()
        # Give the stream a moment to actually connect; `done` is not replayed.
        time.sleep(1.0)

        # Overdrive short-circuits the approval path in tool_executor before it
        # is ever reached. Without it a headless run either parks on an
        # approval nobody can answer, or fails closed on every mutating tool.
        self._session.post(
            f"{self.base_url}/api/v1/commands/execute",
            headers=self._headers(),
            json={"command": "permission_mode overdrive", "session_id": session_id},
            timeout=30,
        )

        body = {
            "input": self._prompt(task),
            "session_id": session_id,
            "working_dir": str(task.workspace.resolve()),
        }
        r = self._session.post(
            f"{self.base_url}/api/v1/orchestrate",
            headers=self._headers(),
            json=body,
            timeout=60,
        )
        if r.status_code not in (200, 202):
            stop.set()
            return {"status": "runner_error", "error": f"orchestrate HTTP {r.status_code}: {r.text[:400]}"}

        tool_calls = 0
        turns = 0
        # `cost_update.usage` is PER TURN, not cumulative -- it must be summed.
        # `session_cost_usd` on the same frame IS cumulative and must not be.
        usage_sum: dict[str, int] = {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        }
        cost = None
        cost_complete = True
        model = None
        # A turn can end on an error rather than an answer. `turn_error` carries
        # an additive `owner` field (`:osa` | `:provider`); without reading it
        # this runner returned status "ok" for a turn that died inside OSA, and
        # diagnose.py then filed the missing patch as `model_no_patch`. Every
        # OSA-internal fault was being charged to the model.
        turn_error = None
        deadline = time.monotonic() + task.timeout_s
        log = self._open_log(task.instance_id)
        sig = _SignalCollector()

        def snapshot(status: str, error: str | None = None) -> dict:
            return {
                "status": status, "error": error,
                "usage_sum": dict(usage_sum), "cost_usd": cost,
                "cost_complete": cost_complete,
                "tool_calls": tool_calls, "turns": turns, "model": model,
                "turn_error": turn_error,
                "turn_error_owner": _turn_error_owner(turn_error),
                "signals": sig.finish(),
            }

        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._cancel(session_id)
                    return snapshot("timeout", f"agent exceeded {task.timeout_s}s")
                try:
                    ev = events.get(timeout=min(remaining, 5.0))
                except Empty:
                    continue

                if ev is None:  # reader died
                    return snapshot("runner_error", "SSE stream closed before done")
                if log:
                    log.write(json.dumps(ev) + "\n")
                sig.observe(ev)

                etype = ev.get("type") or ev.get("_event")
                if etype == "tool_call" and ev.get("phase") == "start":
                    tool_calls += 1
                elif etype == "cost_update":
                    for k in usage_sum:
                        v = (ev.get("usage") or {}).get(k)
                        if isinstance(v, int):
                            usage_sum[k] += v
                    # Prefer the tree total over the parent-only session cost;
                    # see _tree_cost. Both are cumulative, so neither is summed.
                    cost = _tree_cost(ev, {"cost_usd": cost}, session_key="session_cost_usd")
                    if ev.get("tree_cost_complete") is False:
                        cost_complete = False
                    model = ev.get("model") or model
                    turns += 1
                    if ev.get("turn_error"):
                        turn_error = ev["turn_error"]
                elif etype == "done":
                    if turn_error:
                        owner = _turn_error_owner(turn_error)
                        msg = (turn_error.get("message")
                               if isinstance(turn_error, dict) else None)
                        return snapshot(_OWNER_STATUS[owner], msg or f"turn_error ({owner})")
                    return snapshot("ok")
        finally:
            stop.set()
            if log:
                log.close()

    def _event_log_path(self, instance_id: str) -> Path | None:
        if not self.log_dir:
            return None
        return self.log_dir / f"{instance_id}.events.jsonl"

    def _open_log(self, instance_id: str):
        p = self._event_log_path(instance_id)
        if not p:
            return None
        self.log_dir.mkdir(parents=True, exist_ok=True)  # type: ignore[union-attr]
        return p.open("w")

    def _cancel(self, session_id: str) -> None:
        try:
            self._session.post(
                f"{self.base_url}/api/v1/sessions/{session_id}/cancel",
                headers=self._headers(),
                timeout=30,
            )
        except requests.RequestException:
            pass

    def _sse_reader(self, session_id: str, out: Queue, stop: threading.Event) -> None:
        """Parse `event: <name>\\ndata: <json>\\n\\n` frames onto the queue."""
        try:
            with self._session.get(
                f"{self.base_url}/api/v1/stream/{session_id}",
                headers=self._headers(),
                stream=True,
                timeout=(10, None),
            ) as resp:
                resp.raise_for_status()
                name = None
                for raw in resp.iter_lines(decode_unicode=True):
                    if stop.is_set():
                        return
                    if raw is None:
                        continue
                    line = raw.strip()
                    if not line or line.startswith(":"):
                        continue
                    if line.startswith("event:"):
                        name = line[6:].strip()
                    elif line.startswith("data:"):
                        payload = line[5:].strip()
                        try:
                            ev = json.loads(payload)
                        except json.JSONDecodeError:
                            ev = {"raw": payload}
                        if not isinstance(ev, dict):
                            ev = {"raw": ev}
                        ev.setdefault("_event", name)
                        ev.setdefault("type", name)
                        out.put(ev)
                        if (ev.get("type") or name) == "done":
                            return
                        name = None
        except requests.RequestException:
            pass
        finally:
            out.put(None)

    # -- cli transport -----------------------------------------------------

    def _run_cli(self, task: Task, session_id: str) -> dict:
        # The HTTP transport POSTs `permission_mode overdrive` before it
        # dispatches. The CLI transport had no equivalent, so every mutating
        # tool would have failed closed and the run would have scored 0 for
        # reasons unrelated to OSA's ability. PermissionMode rehydrates its ETS
        # table from this file when a fresh BEAM starts, which is exactly what
        # `mix osa.run` is, so seeding the file is enough.
        seed_permission_mode(session_id, "overdrive")

        cmd = [
            "mix", "osa.run",
            "--format", "stream-json",
            "--max-turns", str(self.max_turns),
            "--resume", session_id,
        ]
        if self.model:
            cmd += ["--model", self.model]
        if self.provider:
            cmd += ["--provider", self.provider]
        if self.max_budget_usd is not None:
            cmd += ["--max-budget", str(self.max_budget_usd)]
        cmd.append(self._prompt(task))

        env = os.environ.copy()
        env["OSA_ORIGINAL_CWD"] = str(task.workspace.resolve())
        env["MIX_ENV"] = env.get("MIX_ENV", "dev")
        # `mix osa.run` boots the whole application, HTTP listener included. Two
        # of them, or one alongside a daemon, fight over the port and the loser
        # dies at boot with an error that has nothing to do with the task. Give
        # each invocation its own.
        env["OSA_HTTP_PORT"] = str(_free_port())

        log = self._open_log(task.instance_id)
        tool_calls = 0
        sig = _SignalCollector()
        timed_out = threading.Event()
        try:
            proc = subprocess.Popen(
                cmd, cwd=self.repo_root, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, errors="replace",
            )

            # `proc.wait(timeout=...)` after draining stdout can never fire: the
            # drain loop blocks until the child closes stdout, so a hung agent
            # hangs the whole benchmark. A watchdog that kills the child is what
            # actually bounds this.
            def _watchdog() -> None:
                if not timed_out.wait(task.timeout_s):
                    timed_out.set()
                    proc.kill()

            wd = threading.Thread(target=_watchdog, daemon=True)
            wd.start()

            try:
                for line in proc.stdout:  # type: ignore[union-attr]
                    if log:
                        log.write(line)
                    line = line.strip()
                    if not line.startswith("{"):
                        continue
                    try:
                        ev = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    sig.observe(ev)
                    # `mix osa.run --format stream-json` labels tool frames
                    # `tool_use`; the HTTP stream calls them `tool_call`. Accept
                    # both so the two transports report comparable numbers.
                    if ev.get("type") in ("tool_use", "tool_call") and ev.get(
                        "phase"
                    ) in ("start", None):
                        tool_calls += 1
                rc = proc.wait()
            finally:
                was_timeout = timed_out.is_set()
                timed_out.set()  # release the watchdog

            if was_timeout:
                return {"status": "timeout", "error": f"exceeded {task.timeout_s}s",
                        "tool_calls": tool_calls, "signals": sig.finish()}
            if rc != 0:
                err = (proc.stderr.read() if proc.stderr else "")[:800]
                return {"status": "agent_error", "error": f"exit {rc}: {err}",
                        "tool_calls": tool_calls, "signals": sig.finish()}
            return {"status": "ok", "tool_calls": tool_calls, "signals": sig.finish()}
        finally:
            if log:
                log.close()
