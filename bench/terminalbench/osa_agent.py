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

from typing import ClassVar

from harbor.agents.installed.base import (
    BaseInstalledAgent,
    EnvVar,
    with_prompt_template,
)
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


def ablation_env(lookup=None) -> dict[str, str]:
    """The ablation switches actually set, if any.

    ``lookup`` is a ``get(key) -> str | None`` callable. It exists so the
    adapter can pass ``self._get_env`` and pick up Harbor's ``--ae`` values;
    with no argument it falls back to the host process env, which is what the
    module-level callers and the tests want.

    ## D9 — why the callable, and what was broken without it

    Harbor resolves an agent's environment from three sources, in precedence
    order (`agents/installed/base.py:583-590`): `--ae`-resolved vars, the
    agent's `extra_env`, then `os.environ`. Reading `os.environ` directly skips
    the first two, so `--ae OSA_VERIFICATION_ADEQUACY=0` was accepted on the
    command line, recorded in `config.json`, and then had **no effect on the
    run** -- the exact shape of a silently-void ablation. `OLLAMA_URL` worked
    only because it happened to go through `self._get_env`.
    """
    get = lookup if lookup is not None else os.environ.get
    out: dict[str, str] = {}
    for k in OSA_ABLATION_ENV_KEYS:
        v = get(k)
        if v not in (None, ""):
            out[k] = str(v)
    return out


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

    #: D10, in the one place it buys something.
    #:
    #: `CLI_FLAGS` is structurally inapplicable here: it builds a command line
    #: for the agent's binary (`build_cli_flags`, `base.py:706-722`), and this
    #: adapter never builds one -- `osagent serve` is started by the driver and
    #: driven over HTTP. Descriptors for `provider`/`port`/`boot_timeout_sec`
    #: would be ceremony around kwargs nothing else reads.
    #:
    #: `effort` is different, and the difference is a real hazard rather than a
    #: style point. It is written into `~/.osa/config.toml` as
    #: `[model].effort`, and OSA does not reject an unknown rung -- it logs
    #: "ignoring unknown [model].effort" and boots at its own default. So a
    #: typo produces a run that proceeds normally and records a pin it did not
    #: have, on the axis Anthropic measured at 10.3 pp and cline at 11.2 pp on
    #: this exact model. `choices` turns that into a construction-time
    #: `ValueError` (`base.py:725-741` -> `_coerce_value`).
    #:
    #: `env_fallback` keeps `OSA_BENCH_EFFORT=high ./run_bench.py ...` working
    #: unchanged while also accepting Harbor's own `--ak effort=high`.
    ENV_VARS: ClassVar[list[EnvVar]] = [
        EnvVar(
            kwarg="effort",
            env="OSA_BENCH_EFFORT",
            type="enum",
            # OSA's `Application.resolve_effort/1` accepts exactly these.
            choices=["fast", "medium", "high", "xhigh", "ultra"],
            env_fallback="OSA_BENCH_EFFORT",
        ),
    ]

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

    # --------------------------------------------------------------- env seam

    def _env(self, key: str, default: str | None = None) -> str | None:
        """One environment read, through Harbor's precedence chain.

        `--ae KEY=VALUE` lands in `self._resolved_env_vars`, which `_get_env`
        consults ahead of `self._extra_env` and `os.environ`
        (`agents/installed/base.py:583-590`). Reading `os.environ` directly --
        which this adapter used to do in five places -- silently ignores the
        first two, so an `--ae` switch that appears in `config.json` never
        reaches the run. See `ablation_env` for the measured consequence.

        The `AttributeError` fallback covers an instance built outside a Harbor
        trial: `_get_env` is inherited and therefore present, but it reads
        `self._resolved_env_vars` / `self._extra_env`, which only
        `BaseInstalledAgent.__init__` creates. The unit tests construct exactly
        that shape, and a bare `os.environ` read is the correct answer there --
        there is no `--ae` chain to consult.
        """
        get = getattr(self, "_get_env", None)
        if get is not None:
            try:
                v = get(key)
            except AttributeError:
                v = os.environ.get(key)
        else:
            v = os.environ.get(key)
        return v if v not in (None, "") else default

    def _ablation_env(self) -> dict[str, str]:
        """`ablation_env`, resolved through Harbor's precedence chain."""
        return ablation_env(self._env)

    @override
    def get_version_command(self) -> str | None:
        return f"{REMOTE_RELEASE}/bin/osagent version"

    # D11: this overrides `BaseInstalledAgent.parse_version`; the decorator is
    # what makes a rename upstream a type error here instead of a silent
    # fallback to the base implementation.
    @override
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
        # D11: built as an ordered mapping, not an append-only list.
        #
        # `OSA_DEFAULT_PROVIDER` could previously be written up to three times
        # in one file -- once from `keys`, once from `self._provider`, once from
        # `--model`. Every OSA `.env` reader is last-wins so the *effective*
        # value was right, but the artefact then disagreed with itself, and the
        # dotenv is one of the two places a later reader reconstructs what a run
        # was actually configured with. A config file that has to be replayed to
        # be understood is not a record.
        env: dict[str, str] = {}
        for k in keys:
            v = self._env(k)
            if v:
                env[k] = v
        if self._provider:
            env["OSA_DEFAULT_PROVIDER"] = self._provider
        if self.model_name:
            provider, model = self._split_model(self.model_name)
            env["OSA_DEFAULT_PROVIDER"] = provider
            env[f"{provider.upper()}_MODEL"] = model
        # The benchmark never wants a TUI, an updater, or telemetry chatter.
        env["OSA_REQUIRE_AUTH"] = "false"
        env["OSA_HTTP_PORT"] = str(self._port)
        # Ablation switches (seam 1 of 2 -- see OSA_ABLATION_ENV_KEYS).
        env.update(self._ablation_env())
        return "\n".join(f"{k}={v}" for k, v in env.items()) + "\n"

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
            else (self._provider or self._env("OSA_DEFAULT_PROVIDER") or "ollama",
                  self._env("OLLAMA_MODEL") or "")
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
        # Resolved through the `ENV_VARS` descriptor when one is available, so
        # `--ak effort=high` and `OSA_BENCH_EFFORT=high` are the same pin and an
        # invalid rung has already been rejected. Falls back to a plain env read
        # for an instance built outside a Harbor trial.
        effort = None
        try:
            effort = self.resolve_env_vars().get("OSA_BENCH_EFFORT")
        except AttributeError:
            pass
        if not effort:
            effort = self._env("OSA_BENCH_EFFORT")
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

        raw = self._env("OSA_BENCH_TIMEOUT_MULTIPLIER")
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

    # ------------------------------------------------------- injected context

    def _mcp_json(self) -> str | None:
        """Harbor's `self.mcp_servers`, in the file OSA actually reads.

        ## D6, half one

        Harbor injects `mcp_servers` into the agent constructor whenever a task
        or the job declares them (`trial/trial.py:828-840`), merging
        `task.config.environment.mcp_servers` with `config.agent.mcp_servers`.
        `BaseAgent.__init__` stores them on `self.mcp_servers`
        (`agents/base.py:73,84`), and this adapter read the attribute nowhere --
        so a task that ships an MCP server ran against an agent that could not
        see it, and was still scored. That failure is indistinguishable from the
        model being unable to do the task.

        Measured across the datasets on disk: **0 of 89 on TB 2.0 and 0 of 89 on
        TB 2.1** declare `mcp_servers`, so this has never altered a
        Terminal-Bench number. It is not academic anywhere else: **5 of the 80
        Harbor-Index tasks** (`gaia2-adapt-hard-1`, `-hard-2`, `gaia2-ambiguous`,
        `gaia2-timed-1`, `-2`) declare an `are` server, and
        `terminal-bench/medical-claims-processing` declares `playwright`. A
        Harbor-Index run made before this fix would have scored six tasks the
        agent was structurally unable to do.

        ## The format

        `~/.osa/mcp.json`, Claude-Desktop-compatible: a top-level `mcpServers`
        object (`lib/optimal_system_agent/mcp/config.ex:3-13`). OSA's parser
        picks the transport from the shape rather than from a field --
        `transport = if is_binary(url) ... :http_sse, else: :stdio`
        (`config.ex:416`).

        Harbor's three transports map onto OSA's two without loss, and the
        collapse is real rather than assumed: OSA's remote transport probes
        StreamableHTTP first and falls back to legacy HTTP+SSE on 404/405/406/415
        (`lib/optimal_system_agent/mcp/transport/http.ex:3-15,39-49`), which is
        the same negotiation opencode does. So `sse` and `streamable-http` are
        both "a URL", and OSA discovers which dialect the server speaks. Every
        MCP-declaring task on disk uses one of those two (`streamable-http` for
        the five gaia2 tasks, `sse` for `medical-claims-processing`).

        NOT VERIFIED against a live MCP task. Writing the file is measured
        against OSA's parser; that the resulting session reaches an `are`
        sidecar is not, and cannot be until a Harbor-Index arm runs.
        """
        servers = getattr(self, "mcp_servers", None) or []
        if not servers:
            return None
        out: dict[str, dict[str, Any]] = {}
        for s in servers:
            transport = getattr(s, "transport", None)
            url = getattr(s, "url", None)
            command = getattr(s, "command", None)
            if url:
                out[s.name] = {"url": url}
            elif command:
                entry: dict[str, Any] = {"command": command}
                args = list(getattr(s, "args", None) or [])
                if args:
                    entry["args"] = args
                out[s.name] = entry
            else:
                # Harbor's own validator forbids this
                # (`models/task/config.py:630-636`), so reaching it means the
                # shape changed upstream. Refuse rather than drop a server and
                # score the trial as if the task had never asked for one.
                raise RuntimeError(
                    f"MCP server {s.name!r} declares transport {transport!r} with "
                    "neither url nor command; refusing to run a task whose MCP "
                    "server cannot be configured."
                )
        return json.dumps({"mcpServers": out}, indent=2)

    def _reject_unsupported_injections(self, environment: BaseEnvironment) -> None:
        """D4 and D6: refuse what we cannot honour, instead of ignoring it.

        ## D4 — every exec in this adapter is `exec_as_root`

        Harbor wraps the run phase in
        `with self.agent_environment.with_default_user(user)`
        (`trial/trial.py:464`) so that `exec_as_agent` picks up
        `task.config.agent.user` (`agents/installed/base.py:875-886`). This
        adapter calls `exec_as_root` everywhere, which pins root regardless.

        **Measured: this changes nothing on anything we run.** All 332 task
        copies on disk -- 89 TB 2.0, 89 TB 2.1, 80 Harbor-Index, 74
        terminal-bench -- leave `[agent].user` unset, and Harbor documents unset
        as "the environment's default USER (e.g., root)"
        (`models/task/config.py:341-344`). So `exec_as_agent` and
        `exec_as_root` resolve to the same user on every task in the house, and
        the doc's claim that we "write root-owned files on tasks with a non-root
        agent user" describes a task that does not exist here.

        **It is not swapped anyway, because root is load-bearing.** The install
        phase needs it for apt, for `chmod u+s` on erlexec's port program, and
        for writing under `/installed-agent`. The run phase needs it because the
        release's own `vm.args` carries
        `-erlexec root true user root limit_users [root]` -- written by
        `install()` precisely because erlexec refuses to start its C port
        program as root without an explicit effective user. Running the driver
        as a non-root user against that vm.args would not produce a
        correctly-permissioned run; it would produce a boot failure.

        So the deviation stands, deliberately, and this guard is what stops it
        being silent: the first task that ever declares a non-root agent user
        gets an errored trial with a message, not a root-owned filesystem and a
        reward computed against it.
        """
        user = getattr(environment, "default_user", None)
        if user is not None and str(user) not in ("root", "0"):
            raise RuntimeError(
                f"task declares [agent].user={user!r}, but this adapter execs as "
                "root throughout (the injected release's vm.args pins erlexec to "
                "root, so a non-root run would fail to boot rather than run "
                "correctly). Refusing rather than writing root-owned files into a "
                "task whose verifier may check ownership."
            )
        self._reject_skills_dir()

    def _reject_skills_dir(self) -> None:
        """D6, half two: refuse a `skills_dir` instead of ignoring it.

        Harbor passes `skills_dir` as a path *inside the environment* holding
        Anthropic-style skill folders, and `claude_code.py:1559-1585` copies
        them into the agent's config dir. OSA's skills are a different artefact
        entirely -- `~/.osa/skills/<slug>.json`, one JSON document per skill
        (`lib/optimal_system_agent/skills.ex:24`,
        `agent/skill_bootstrap.ex:14-17`) -- so copying Harbor's directory there
        would produce files OSA's loader does not read. That is worse than doing
        nothing, because it looks like support.

        So this raises. A trial that errors is recorded with `exception_info`
        set and reads as a harness fault; a trial that silently ignores the
        injection is recorded as the model failing. Only one of those is true.

        No task on any dataset copy we hold declares `skills_dir` (measured: 0
        of 89 on TB 2.0, 0 of 89 on TB 2.1, 0 of 80 on Harbor-Index, 0 of 74 on
        terminal-bench), so this cannot fire on anything we currently run.
        """
        skills_dir = getattr(self, "skills_dir", None)
        if skills_dir:
            raise RuntimeError(
                f"Harbor injected skills_dir={skills_dir!r}, which this adapter "
                "cannot honour: OSA loads skills from ~/.osa/skills/<slug>.json, "
                "not from Anthropic-style SKILL.md folders. Refusing rather than "
                "scoring a task whose skills the agent never received."
            )

    # D5. `--agent-prompt-template` is applied by this decorator and by nothing
    # else: `render_instruction` is only ever called from `with_prompt_template`
    # (`agents/installed/base.py:159-176,913-917`). Without it the flag was
    # accepted, recorded in `config.json`, and silently discarded -- so a run
    # claiming a prompt template ran the bare instruction. Same placement as
    # `opencode.py:475-477`, `codex.py:1331-1333`, `claude_code.py:1599-1601`.
    @with_prompt_template
    @override
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        self._reject_unsupported_injections(environment)
        agent_dir = EnvironmentPaths.agent_dir.as_posix()
        await self._upload_config_text(
            environment,
            content=instruction,
            remote_path=REMOTE_INSTRUCTION,
            filename="instruction.txt",
        )
        mcp_json = self._mcp_json()
        if mcp_json:
            await self._upload_config_text(
                environment,
                content=mcp_json,
                remote_path=f"{REMOTE_ROOT}/mcp.json",
                filename="mcp.json",
            )
            await self.exec_as_root(
                environment,
                command=(
                    'mkdir -p "$HOME/.osa" && '
                    f'mv {shlex.quote(REMOTE_ROOT + "/mcp.json")} "$HOME/.osa/mcp.json" && '
                    'chmod 600 "$HOME/.osa/mcp.json"'
                ),
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
            **self._ablation_env(),
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

        uncached_in = pick("input_tokens", "input_tokens")
        context.n_output_tokens = pick("output_tokens", "output_tokens")
        cache_r = pick("cache_read_tokens", "cache_read_input_tokens") or 0
        cache_w = pick("cache_creation_tokens", "cache_creation_input_tokens") or 0

        # D7. `n_input_tokens` is the WHOLE prompt, cache included.
        #
        # ## What the field means
        #
        # Harbor documents it as "The number of input tokens used **including
        # cache**" (`models/agent/context.py:9-11`), and the ATIF field every
        # reference adapter feeds it from says the same: `total_prompt_tokens`
        # is "Sum of all prompt tokens across all steps, **including cached
        # tokens**" (`models/trajectories/final_metrics.py:11-14`).
        # `claude_code.py:755-759` computes it literally --
        # `prompt_tokens = input_tokens + cache_read + cache_creation`, commented
        # "Align with Anthropic session totals" -- and assigns it at `:1526`.
        # `opencode.py:421`, `codex.py:1195`, `cursor_cli.py:821` and
        # `openhands_sdk.py:160` all take the same `total_prompt_tokens`.
        # `n_cache_tokens` is the cache slice on its own, and is a SUBSET of
        # `n_input_tokens`, not a sibling of it (`claude_code.py:1527`).
        #
        # We were writing the uncached remainder into a field the whole field
        # reads as the total. Every token and cost figure published from
        # `results.json` was therefore incomparable with anyone else's.
        #
        # ## What OSA reports, measured
        #
        # OSA's `input_tokens` is the uncached remainder. `Loop.Accounting`
        # subtracts the cached overlap back out for every `{:compat, _}` route,
        # because an OpenAI-shaped gateway reports `prompt_tokens` inclusive of
        # its cached slice. Confirmed on `runs/anthropic-cache-probe-20260814`:
        # 101,547 input against 2,320,315 cache reads across 3 trials -- input
        # cannot be the total when it is 4% of the cache alone. So the three
        # counters are disjoint and adding them is the correct fold, not a
        # double count.
        #
        # ## What this changes about the numbers we have published
        #
        # Nothing, on the run we have quoted. `runs/osa-tb20-full89-f6981b61`
        # measured cache_read = 0 and cache_creation = 0 on all 87 trials that
        # wrote telemetry -- `ollama/glm-5.2:cloud` reported no cache tokens at
        # all -- so the fold adds zero. It matters for every future run on a
        # provider that does report them, where on the probe above it would have
        # been a 23x understatement.
        context.n_input_tokens = (
            (uncached_in or 0) + cache_r + cache_w
            if uncached_in is not None or cache_r or cache_w
            else None
        )
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
            # The uncached remainder, recorded explicitly because Harbor's
            # schema has nowhere to put it once `n_input_tokens` became the
            # total (D7). Without it a reader cannot recover a cache hit rate
            # from `results.json` alone, and `report.py::_reconcile_spend` would
            # have to guess whether an archived run's `n_input_tokens` came from
            # a pre- or post-D7 adapter. `report.py` prefers this key and treats
            # its absence as "pre-D7 artefact, `n_input_tokens` is uncached".
            "osa_uncached_input_tokens": uncached_in,
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
