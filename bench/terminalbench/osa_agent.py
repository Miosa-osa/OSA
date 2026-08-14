"""Harbor agent adapter for OSA — Terminal-Bench 2.0.

Run it with::

    harbor run -d terminal-bench@2.0 \
        -a bench.terminalbench.osa_agent:OsaAgent \
        --ae OLLAMA_URL=http://host.docker.internal:11434

--------------------------------------------------------------------------
Why this adapter looks the way it does
--------------------------------------------------------------------------

Harbor scores the *final state of the container*, not a patch, so the agent has
to run inside the container. Every other adapter in Harbor's tree
(``claude_code``, ``codex``, ``pi``, ``fx``) installs its agent from npm or a
curl|sh installer, because every other agent is a Node or Rust binary.

OSA is an Elixir/OTP application. Three routes were on the table:

  1. **Install a toolchain and build OSA in the task container.** Rejected:
     ~800 MB of apt + hex + a multi-minute compile *per task*, needing network
     egress the task may not have, and it changes the environment under test
     before the agent ever starts.

  2. **Run OSA on the host and drive the container over a shim.** Rejected: the
     agent's shell would not be the graded container's shell in any faithful
     sense, tool calls would cross a host boundary, and the failure modes we are
     specifically hunting (compaction, truncation, long-horizon recovery) would
     be measured against a fake terminal.

  3. **Ship a self-contained OTP release with ERTS bundled.**  Chosen.  OSA
     already produces exactly this artefact (``mix release osagent``, see
     ``.github/workflows/release.yml``) and it needs no Elixir, no Erlang and no
     toolchain on the target. It is 17 MB, extracts in about a second, and the
     only host contract is glibc — libcrypto/libssl/libtinfo are vendored into
     ``<release>/vendor`` and put on ``LD_LIBRARY_PATH`` at install time.

Route 3's one real constraint is that ERTS is native code, so the release must
be built against a glibc no newer than the task image's. ``build_release.sh``
builds it inside debian-bookworm for that reason; see ``Dockerfile.release``.

The other half of the problem is that the OTP release exposes **no one-shot
headless run**. ``bin/osagent`` dispatches ``chat|setup|serve|doctor|version``
and nothing else; the one-shot path (``mix osa.run --format stream-json``) is a
Mix task, and Mix tasks are not shipped in a release. So the adapter boots
``osagent serve`` inside the container and drives it over its own HTTP/SSE API
with ``driver/osa_headless.py``. That is a real OSA entry point, not a mock: the
same one ``bench/swebench``'s http transport uses.
"""

from __future__ import annotations

import json
import os
import shlex
from pathlib import Path
from typing import Any, override

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trial.paths import EnvironmentPaths

HERE = Path(__file__).resolve().parent
RELEASE_TARBALL = HERE / "dist" / "osa-release-linux-x86_64.tar.gz"
DRIVER = HERE / "driver" / "osa_headless.py"
BOOT_CHECK = HERE / "driver" / "osa_boot_check.py"

# Where the release lands in the container. /installed-agent is Harbor's own
# convention (BaseInstalledAgent.setup creates it) and is outside anything a
# task's tests look at, so OSA's presence cannot itself change a verdict.
REMOTE_ROOT = "/installed-agent"
REMOTE_RELEASE = f"{REMOTE_ROOT}/osa"
REMOTE_DRIVER = f"{REMOTE_ROOT}/osa_headless.py"
REMOTE_BOOT_CHECK = f"{REMOTE_ROOT}/osa_boot_check.py"
REMOTE_INSTRUCTION = f"{REMOTE_ROOT}/instruction.txt"

