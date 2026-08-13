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


def clear_session_files(session_id: str) -> None:
    """Remove any prior on-disk state for this session id.

    Without this a re-run inherits the previous run's spend sidecar and
    transcript, and the reported token totals become the sum of both runs.
    """
    sdir = _osa_home() / "sessions"
    if not sdir.is_dir():
        return
    stem = _sanitize(session_id)
    for p in sdir.glob(f"{stem}.*"):
        try:
            p.unlink()
        except OSError:
            pass


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
        self._session = requests.Session()
        self._backend: dict = {}

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
        self._session.close()

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
        clear_session_files(session_id)
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

        try:
            patch = git_diff(task.workspace)
        except subprocess.CalledProcessError as e:
            patch = ""
            status, error = "runner_error", f"git diff failed: {e.stderr!r}"

        if status == "ok" and not patch.strip():
            status = "empty_patch"

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
            cost_usd=spend.get("cost_usd", telemetry.get("cost_usd")),
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
        model = None
        deadline = time.monotonic() + task.timeout_s
        log = self._open_log(task.instance_id)

        def snapshot(status: str, error: str | None = None) -> dict:
            return {
                "status": status, "error": error,
                "usage_sum": dict(usage_sum), "cost_usd": cost,
                "tool_calls": tool_calls, "turns": turns, "model": model,
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

                etype = ev.get("type") or ev.get("_event")
                if etype == "tool_call" and ev.get("phase") == "start":
                    tool_calls += 1
                elif etype == "cost_update":
                    for k in usage_sum:
                        v = (ev.get("usage") or {}).get(k)
                        if isinstance(v, int):
                            usage_sum[k] += v
                    cost = ev.get("session_cost_usd", cost)
                    model = ev.get("model") or model
                    turns += 1
                elif etype == "done":
                    return snapshot("ok")
        finally:
            stop.set()
            if log:
                log.close()

    def _open_log(self, instance_id: str):
        if not self.log_dir:
            return None
        self.log_dir.mkdir(parents=True, exist_ok=True)
        return (self.log_dir / f"{instance_id}.events.jsonl").open("w")

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

        log = self._open_log(task.instance_id)
        tool_calls = 0
        try:
            proc = subprocess.Popen(
                cmd, cwd=self.repo_root, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, errors="replace",
            )
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
                    if ev.get("type") == "tool_use" and ev.get("phase") == "start":
                        tool_calls += 1
                rc = proc.wait(timeout=task.timeout_s)
            except subprocess.TimeoutExpired:
                proc.kill()
                return {"status": "timeout", "error": f"exceeded {task.timeout_s}s",
                        "tool_calls": tool_calls}
            if rc != 0:
                err = (proc.stderr.read() if proc.stderr else "")[:500]
                return {"status": "agent_error", "error": f"exit {rc}: {err}",
                        "tool_calls": tool_calls}
            return {"status": "ok", "tool_calls": tool_calls}
        finally:
            if log:
                log.close()
