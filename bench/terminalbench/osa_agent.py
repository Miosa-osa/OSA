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
     only host contract is glibc + libcrypto.

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

# Where the release lands in the container. /installed-agent is Harbor's own
# convention (BaseInstalledAgent.setup creates it) and is outside anything a
# task's tests look at, so OSA's presence cannot itself change a verdict.
REMOTE_ROOT = "/installed-agent"
REMOTE_RELEASE = f"{REMOTE_ROOT}/osa"
REMOTE_DRIVER = f"{REMOTE_ROOT}/osa_headless.py"
REMOTE_INSTRUCTION = f"{REMOTE_ROOT}/instruction.txt"


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
        self._run_timeout = int(run_timeout_sec) if run_timeout_sec else None
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

        await self.exec_as_root(
            environment,
            command=(
                f"set -eu; "
                f"tar -C {shlex.quote(REMOTE_ROOT)} -xzf {shlex.quote(remote_tar)} && "
                f"rm -f {shlex.quote(remote_tar)} && "
                f"rm -rf {shlex.quote(REMOTE_RELEASE)} && "
                f"mv {shlex.quote(REMOTE_ROOT)}/osagent {shlex.quote(REMOTE_RELEASE)} && "
                f"chmod +x {shlex.quote(REMOTE_DRIVER)}"
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

        # OSA config. HOME-relative on purpose: OSA's dotenv loader uses
        # Path.expand("~/.osa/.env") and does NOT honour OSA_HOME, so writing
        # anywhere else silently produces an unconfigured agent.
        await self.exec_as_root(
            environment,
            command='mkdir -p "$HOME/.osa"',
        )
        for content, dest, fname in (
            (self._dotenv(), "/tmp/osa-dotenv", ".env"),
            (self._config_json(), "/tmp/osa-config", "config.json"),
        ):
            await self._upload_config_text(
                environment, content=content, remote_path=dest, filename=fname
            )
            await self.exec_as_root(
                environment,
                command=f'mv {shlex.quote(dest)} "$HOME/.osa/{fname}" && '
                f'chmod 600 "$HOME/.osa/{fname}"',
            )

        # Fail loudly here rather than mid-episode: a release that cannot even
        # print its version is an install failure, and Harbor should record it
        # as one instead of scoring a zero that looks like the model's fault.
        await self.exec_as_root(
            environment, command=f"{REMOTE_RELEASE}/bin/osagent version"
        )

    # ------------------------------------------------------------------- run

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
            **self.resolve_env_vars(),
        }
        if self._run_timeout:
            env["OSA_BENCH_RUN_TIMEOUT"] = str(self._run_timeout)

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
            if spend_key in spend:
                return spend[spend_key]
            return summed.get(sse_key)

        context.n_input_tokens = pick("input_tokens", "input_tokens")
        context.n_output_tokens = pick("output_tokens", "output_tokens")
        cache_r = pick("cache_read_tokens", "cache_read_input_tokens") or 0
        cache_w = pick("cache_creation_tokens", "cache_creation_input_tokens") or 0
        context.n_cache_tokens = (cache_r + cache_w) or None
        cost = spend.get("cost_usd", t.get("cost_usd"))
        context.cost_usd = cost if cost else None

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
            "osa_event_type_counts": t.get("event_type_counts"),
            "osa_self_inflicted": (t.get("self_inflicted") or {}).get("counts"),
            "osa_self_inflicted_samples": (t.get("self_inflicted") or {}).get("samples"),
            "osa_usage_sum": summed,
            "osa_spend_sidecar": spend,
        }