# ---------------------------------------------------------------------------
# Ablation switches: OSA behaviour flags forwarded from the host process into
# the container.
#
# These exist so a one-variable ablation can be run against the SAME artefact.
# Rebuilding from an older commit to turn a feature off changes everything that
# landed between the two commits; a runtime kill switch changes one clause. An
# ablation whose arms were built differently is not an ablation, and we have
# already voided one that way.
#
# Each is forwarded on BOTH seams, because either alone has a silent-failure
# mode and a flag that does not arrive is indistinguishable from a flag that
# had no effect:
#
#   1. ``~/.osa/.env`` written by :meth:`_dotenv` -> ``Application.start``
#      does ``System.put_env/2`` for anything not already in the OS env.
#   2. the ``env=`` of the ``run()`` exec -> the driver process -> ``boot()``
#      does ``os.environ.copy()`` -> the ``osagent serve`` OS environment,
#      which is what ``System.get_env/1`` reads at the point of use.
#
# Verified against release 1.0.97 / artefact sha256 8cb0e2b3...:
#   OSA_VERIFICATION_ADEQUACY=0 bin/osagent_release eval \
#     'IO.puts(inspect(System.get_env("OSA_VERIFICATION_ADEQUACY")))'  ->  "0"
# and the compiled-in default reads back as ``true``, i.e. ON unless switched.
#
# Unset on the host means "do not mention it at all", so the default arm is
# byte-identical to a run made before this existed.
OSA_ABLATION_ENV_KEYS = (
    # Agent.Loop.VerificationGate clause 3 (adequacy: a persisted, re-runnable
    # test that failed at least once and then passed across a source fix).
    # "0"/"false"/"off"/"no" disables it. Clauses 1 and 2 are NOT affected,
    # and neither is `VerificationGate.first_write_nudge/1`.
    "OSA_VERIFICATION_ADEQUACY",
)


#: The driver's own default deadline, duplicated from
#: `driver/osa_headless.py:RUN_TIMEOUT`. Kept here so the multiplier can be
#: applied host-side, where the multiplier is known -- the driver runs inside
#: the container and has never been told what Harbor was invoked with.
DRIVER_RUN_TIMEOUT_BASE = 1800

#: Seconds of headroom the driver keeps under Harbor's own agent deadline.
#:
#: ## Why the driver has to lose the race on purpose
#:
#: Harbor bounds `agent.run()` with `wait_for(agent_timeout)`. When that fires it
#: cancels the coroutine and the container exec dies where it stands: no
#: telemetry file, no `cancel` POST, so OSA never flushes its spend sidecar, and
#: -- since 2026-08-15 -- the driver's exit-code table never runs either. The
#: trial lands as `no_telemetry_written` and the whole fault-attribution record
#: for it is lost.
#:
#: When the DRIVER's deadline fires first, it cancels the session, writes
#: telemetry, and exits 0, and Harbor's verifier then grades whatever is on
#: disk. That is not a technicality: on the full-89 run, 2 of the 5 trials that
#: reached the driver's own timeout scored **reward 1.0** -- the work was
#: finished and only the terminal frame was missing.
#:
#: ## What was actually happening
#:
#: The deadline was a fixed 1800s base, so which clock won was an accident of
#: the task's declared budget. Measured across TB 2.0 at `--timeout-multiplier
#: 2.0`: **Harbor pre-empted the driver on 56 of 89 tasks**, and the driver only
#: won on the 33 whose own budget was >= 1800s. `gpt2-codegolf` (900s budget,
#: so 1800s from Harbor against the driver's 3600s) is the worked example --
#: `AgentTimeoutError`, `no_telemetry_written`, nothing recorded.
DRIVER_TIMEOUT_GRACE_SEC = 60


