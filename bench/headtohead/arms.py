"""The arms: one row per agent harness, and what it takes to make it runnable.

THE POINT OF THIS FILE
----------------------
A head-to-head is only a harness comparison if the MODEL IS HELD FIXED. The
moment one arm runs GPT-5 and another runs GLM, the result is a model
comparison wearing a harness comparison's clothes, and it will be quoted as the
latter. So every arm here declares, explicitly and machine-readably:

  * which model string it is given,
  * how it is pointed at the shared provider,
  * and -- for arms we cannot point at the shared provider -- WHY NOT.

`RUNNABLE` and `BLOCKED` are separate tables so that "we did not run Claude
Code" can never quietly become "Claude Code was not competitive".

THE SHARED PROVIDER
-------------------
One Ollama daemon on the host, at :11434, serving `glm-5.2:cloud` (a 1M-context
tool-calling model proxied to ollama.com). It exposes two wire protocols for
the same weights:

  * `/api/chat`            Ollama-native. OSA's `providers/ollama.ex` uses this.
  * `/v1/chat/completions` OpenAI-compatible shim. Everything else uses this.

Both were verified to reach `glm-5.2:cloud` and to return tool calls. This is a
REAL, DECLARED asymmetry -- the arms share weights and a daemon, not a
serialisation path -- and it is recorded in every artefact rather than glossed.
It is the smallest asymmetry available: the alternative (running OSA through
its own `openai_compat` provider) would have changed OSA away from its default
configuration, which is a bigger confound than the wire format.

Container reachability: Harbor puts each trial on its own compose network with
no host-gateway alias, so `host.docker.internal` does not resolve by default.
`bench/terminalbench/compose-host-provider.yaml` adds it. It is passed to
EVERY arm here, not just OSA -- an overlay applied to one arm and not another
is a difference in the environment under test.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
TBENCH = HERE.parent / "terminalbench"

#: The one model every arm must be given. Held fixed or the run is void.
SHARED_MODEL = "glm-5.2:cloud"

#: Reachable from inside a task container once the compose overlay is applied.
#: `host.docker.internal` does NOT resolve on the host itself, so it must never
#: be used for a host-side probe -- doing so reports "provider unreachable" for
#: a provider that is running perfectly well.
OPENAI_COMPAT_BASE_URL = "http://host.docker.internal:11434/v1"
OLLAMA_NATIVE_URL = "http://host.docker.internal:11434"

#: The same daemon, addressed from the host. Used only for preflight probes.
HOST_PROBE_URL = "http://localhost:11434"

#: Ollama does not check the bearer token; the local daemon holds the real
#: ollama.com credential. A placeholder is still required because several CLIs
#: refuse to start without SOME key, and refusing to start is an arm we would
#: then have to report as blocked for a reason that is not real.
PLACEHOLDER_KEY = "ollama-local-no-auth"


@dataclass(frozen=True)
class Arm:
    """One harness under test."""

    name: str
    #: What goes after `harbor run -a`. Either a registered agent name or a
    #: `module:Class` import path.
    agent_spec: str
    #: What goes after `-m`. The provider prefix selects Harbor's credential
    #: resolution path; the part after the slash is the model id sent on the wire.
    model: str
    #: Host env this arm needs so Harbor can resolve and forward credentials.
    env: dict[str, str] = field(default_factory=dict)
    #: Extra `--ae KEY=VALUE` pairs injected into the container's agent env.
    agent_env: dict[str, str] = field(default_factory=dict)
    #: Extra `--ak key=value` adapter kwargs. Values are JSON-parsed by Harbor.
    agent_kwargs: dict[str, str] = field(default_factory=dict)
    #: Which marker table `attribution.scrape_markers` should use.
    family: str = "generic"
    #: Which wire protocol this arm speaks to the shared daemon.
    wire: str = "openai-compat"
    #: Anything the reader must know to interpret this arm's number.
    caveats: tuple[str, ...] = ()

    def harbor_args(self) -> list[str]:
        args = ["-a", self.agent_spec, "-m", self.model]
        for k, v in sorted(self.agent_env.items()):
            args += ["--ae", f"{k}={v}"]
        for k, v in sorted(self.agent_kwargs.items()):
            args += ["--ak", f"{k}={v}"]
        return args


@dataclass(frozen=True)
class BlockedArm:
    """An arm we deliberately did not run, and the reason.

    `reason` must name a MISSING THING (a credential, a subscription, a
    protocol), never a judgement about the agent. An arm blocked for lack of a
    key is not an arm that lost.
    """

    name: str
    agent_spec: str
    blocker: str
    reason: str
    what_would_unblock: str
    #: Whether the CLI itself installs into a task container. Several of these
    #: install perfectly well and are blocked one layer later, at the model
    #: connection. Recording that distinction stops "blocked" from being read
    #: as "broken".
    installs_ok: bool | None = None
    installed_version: str | None = None


# ---------------------------------------------------------------------------
# Runnable arms
# ---------------------------------------------------------------------------
# NOTE: membership here is a CLAIM THAT MUST BE PROVEN by preflight.sh
# (does the CLI install) and by a live smoke trial (does it reach the shared
# provider and emit tool calls). `run_h2h.py --preflight-required` refuses to
# score an arm that has not passed both.

RUNNABLE: dict[str, Arm] = {
    "osa": Arm(
        name="osa",
        agent_spec="osa_agent:OsaAgent",
        model=f"ollama/{SHARED_MODEL}",
        agent_env={
            "OSA_DEFAULT_PROVIDER": "ollama",
            "OLLAMA_URL": OLLAMA_NATIVE_URL,
            "OLLAMA_MODEL": SHARED_MODEL,
        },
        family="osa",
        wire="ollama-native (/api/chat)",
        caveats=(
            "Runs from a snapshot OTP release in bench/terminalbench/dist/; a "
            "stale artefact silently benchmarks old code.",
            "Needs git present in the container and a setuid workaround for "
            "erlexec-as-root; both are OSA defects worked around by the "
            "adapter and both modify the environment under test.",
        ),
    ),
    "codex": Arm(
        name="codex",
        agent_spec="codex",
        model=f"openai/{SHARED_MODEL}",
        env={
            # Codex hardcodes default_provider="openai", so the prefix is
            # cosmetic; the key still has to resolve or the adapter writes an
            # empty auth.json.
            "OPENAI_API_KEY": PLACEHOLDER_KEY,
            "OPENAI_BASE_URL": OPENAI_COMPAT_BASE_URL,
        },
        agent_env={
            # Codex >= ~0.13 REMOVED `wire_api = "chat"` — WireApi has a single
            # variant, Responses — so the OpenAI-compatible chat-completions
            # route that every other arm uses does not exist for this arm. Its
            # built-in `ollama` provider is Responses-over-CODEX_OSS_BASE_URL,
            # and the Ollama daemon here was verified to serve
            # POST /v1/responses (HTTP 200, glm-5.2). That is the only route in.
            "CODEX_OSS_BASE_URL": OPENAI_COMPAT_BASE_URL,
        },
        agent_kwargs={
            # Route to the built-in `ollama` provider. Built-in providers
            # cannot be redefined, and the built-in `openai` one sets
            # requires_openai_auth, so a fresh selection is the only way in.
            "config": '{"model_provider":"ollama"}',
            # Codex otherwise emits `-c model_reasoning_effort=high` for every
            # model, including ones that never heard of the parameter.
            "reasoning_effort": "null",
        },
        family="codex",
        wire="openai-responses (/v1/responses)",
        caveats=(
            "Reaches the shared daemon over /v1/responses, not "
            "/v1/chat/completions: the installed CLI (0.147.0) has no "
            "chat-completions wire API left. Same daemon, same weights, a "
            "third serialisation path.",
            "Needs `--ak config='{\"model_provider\":\"ollama\"}'` — built-in "
            "providers cannot be redefined, and the `openai` provider sets "
            "requires_openai_auth.",
            "Ships `-c model_reasoning_effort=high` by default for EVERY "
            "model; passed `--ak reasoning_effort=null` so a non-OpenAI "
            "endpoint is not handed a parameter it may reject.",
            "Installed from npm inside each container (nvm + node 22); needs "
            "egress to raw.githubusercontent.com, nodejs.org and npmjs.org.",
        ),
    ),
    "opencode": Arm(
        name="opencode",
        agent_spec="opencode",
        model=f"openai/{SHARED_MODEL}",
        env={
            "OPENAI_API_KEY": PLACEHOLDER_KEY,
            "OPENAI_BASE_URL": OPENAI_COMPAT_BASE_URL,
        },
        family="opencode",
        # OBSERVED, not assumed. A live trial's own error payload carried
        # `metadata.url = http://host.docker.internal:11434/v1/responses` --
        # opencode routes through the AI SDK's openai provider, which now
        # defaults to the Responses API rather than chat-completions. The
        # connection config is confirmed correct by that same payload: right
        # host, right port, right model.
        wire="openai-responses (/v1/responses, observed)",
        caveats=(
            "Resolves its model catalog from models.dev and its provider "
            "package (@ai-sdk/openai) on demand AT RUN TIME, so it needs "
            "egress beyond install. XDG_DATA_HOME is redirected into /logs, so "
            "that cache is cold on every trial.",
            "The provider prefix must be literally `openai`: the adapter only "
            "injects `baseURL` for providers in {anthropic, openai}, so "
            "`ollama/...` would produce a provider block with no endpoint.",
        ),
    ),
    "goose": Arm(
        name="goose",
        agent_spec="goose",
        model=f"openai/{SHARED_MODEL}",
        env={
            "OPENAI_API_KEY": PLACEHOLDER_KEY,
            "OPENAI_BASE_URL": OPENAI_COMPAT_BASE_URL,
        },
        family="goose",
        caveats=(
            "goose hard-whitelists its provider slug to "
            "{anthropic, databricks, google, openai, tetrate}, so it has to be "
            "entered as `openai/` even though the endpoint is Ollama.",
            "Has a `--max-turns` cap (adapter default unset, goose's own "
            "default 1000). Left unset so that every arm is bounded by the "
            "SAME limit -- wall clock -- rather than by a cap only some arms "
            "have.",
            "Installed from a GitHub release tarball; needs egress to "
            "github.com and objects.githubusercontent.com.",
        ),
    ),
    "mini-swe-agent": Arm(
        name="mini-swe-agent",
        agent_spec="mini-swe-agent",
        model=f"openai/{SHARED_MODEL}",
        env={
            # MUST be OPENAI_API_KEY, not MSWEA_API_KEY: the spec lists
            # MSWEA_API_KEY first, and if it resolves, the passthrough branch
            # exports ONLY that name -- which upstream mini-swe-agent never
            # reads, so LiteLLM would receive no key at all.
            "OPENAI_API_KEY": PLACEHOLDER_KEY,
            "OPENAI_BASE_URL": OPENAI_COMPAT_BASE_URL,
        },
        family="generic",
        caveats=(
            "This is the CONTROL ARM and the most informative one here. "
            "mini-swe-agent is a deliberately minimal scaffold -- roughly a "
            "loop around one bash tool. Any arm that cannot beat it is not "
            "earning its complexity, and OSA beating it is the smallest claim "
            "worth making.",
            "`reasoning_effort` must stay unset: on an `openai/`-prefixed "
            "model the adapter switches to the Responses API, which is a "
            "different route from the one this arm is being measured on.",
            "Cost is always reported as 0 (glm-5.2:cloud is not in LiteLLM's "
            "price map, and MSWEA_COST_TRACKING=ignore_errors swallows the "
            "lookup failure). Tokens are real.",
        ),
    ),
    "aider": Arm(
        name="aider",
        agent_spec="aider",
        # DOUBLE prefix, deliberately. aider.py:151 passes the POST-SPLIT name
        # to the CLI, so `openai/glm-5.2:cloud` reaches aider as the bare
        # `glm-5.2:cloud`, and LiteLLM cannot infer a provider from that ->
        # "LLM Provider NOT provided". Doubling makes harbor's split eat one
        # prefix and hand LiteLLM the one it needs.
        model=f"openai/openai/{SHARED_MODEL}",
        env={
            "OPENAI_API_KEY": PLACEHOLDER_KEY,
            "OPENAI_BASE_URL": OPENAI_COMPAT_BASE_URL,
        },
        agent_env={
            # Only ONE url alias is auto-exported (the first that resolves);
            # LiteLLM checks OPENAI_BASE_URL then OPENAI_API_BASE. Belt and braces.
            "OPENAI_API_BASE": OPENAI_COMPAT_BASE_URL,
        },
        family="aider",
        caveats=(
            "Aider is an edit-loop assistant, not a terminal agent, and it is "
            "invoked one-shot with `--message`. It is a FLOOR, not a peer: "
            "Terminal-Bench grades container state, so an arm that mostly "
            "edits files is structurally disadvantaged. Read its score as a "
            "lower bound on the task set's difficulty, never as a ranking.",
            "REPORTS NO TELEMETRY AT ALL -- its "
            "`populate_context_post_run` is `pass`. No tokens, no cost. Its "
            "row in the cost table is empty by construction, and must not be "
            "read as 'cheap'.",
        ),
    ),
}


# ---------------------------------------------------------------------------
# Blocked arms
# ---------------------------------------------------------------------------

BLOCKED: dict[str, BlockedArm] = {
    "claude-code": BlockedArm(
        name="claude-code",
        agent_spec="claude-code",
        blocker="protocol + credential",
        reason=(
            "Claude Code speaks the Anthropic Messages API (`/v1/messages`) "
            "and Harbor's adapter only offers ANTHROPIC_API_KEY / "
            "ANTHROPIC_BASE_URL / Bedrock / an OAuth token. The shared Ollama "
            "daemon serves `/api/chat` and OpenAI's `/v1/chat/completions`; it "
            "does not serve `/v1/messages`, so there is no base URL that would "
            "make Claude Code talk to glm-5.2. No ANTHROPIC_API_KEY is present "
            "on this machine either, so the alternative -- running it on a "
            "Claude model -- would hold nothing fixed and measure the model, "
            "not the harness."
        ),
        what_would_unblock=(
            "An Anthropic-Messages-to-OpenAI translating proxy in front of "
            "Ollama (LiteLLM's /v1/messages passthrough, claude-code-router). "
            "That inserts a translation layer into one arm and not the others, "
            "which is itself a confound and would have to be declared."
        ),
        installs_ok=True,
        installed_version="2.1.231",
    ),
    "gemini-cli": BlockedArm(
        name="gemini-cli",
        agent_spec="gemini-cli",
        blocker="protocol + credential",
        reason=(
            "The adapter resolves GEMINI_API_KEY / GOOGLE_GEMINI_BASE_URL and "
            "drives the Google generative-language API. There is no "
            "OpenAI-compatible provider path in the adapter and no Google key "
            "on this machine."
        ),
        what_would_unblock="A Google API key, plus an arm that runs a Gemini model — which does not hold the model fixed.",
        installs_ok=True,
        installed_version="0.55.1",
    ),
    "cursor-cli": BlockedArm(
        name="cursor-cli",
        agent_spec="cursor-cli",
        blocker="subscription",
        reason=(
            "Hard-requires CURSOR_API_KEY (cursor_cli.py:863-867) and routes "
            "through Cursor's own backend, which selects the model. There is "
            "no way to point it at a local endpoint and no Cursor "
            "subscription here."
        ),
        what_would_unblock="A Cursor subscription — and it would still run Cursor's models, not ours.",
    ),
    "copilot-cli": BlockedArm(
        name="copilot-cli",
        agent_spec="copilot-cli",
        blocker="subscription",
        reason="Requires a GITHUB_TOKEN with Copilot entitlement; model selection is server-side.",
        what_would_unblock="A Copilot subscription — same model-fixing problem as cursor-cli.",
    ),
    "grok-build": BlockedArm(
        name="grok-build",
        agent_spec="grok-build",
        blocker="credential",
        reason="Requires XAI_API_KEY; no xAI credential on this machine.",
        what_would_unblock="An xAI key, and an xAI-hosted model — which again does not hold the model fixed.",
    ),
    "devin": BlockedArm(
        name="devin",
        agent_spec="devin",
        blocker="subscription",
        reason="Hosted product; runs on Cognition's infrastructure with their model.",
        what_would_unblock="Nothing that would preserve a fixed model.",
    ),
}


#: THE STANDING CONTROL ARM. Every OSA number we publish must sit next to this
#: one, on the same model and the same tasks.
#:
#: This is not a preference; it is the field's own convention. SWE-bench's
#: maintainers ship a "Bash Only" leaderboard filter whose tooltip reads "Show
#: only runs in the mini-SWE-agent environment, so scores compare models rather
#: than harnesses" — i.e. they built a view specifically to REMOVE the scaffold,
#: and mini-SWE-agent is the scaffold they chose as the neutral one. ProgramBench
#: adopted it as its sole scaffold for the same stated reason.
#:
#: It is ~190 lines: a loop around one bash tool, no tool-calling interface,
#: linear history, `subprocess.run` per action. It has already beaten OSA in our
#: own head-to-head. That is the finding, and it is more useful to us than any
#: number where OSA wins — a 190-line bash loop matching a whole harness is a
#: measurement of how much of the harness is doing nothing.
#:
#: `run_h2h.py` re-adds it if it is dropped from --arms, and records that it did.
STANDING_CONTROL_ARM = "mini-swe-agent"


def all_arm_names() -> list[str]:
    return sorted(RUNNABLE) + sorted(BLOCKED)


def get(name: str) -> Arm:
    if name in RUNNABLE:
        return RUNNABLE[name]
    if name in BLOCKED:
        b = BLOCKED[name]
        raise SystemExit(
            f"arm '{name}' is blocked ({b.blocker}): {b.reason}\n"
            f"What would unblock it: {b.what_would_unblock}"
        )
    raise SystemExit(f"unknown arm '{name}'. Known: {', '.join(all_arm_names())}")
