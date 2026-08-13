"""Harbor agent adapter for OSA in the *corrupted* arm of Recovery-Bench.

This is deliberately the thinnest file in the directory. Everything it does is
composition:

* :class:`bench.terminalbench.osa_agent.OsaAgent` already knows how to get an
  OSA OTP release into a Terminal-Bench container, boot ``osagent serve`` and
  drive it over OSA's own HTTP/SSE API. None of that is re-implemented here.
* ``recovery_bench.agents.recovery_mixin.RecoveryMixin`` (upstream, vendored
  under ``upstream/``) already knows how to find the previous failed
  trajectory, extract its commands, and wrap the instruction in the standard
  recovery preamble. That is re-used verbatim rather than re-worded, because
  the *prompt text is part of the benchmark*: change it and the number stops
  being comparable to the published one.

The class body below is the same three-method shape as upstream's
``RecoveryClaudeCode``, ``RecoveryCodex`` and ``RecoveryPi``: ``setup`` replays,
``run`` re-prompts. That symmetry is the point — it is what makes "OSA on
Recovery-Bench" the same measurement as "Claude Code on Recovery-Bench".

--------------------------------------------------------------------------
What the two arms actually differ by
--------------------------------------------------------------------------

Fresh arm      : ``OsaAgent`` on task T, pristine container.
Corrupted arm  : ``RecoveryOsa`` on task T, container into which a *weaker*
                 model's failed command sequence has been replayed first.

Model, task, image, verifier, timeouts and the OSA release binary are identical
across the two. The only independent variable is the starting state of the
machine (plus, if ``message_mode`` is not ``none``, the polluted transcript).
That is what makes the delta attributable to recovery rather than capability.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The Terminal-Bench adapter is the parent class; upstream carries the replay
# engine and the prompt text. Both are path-injected rather than installed,
# which keeps this directory self-contained and keeps `bench/terminalbench`
# unmodified — the fresh arm has to run the *unmodified* adapter or the
# comparison is worthless.
for p in (HERE.parent / "terminalbench", HERE / "upstream"):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

from harbor.environments.base import BaseEnvironment  # noqa: E402
from harbor.models.agent.context import AgentContext  # noqa: E402

from osa_agent import OsaAgent  # noqa: E402
from recovery_bench.agents.recovery_mixin import RecoveryMixin  # noqa: E402
from recovery_bench.replay import replay_via_exec  # noqa: E402

logger = logging.getLogger(__name__)


class RecoveryOsa(RecoveryMixin, OsaAgent):
    """OSA, started on a machine a previous agent already broke."""

    def __init__(self, *args, message_mode: str = "none", **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._init_recovery(message_mode)
        self._replay_stats: dict[str, int] = {}

    @staticmethod
    def name() -> str:
        return "recovery-osa"

    # ----------------------------------------------------------------- setup

    async def setup(self, environment: BaseEnvironment) -> None:
        """Install OSA, then corrupt the machine under it.

        Order matters and is inherited from upstream: the agent is installed
        into the *pristine* container first, then the failed trajectory is
        replayed. Replaying first would let the previous agent's commands
        interfere with OSA's own install (a `rm -rf /` style step in a
        trajectory would take the harness down rather than the task), and it
        would also mean install failures got mis-attributed to corruption.

        OSA lives under ``/installed-agent``, which no task's verifier looks
        at, so nothing replayed here can be undone by the install and nothing
        installed here changes what the verifier sees.
        """
        await super().setup(environment)

        commands, messages = self._parse_trajectory()
        started = time.time()
        # Written unconditionally, before the replay, so that a replay which
        # hangs or crashes still leaves evidence of what it was going to do.
        # Harbor's trial.log only records a subset of execs, so without this
        # file there is no durable proof that the corruption ever happened —
        # and an unproven corrupted arm is just a second fresh arm.
        manifest = {
            "trajectory_folder": str(self._trajectory_folder),
            "trajectory_found": bool(commands or messages),
            "commands_found": len(commands),
            "prior_messages": len(messages),
            "message_mode": self._message_mode,
            "first_commands": [c.command for c in commands[:15] if c.command],
            "replay_started": True,
            "replay_finished": False,
            "replay_seconds": None,
        }
        self._write_manifest(manifest)

        if not commands:
            # A corrupted arm with nothing to replay is a *fresh* run wearing a
            # recovery label. It must never be silently scored as recovery.
            logger.error(
                "RECOVERY-BENCH: no trajectory commands found for this task "
                "(TRAJECTORY_FOLDER=%s). This trial is NOT a valid corrupted "
                "run and must be excluded from the delta.",
                self._trajectory_folder,
            )
            self._replay_stats = {"commands_found": 0}
            return

        logger.info("RECOVERY-BENCH: replaying %d commands", len(commands))
        await replay_via_exec(environment, commands)

        manifest["replay_finished"] = True
        manifest["replay_seconds"] = round(time.time() - started, 2)
        self._write_manifest(manifest)
        self._replay_stats = {"commands_found": len(commands)}

    def _write_manifest(self, manifest: dict) -> None:
        """Persist replay evidence next to the rest of the trial's artefacts."""
        try:
            self.logs_dir.mkdir(parents=True, exist_ok=True)
            (self.logs_dir / "recovery-replay.json").write_text(
                json.dumps(manifest, indent=2) + "\n"
            )
        except OSError as e:  # noqa: BLE001
            logger.warning("could not write recovery-replay.json: %s", e)

    # ------------------------------------------------------------------- run

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        """Prompt OSA with the recovery-wrapped instruction.

        ``_build_recovery_instruction`` is upstream's, unmodified: the
        RECOVERY MODE preamble is benchmark text, not harness text.
        """
        recovery_instruction = await self._build_recovery_instruction(instruction)
        await super().run(recovery_instruction, environment, context)

    # ------------------------------------------------------------- telemetry

    def populate_context_post_run(self, context: AgentContext) -> None:
        """Parent telemetry, plus the facts that make the arm auditable.

        ``recovery_replay_commands`` is the field the reporter uses to throw a
        trial out of the corrupted arm. Without it, a replay that silently did
        nothing would inflate the corrupted score and shrink the delta — the
        exact direction of error that would make OSA look better than it is.
        """
        super().populate_context_post_run(context)
        meta = dict(context.metadata or {})
        meta.update(
            {
                "recovery_arm": "corrupted",
                "recovery_message_mode": self._message_mode,
                "recovery_replay_commands": self._replay_stats.get("commands_found", 0),
                "recovery_trajectory_folder": str(self._trajectory_folder),
                "recovery_prior_messages": len(getattr(self, "_replay_messages", []) or []),
            }
        )
        context.metadata = meta


class RecoveryOsaFullContext(RecoveryOsa):
    """``message_mode=full``: the polluted transcript goes in the prompt too.

    Kept as a named class because Harbor selects agents by import path, and a
    separate path is the least error-prone way to run the second condition
    without a stray ``--agent-kwarg`` silently changing what a run means.
    """

    def __init__(self, *args, **kwargs) -> None:
        kwargs.setdefault("message_mode", "full")
        super().__init__(*args, **kwargs)

    @staticmethod
    def name() -> str:
        return "recovery-osa-full"


# Sanity: fail at import rather than mid-run if the traces were never fetched.
if not os.environ.get("RECOVERYBENCH_SKIP_TRACE_CHECK"):
    _folder = os.environ.get("TRAJECTORY_FOLDER", "")
    if _folder and not Path(_folder).is_dir():
        raise SystemExit(
            f"TRAJECTORY_FOLDER={_folder!r} is not a directory. "
            "Fetch the shared initial traces first:  ./fetch_lfs.py"
        )