def task_declared_timeout(logs_dir: Path) -> float | None:
    """The task's own `timeout_sec`, resolved host-side. None if not knowable.

    Harbor hands `agent_timeout_sec` to the constructor **only for the oracle**
    (`trial/trial.py:822-828`), and exports no `HARBOR_*_TIMEOUT` into the
    container, so an adapter is simply never told its budget. It is recoverable
    anyway, because this adapter runs on the HOST: the trial directory is named
    `<task-name>__<suffix>`, and the dataset the run selected is on disk.

    Returns the task's declared base timeout, unmultiplied -- the caller applies
    the multiplier, exactly as Harbor does.
    """
    try:
        trial_name = logs_dir.parent.name
    except (AttributeError, IndexError):
        return None
    task_name = trial_name.rsplit("__", 1)[0]
    if not task_name:
        return None

    tasks_dir = os.environ.get("OSA_TBENCH_TASKS_DIR") or os.environ.get(
        "OSA_BENCH_TASKS_DIR"
    )
    if tasks_dir:
        # The run told us exactly which task set it selected. Unambiguous.
        roots = [Path(tasks_dir)]
    elif (HERE / "tasks").is_dir():
        # Nobody told us, so scan the dataset copies this repo manages. Task
        # NAMES are not unique across them -- `gpt2-codegolf` exists in TB 2.0
        # at 900s and elsewhere at 18000s -- so a first-match scan silently
        # picks the wrong budget, and picking a budget that is 20x too large
        # puts Harbor back in front of the driver, which is the exact failure
        # this function exists to prevent. Ambiguity therefore resolves to
        # "unknown", never to a guess.
        roots = sorted((HERE / "tasks").glob("*"))
    else:
        return None

    found: set[float] = set()
    for root in roots:
        toml_path = Path(root) / task_name / "task.toml"
        if not toml_path.is_file():
            continue
        try:
            import tomllib

            data = tomllib.loads(toml_path.read_text())
        except Exception:  # noqa: BLE001
            continue
        # `timeout_sec` lives under [agent] in schema 1.x; tolerate top level.
        for section in (data.get("agent") or {}, data):
            v = section.get("timeout_sec")
            if isinstance(v, (int, float)) and v > 0:
                found.add(float(v))
                break

    if len(found) == 1:
        return found.pop()
    # Zero matches, or several datasets that disagree: not knowable.
    return None


def driver_run_timeout() -> int | None:
    """The agent deadline the driver should enforce, scaled by the multiplier.

    ## The bug this closes

    `driver/osa_headless.py` kills the episode at a hardcoded 1800s. That
    deadline is independent of every Harbor timeout multiplier, so a run
    invoked with `--timeout-multiplier 2.0` -- whose `result.json` faithfully
    records `timeout_multiplier: 2.0` -- still cut its agent off at 1800s
    while Harbor was prepared to wait 3600s. The effective budget was
    `min(Harbor, ours)`, and ours always won.

    Measured on the first full-89 arm: `make-mips-interpreter` died at 1875s
    wall with `osa_error: "agent exceeded 1800s"` -- our string, not Harbor's --
    on a run that claimed a doubled budget. That arm gave every task half the
    agent time cline's published GLM-5.2 rows got, which is precisely the axis
    it existed to match.

    ## Why it is computed here and not there

    The driver executes inside the task container and is never told what Harbor
    was invoked with. The multiplier is only knowable in this process, so the
    scaling has to happen here and arrive as `OSA_BENCH_RUN_TIMEOUT`, which the
    driver already reads. That also means **this fix requires no edit to the
    driver**, which matters: the driver is uploaded per-trial during
    `install()`, so changing it mid-run would hand later trials a different
    budget from earlier ones and make the arm internally inconsistent.

    Returns `None` when no multiplier is set, leaving the driver's own default
    untouched rather than restating it -- an unset multiplier must not start
    writing an env var that was previously absent.
    """
    raw = os.environ.get("OSA_BENCH_TIMEOUT_MULTIPLIER")
    if not raw:
        return None
    try:
        mult = float(raw)
    except ValueError:
        return None
    if mult <= 0 or mult == 1.0:
        return None
    return int(DRIVER_RUN_TIMEOUT_BASE * mult)


def ablation_env() -> dict[str, str]:
    """The ablation switches actually set in the host process, if any."""
    return {
        k: os.environ[k]
        for k in OSA_ABLATION_ENV_KEYS
        if os.environ.get(k) not in (None, "")
    }


# Appended (idempotently) to every `releases/<vsn>/env.sh` in the injected
# release. The marker comment is what makes a re-install a no-op.
_VENDOR_PATH_SNIPPET = f"""set -eu
for f in {REMOTE_RELEASE}/releases/*/env.sh; do
  if ! grep -q OSA_BENCH_VENDOR_PATH "$f"; then
    cat >> "$f" <<'EOF'

# OSA_BENCH_VENDOR_PATH -- added by bench/terminalbench/osa_agent.py
export LD_LIBRARY_PATH="$RELEASE_ROOT/vendor${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}"
EOF
  fi
done
"""


class OsaAgent(BaseInstalledAgent):
    """OSA driven headlessly inside the task container."""

    # OSA emits its own event stream, not Harbor's ATIF trajectory format.
    SUPPORTS_ATIF = False
    SUPPORTS_RESUME = False

    def __init__(
        self,
        *args: Any,
        provider: str | None = None,
        port: int = 19899,
        boot_timeout_sec: int = 240,
        run_timeout_sec: int | None = None,
        **kwargs: Any,
    ) -> None:
        self._provider = provider
        self._port = int(port)
        self._boot_timeout = int(boot_timeout_sec)
        # An explicit operator override only. The DEFAULT is resolved per-trial
        # in `_effective_run_timeout()`, because it depends on the task's own
        # declared budget and the trial does not exist yet at construction time.
        self._run_timeout_override = int(run_timeout_sec) if run_timeout_sec else None
        super().__init__(*args, **kwargs)
        if not RELEASE_TARBALL.exists():
            raise FileNotFoundError(
                f"{RELEASE_TARBALL} is missing. Build it first:\n"
                f"  {HERE / 'build_release.sh'}\n"
                "It is a self-contained OTP release and is deliberately not "
                "committed."
            )

    @staticmethod
    @override
    def name() -> str:
        return "osa"

    @override
    def get_version_command(self) -> str | None:
        return f"{REMOTE_RELEASE}/bin/osagent version"

    def parse_version(self, stdout: str) -> str:
        # `osagent version` prints an ERTS latin1-locale warning on a bare
        # container image before the version line, so take the last non-empty
        # line rather than the whole of stdout.
        lines = [l for l in stdout.strip().splitlines() if l.strip()]
        last = lines[-1] if lines else ""
        return last.strip().removeprefix("osagent v").strip()

    # ---------------------------------------------------------------- config

    def _dotenv(self) -> str:
        """The ``~/.osa/.env`` OSA loads at boot.

        Values come from the host process env, which is how Harbor's ``--ae``
        flags arrive. Nothing is defaulted to a credential; an unset key is
        written as empty so OSA's own resolution order applies unchanged.
        """
        keys = (
            "OSA_DEFAULT_PROVIDER",
            "OLLAMA_URL",
            "OLLAMA_MODEL",
            "OLLAMA_API_KEY",
            # The reasoning dial that actually reaches the wire on our serving
            # path. `Providers.Ollama.maybe_add_think/3` reads
            # `:ollama_think` (set from this key) FIRST, ahead of the
            # `thinking_model?/1` default -- and Ollama has no effort->thinking
            # wiring at all, so OSA's effort ladder never changes an Ollama
            # request body. Unset means "whatever the capability probe decides",
            # which is exactly the unpinned condition that voids a comparison.
            "OLLAMA_THINK",
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "OPENAI_BASE_URL",
            "GROQ_API_KEY",
            "XAI_API_KEY",
            "OPENROUTER_API_KEY",
            "ZAI_API_KEY",
        )
        lines = []
        for k in keys:
            v = self._get_env(k) if hasattr(self, "_get_env") else os.environ.get(k)
            if v:
                lines.append(f"{k}={v}")
        if self._provider:
            lines.append(f"OSA_DEFAULT_PROVIDER={self._provider}")
        if self.model_name:
            provider, model = self._split_model(self.model_name)
            lines.append(f"OSA_DEFAULT_PROVIDER={provider}")
            lines.append(f"{provider.upper()}_MODEL={model}")
        # The benchmark never wants a TUI, an updater, or telemetry chatter.
        lines += [
            "OSA_REQUIRE_AUTH=false",
            f"OSA_HTTP_PORT={self._port}",
        ]
        # Ablation switches (seam 1 of 2 -- see OSA_ABLATION_ENV_KEYS).
        lines += [f"{k}={v}" for k, v in ablation_env().items()]
        return "\n".join(lines) + "\n"

    def _split_model(self, model_name: str) -> tuple[str, str]:
        """Harbor passes ``provider/model``; OSA wants them separately."""
        if "/" in model_name:
            provider, model = model_name.split("/", 1)
            return provider, model
        return (self._provider or "ollama"), model_name

    def _config_json(self) -> str:
        provider, model = (
            self._split_model(self.model_name)
            if self.model_name
            else (self._provider or os.environ.get("OSA_DEFAULT_PROVIDER") or "ollama",
                  os.environ.get("OLLAMA_MODEL") or "")
        )
        return json.dumps({"provider": provider, "model": model}, indent=2)

    def _config_toml(self) -> str | None:
        """``~/.osa/config.toml``, written ONLY to pin reasoning effort.

        Returns ``None`` when ``OSA_BENCH_EFFORT`` is unset, and nothing is
        uploaded in that case. That is not laziness: an unpinned run must be
        distinguishable on disk from a run pinned to OSA's default, because the
        two are the same request bytes and different claims. `run_bench.py`
        records the same absence as ``"effort": null``.

        Only ``[model].effort`` is written. A ``[model].provider`` here would
        take TOP precedence in `Application.resolve_model/0` -- ahead of the
        `OSA_DEFAULT_PROVIDER` env the rest of this adapter sets -- so the table
        is kept to the one key that has no other seam. `ConfigFile.effort/0` is
        toml-only; there is no config.json or env equivalent.
        """
        effort = os.environ.get("OSA_BENCH_EFFORT")
        if not effort:
            return None
        return f'[model]\neffort = "{effort}"\n'

    # --------------------------------------------------------------- install

    @override
    async def install(self, environment: BaseEnvironment) -> None:
        # python3 for the driver; procps so the driver can reap `serve`; tar to
        # unpack; ca-certificates so OSA's HTTP client can reach a provider.
        #
        # `git` is NOT optional, and not because the benchmark wants it: OSA's
        # FSCheckpoint.Server calls System.cmd("git", ["init"]) in its GenServer
        # init and does not rescue :enoent. On an image without git that
        # exception propagates through Supervisors.Extensions and takes the
        # whole application down at boot. See the "OSA defects" section of
        # README.md -- this is an OSA bug being worked around here, not a
        # benchmark requirement.
        await self.ensure_system_dependencies(
            environment, ("python3", "tar", "ca_certificates", "procps", "git")
        )

        await self.exec_as_root(
            environment, command=f"mkdir -p {shlex.quote(REMOTE_ROOT)}"
        )
        remote_tar = f"{REMOTE_ROOT}/osa-release.tar.gz"
        await environment.upload_file(RELEASE_TARBALL, remote_tar)
        await environment.upload_file(DRIVER, REMOTE_DRIVER)
        await environment.upload_file(BOOT_CHECK, REMOTE_BOOT_CHECK)

        await self.exec_as_root(
            environment,
            command=(
                f"set -eu; "
                f"tar -C {shlex.quote(REMOTE_ROOT)} -xzf {shlex.quote(remote_tar)} && "
                f"rm -f {shlex.quote(remote_tar)} && "
                f"rm -rf {shlex.quote(REMOTE_RELEASE)} && "
                f"mv {shlex.quote(REMOTE_ROOT)}/osagent {shlex.quote(REMOTE_RELEASE)} && "
                f"chmod +x {shlex.quote(REMOTE_DRIVER)} {shlex.quote(REMOTE_BOOT_CHECK)}"
            ),
        )

        # erlexec refuses to start its C port program as root unless an explicit
        # effective user was requested, and Terminal-Bench task containers all
        # run as root. Two things are needed, both from erlexec's own docs:
        #
        #   * the port program must carry the setuid bit and be root-owned,
        #     otherwise exec.cpp's `is_root` stays false and `-user root` is
        #     rejected as "requested root but effective user is not root";
        #   * the erlexec application env must carry root/user/limit_users, so
        #     exec_app passes `-user root` to the port program at all.
        #
        # The app env key is `erlexec`, NOT `exec` (exec_app.erl reads
        # application:get_env(erlexec, ...) while the OTP application is named
        # `exec`) -- an easy hour to lose. vm.args is the right place because it
        # survives without touching OSA's source or its sys.config.
        #
        # OSA itself boots erlexec unconditionally even though only the
        # OpenComputers PTY executor uses it, so this is load-bearing for every
        # containerised OSA, not just this benchmark. See README.md.
        await self.exec_as_root(
            environment,
            command=(
                "set -eu; "
                f"chmod u+s {REMOTE_RELEASE}/lib/erlexec-*/priv/*/exec-port; "
                "printf '\\n-erlexec root true user root limit_users [root]\\n' "
                f">> {REMOTE_RELEASE}/releases/*/vm.args"
            ),
        )

        # Make the release's vendored shared libraries actually load.
        #
        # Dockerfile.release copies libcrypto/libssl/libtinfo out of the build
        # image into `<release>/vendor/` precisely so the artefact does not
        # depend on the task image shipping compatible ones. Nothing ever put
        # that directory on the loader's search path, so the vendored copies
        # were dead weight and the crypto NIF resolved against whatever
        # /usr/lib/x86_64-linux-gnu the task image happened to have. That worked
        # only because every current Terminal-Bench image ships libcrypto.so.3;
        # it is an undeclared dependency on the environment and would break
        # silently on an image without one (bullseye ships 1.1, not 3).
        #
        # `releases/<vsn>/env.sh` is the right seam: the release boot script
        # sources it before every command (`. "$REL_VSN_DIR/env.sh"`, after it
        # computes RELEASE_ROOT), so `version`, `doctor`, the boot check and the
        # episode's `serve` all get it, without touching OSA's source. Vendor
        # comes first so it wins over the system copy -- the point is to use the
        # library we shipped, not to fall back to it.
        await self.exec_as_root(
            environment,
            command=_VENDOR_PATH_SNIPPET,
        )

        # OSA config. HOME-relative on purpose: OSA's dotenv loader uses
        # Path.expand("~/.osa/.env") and does NOT honour OSA_HOME, so writing
        # anywhere else silently produces an unconfigured agent.
        await self.exec_as_root(
            environment,
            command='mkdir -p "$HOME/.osa"',
        )
        uploads = [
            (self._dotenv(), "/tmp/osa-dotenv", ".env"),
            (self._config_json(), "/tmp/osa-config", "config.json"),
        ]
        toml = self._config_toml()
        if toml is not None:
            uploads.append((toml, "/tmp/osa-config-toml", "config.toml"))
        for content, dest, fname in uploads:
            await self._upload_config_text(
                environment, content=content, remote_path=dest, filename=fname
            )
            await self.exec_as_root(
                environment,
                command=f'mv {shlex.quote(dest)} "$HOME/.osa/{fname}" && '
                f'chmod 600 "$HOME/.osa/{fname}"',
            )

        # Fail loudly here rather than mid-episode: an artefact that cannot boot
        # is an install failure, and Harbor should record it as one instead of
        # scoring a zero that looks like the model's fault.
        #
        # This used to run `osagent version` and claim exactly that guarantee,
        # which it did not deliver. `bin/osagent version` is `<release> eval
        # OptimalSystemAgent.CLI.version()`, and a Mix release's `eval` starts
        # the VM without starting the OTP application tree -- no supervisor
        # init/1 runs, and no boot-time NIF is loaded. A release with a corrupt
        # or unloadable NIF prints its version happily. That is not a
        # hypothetical: an entire 89-task run failed with `install_or_boot_failed`
        # in the episode on an artefact whose `version` had passed on four
        # different base images.
        #
        # So the gate now boots `serve` and waits for /health -- the same entry
        # point and the same signal the episode itself depends on. Reaching
        # /health means the application tree started, which is the capability
        # being claimed. --require-vendor additionally asserts the VM mapped the
        # release's own libcrypto, so the vendoring above is verified rather
        # than assumed.
        await self.exec_as_root(
            environment,
            command=(
                f"python3 -u {shlex.quote(REMOTE_BOOT_CHECK)} "
                f"{shlex.quote(REMOTE_RELEASE)} "
                f"--port {self._port + 1} --timeout {self._boot_timeout} "
                f"--require-vendor"
            ),
            timeout_sec=self._boot_timeout + 120,
        )

    # ------------------------------------------------------------------- run

    def _effective_run_timeout(self) -> int | None:
        """The deadline handed to the driver, guaranteed to fire before Harbor's.

        Three inputs, in precedence order:

        1. an explicit `run_timeout_sec` kwarg — an operator override, honoured
           as given and never second-guessed;
        2. the task's own declared budget times the multiplier, minus
           `DRIVER_TIMEOUT_GRACE_SEC`. This is the case that matters and the one
           that used not to exist; see that constant for what it costs when
           Harbor wins the race instead;
        3. the old fixed base times the multiplier, when the task's budget is
           not resolvable (a task set outside `tasks/`, or a `task.toml` we
           cannot parse).

        Never returns a value above Harbor's own deadline when that deadline is
        knowable, and returns `None` rather than inventing one when nothing is
        known — an unset multiplier must leave the driver's built-in default
        alone rather than start writing an env var that was previously absent.
        """
        if self._run_timeout_override:
            return self._run_timeout_override

        raw = os.environ.get("OSA_BENCH_TIMEOUT_MULTIPLIER")
        try:
            mult = float(raw) if raw else 1.0
        except ValueError:
            mult = 1.0
        if mult <= 0:
            mult = 1.0

        declared = task_declared_timeout(self.logs_dir)
        if declared:
            # Beat Harbor by the grace margin, but never go below a floor -- a
            # task with a very short budget must not end up with a deadline so
            # small that the driver cancels a run that was about to finish.
            budget = declared * mult
            return int(max(budget - DRIVER_TIMEOUT_GRACE_SEC, budget * 0.9))

        # Nothing task-specific is knowable: fall back to the fixed base scaled
        # by the multiplier, which is all this could ever do before.
        return driver_run_timeout()

    @override
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        agent_dir = EnvironmentPaths.agent_dir.as_posix()
        await self._upload_config_text(
            environment,
            content=instruction,
            remote_path=REMOTE_INSTRUCTION,
            filename="instruction.txt",
        )
        await self.exec_as_root(
            environment, command=f"chmod 644 {shlex.quote(REMOTE_INSTRUCTION)}"
        )

        env = {
            "OSA_BENCH_AGENT_DIR": agent_dir,
            "OSA_BENCH_RELEASE": REMOTE_RELEASE,
            "OSA_BENCH_PORT": str(self._port),
            "OSA_BENCH_BOOT_TIMEOUT": str(self._boot_timeout),
            "OSA_BENCH_SESSION": (self.session_id or "tbench").replace("/", "_"),
            # Ablation switches (seam 2 of 2 -- see OSA_ABLATION_ENV_KEYS).
            # This is the seam that reaches `osagent serve`'s real OS env,
            # which is what `System.get_env/1` reads at the point of use.
            **ablation_env(),
            **self.resolve_env_vars(),
        }
        run_timeout = self._effective_run_timeout()
        if run_timeout:
            env["OSA_BENCH_RUN_TIMEOUT"] = str(run_timeout)

        await self.exec_as_root(
            environment,
            command=(
                f"mkdir -p {shlex.quote(agent_dir)} && "
                f"python3 -u {shlex.quote(REMOTE_DRIVER)} "
                f"{shlex.quote(REMOTE_INSTRUCTION)} 2>&1 | "
                f"tee {shlex.quote(agent_dir + '/osa-driver.log')}"
            ),
            env=env,
        )

    # ------------------------------------------------------------- telemetry

    @override
    def populate_context_post_run(self, context: AgentContext) -> None:
        """Lift OSA's own telemetry into Harbor's AgentContext.

        ``metadata`` deliberately carries the diagnostic fields as well as the
        counters. This benchmark exists to find OSA's own defects, so the
        distinction between "the model did the wrong thing" and "OSA got in its
        own way" has to survive into the results file.
        """
        path = self.logs_dir / "osa-telemetry.json"
        if not path.exists():
            context.metadata = {"osa_status": "no_telemetry_written"}
            return
        try:
            t = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError) as e:
            context.metadata = {"osa_status": f"telemetry_unreadable: {e}"}
            return

        spend = t.get("spend_sidecar") or {}
        summed = t.get("usage_sum") or {}

        def pick(spend_key: str, sse_key: str):
            # Two cumulative counts of the same session, reconciled by `max`.
            #
            # This used to prefer the sidecar whenever the key was present. The
            # sidecar is written by the agent process and can lag the SSE frames
            # by one LLM round-trip when a run is torn down right after its
            # final answer -- measured at 30k-110k input tokens per task on the
            # cost probe, always in the direction that makes us look cheaper.
            # Neither counter can exceed the truth, so `max` is the unbiased
            # reconciliation rather than a guess about which source to trust.
            vals = [
                v
                for v in (spend.get(spend_key), summed.get(sse_key))
                if isinstance(v, (int, float)) and not isinstance(v, bool)
            ]
            return max(vals) if vals else None

        context.n_input_tokens = pick("input_tokens", "input_tokens")
        context.n_output_tokens = pick("output_tokens", "output_tokens")
        cache_r = pick("cache_read_tokens", "cache_read_input_tokens") or 0
        cache_w = pick("cache_creation_tokens", "cache_creation_input_tokens") or 0
        context.n_cache_tokens = (cache_r + cache_w) or None
        # Whole-tree cost, not the parent session alone: subagent/fleet children
        # bill to their own sidecars, so `cost_usd` under-reports any run that
        # delegates. Falls back through parent-only for artefacts written before
        # `tree_cost_usd` existed. The sidecar's own `cost_usd` field is never
        # rewritten -- `tree_spend/1` sums it across descendants, so a tree total
        # stored there would make every ancestor double-count its grandchildren.
        # Same reconciliation as `pick`: these are cumulative totals of one
        # session, so the largest readable one is the freshest, not the first
        # one that happens to be non-null. A stale sidecar taking precedence
        # over a complete frame total is precisely the under-count above.
        cost_vals = [
            v
            for v in (
                spend.get("tree_cost_usd"),
                t.get("cost_usd"),  # driver already preferred the tree total
                spend.get("cost_usd"),
            )
            if isinstance(v, (int, float)) and not isinstance(v, bool)
        ]
        cost = max(cost_vals) if cost_vals else None
        context.cost_usd = cost if cost else None
        # True | False (LOWER BOUND) | None (parent-only, pre-tree-cost run).
        cost_complete = spend.get("tree_cost_complete")
        if cost_complete is None:
            cost_complete = t.get("cost_complete")

        context.metadata = {
            "osa_status": t.get("status"),
            "osa_error": t.get("error"),
            "osa_turns": t.get("turns"),
            "osa_tool_calls": t.get("tool_calls"),
            "osa_saw_done": t.get("saw_done"),
            "osa_boot_s": t.get("boot_s"),
            "osa_run_s": t.get("run_s"),
            "osa_model": t.get("model"),
            "osa_last_event_type": t.get("last_event_type"),
            # Who owns a turn-ending error: `osa` (an OSA bug -- harness fault),
            # `provider` (upstream), or `unknown` (no `owner` field on the
            # event). Carried through so the report can split them instead of
            # charging every one of them to the model.
            # Whether `cost_usd` covers the agent tree. False => lower bound;
            # None => parent session only (subagent spend not included at all).
            # A report quoting the cost MUST carry this.
            "osa_cost_complete": cost_complete,
            "osa_turn_error": t.get("turn_error"),
            "osa_turn_error_owner": t.get("turn_error_owner"),
            "osa_event_type_counts": t.get("event_type_counts"),
            "osa_self_inflicted": (t.get("self_inflicted") or {}).get("counts"),
            "osa_self_inflicted_samples": (t.get("self_inflicted") or {}).get("samples"),
            "osa_usage_sum": summed,
            "osa_spend_sidecar": spend,
        }
