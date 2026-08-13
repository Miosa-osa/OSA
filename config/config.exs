import Config

config :optimal_system_agent,
  # Default LLM provider: :ollama (local) or :anthropic (cloud) or :openai
  default_provider: :ollama,

  # Ollama settings — default to the local daemon, which proxies `:cloud`
  # models via device identity (key-free). The onboarding/picker flow always
  # writes an explicit OLLAMA_URL, so this default only affects zero-config
  # boots, where localhost is the friendlier "no GPU, no key" starting point.
  ollama_url: "http://localhost:11434",
  ollama_model: "qwen3-next:80b",
  ollama_api_key: System.get_env("OLLAMA_API_KEY"),

  # num_ctx ceiling OSA is willing to allocate for LOCAL providers
  # (:ollama / :lmstudio / :llamacpp). This is a CEILING, not the model's
  # trained maximum: KV-cache memory scales with num_ctx, so operators with
  # small VRAM lower it. It is the single knob that keeps budgeting
  # (Agent.Context) and the num_ctx we actually send to Ollama in agreement.
  # See Providers.Registry.effective_context_window/2.
  ollama_num_ctx: 32_768,

  # Anthropic settings (set ANTHROPIC_API_KEY env var)
  anthropic_model: "claude-opus-5",

  # OpenAI-compatible settings (set OPENAI_API_KEY env var)
  openai_url: "https://api.openai.com/v1",
  openai_model: "gpt-5.6-terra",

  # OpenRouter settings (set OPENROUTER_API_KEY env var)
  openrouter_url: "https://openrouter.ai/api/v1",
  # `meta-llama/llama-3.3-70b-instruct` does still exist on OpenRouter, but a
  # two-year-old 70B is a poor default for an agent. Matches the provider
  # config's default; verified present in the live GET /api/v1/models catalog.
  openrouter_model: "anthropic/claude-opus-5",

  # Drop, from the cached system prompt, the tool documentation that the
  # request's own native tool definitions already carry byte-for-byte.
  # Applies ONLY to providers that declare `native_tool_schemas?/0` (the
  # schemas ride in the request body, not in prompt text) and never to the
  # `:lite` local-provider path. Set to `false` to restore the full prose tool
  # block everywhere without a code change.
  dedupe_native_tool_prompt: true,

  # Honor the `alwaysApply: false` declared in a bundled rule's own frontmatter
  # instead of injecting every rule into every request, and strip the frontmatter
  # itself (metadata, not instructions) from what the model sees. Set to `false`
  # to restore the previous concatenate-everything behaviour.
  rules_respect_always_apply: true,

  # Agent configuration
  max_iterations: 200,

  # Should a text-only answer (visible text, no tool calls) be nudged back into
  # the ReAct loop because of how its PROSE reads?
  #
  # `false` (the default) ends the turn there, matching Codex, grok-build and
  # Claude Code. When the model returns text and calls no tools, that text IS
  # the answer — and it has already streamed to the user, so a continuation
  # cannot replace it, only append a second ending at the cost of another
  # full-context request.
  #
  # `true` restores the old wording-based nudges (`wants_to_continue?` /
  # `code_in_text?` / the zero-successful-tools gate) for a weak local model
  # that narrates ("Let me check…") instead of calling tools. Note these key on
  # phrasing, not on behaviour, so they also fire on a correct explanatory
  # answer: "check how the retry budget works and explain it" answered in prose
  # measured 3 round-trips, and an answer containing a fenced code block
  # measured `max_iterations + 1` before the gate was given a bound.
  #
  # Continuation driven by something REAL is unaffected either way and stays on:
  # an empty generation, pending unverified writes from tools that actually ran,
  # an explicit output-token target, a just-crossed compaction boundary, and
  # stop hooks / goal tracking forcing continuation.
  continue_on_text_only: false,

  # Goal verification — an INDEPENDENT, read-only skeptic panel that judges
  # whether the user's GOAL was actually met (not just "a file compiles"), plus
  # a cross-turn goal-status machine. See `Agent.Loop.GoalVerifier` /
  # `Agent.Loop.GoalTracker`.
  #
  # Smart activation (`:auto`, the default) resolves ON automatically for the
  # work where finishing-correctly matters and OFF for cheap interactive turns.
  # Precedence, highest first:
  #   1. explicit `true` / `false` here (operator override — always wins),
  #   2. otherwise `:auto` -> ON when the turn is autonomous/long-running:
  #        - overdrive/bypass permission mode, OR
  #        - a session driving an anchored goal loop (GoalTracker.start/2), OR
  #        - the current turn has run >= goal_verifier_activate_after_iterations
  #          ReAct iterations (a genuinely long turn gets verified even in ask
  #          mode),
  #      and OFF for ordinary short interactive turns.
  # Set to `true` to always verify, `false` to hard-disable.
  goal_verifier_enabled: :auto,
  goal_tracker_enabled: :auto,

  # Iteration count past which a single turn is treated as long-running and
  # goal verification auto-activates (even in ask mode) under `:auto`.
  goal_verifier_activate_after_iterations: 12,

  # Per-skeptic wall-clock bound for one goal-verification round. A skeptic is a
  # cheap, read-only vote (<= 6 iterations, no writes) that BLOCKS the user's
  # turn while the panel is joined, so it must not inherit the generic
  # `:subagent_await_timeout_ms` backstop (2 hours) meant for long delegated
  # work. A skeptic past this bound is reaped and counted as a fail-closed
  # refute, exactly like a crash.
  goal_verifier_skeptic_timeout_ms: 120_000,

  # Doom loop hard cap — absolute total tool calls per session before forced halt.
  # This is a secondary safety net independent of the sliding-window signature check.
  # Raised to 2000: a genuine backstop just above realistic multi-hour volume,
  # so an autonomous run isn't killed at 100. Runtime-tunable (get_env).
  doom_loop_max_calls: 2000,

  # Doom-loop *resample* recovery (grok's DoomLoopRecoverySettings). When a
  # detector flags a repetition / reasoning-only loop, DISCARD the offending
  # assistant response and re-sample the turn (re-rolling is the remedy, not
  # waiting) up to `max_retries` times with near-zero backoff, only then falling
  # back to the existing surface/permission-prompt/abort behavior.
  #   enabled     — master switch (default true)
  #   max_retries — resample budget per stuck stretch (default 2)
  #   backoff_ms  — delay between resamples (default 0 — the fix is re-rolling)
  #   threshold   — identical-call repeats before a loop is declared (default 4)
  doom_loop_resample: [enabled: true, max_retries: 2, backoff_ms: 0, threshold: 4],

  # Wall-clock ceiling on a single agent turn (the GenServer.call in
  # Loop.process_message). `:infinity` because the turn is already bounded
  # logically by max_iterations + max_budget_usd; a wall-clock cap here just
  # orphans a still-running hours-long turn. Callers may still pass an explicit
  # opts[:timeout].
  agent_turn_timeout_ms: :infinity,

  # Per-tool ceiling for the parallel tool-orchestrator path. NO LIMIT.
  #
  # This was 60s, then 300s, each raise chasing a workload that outgrew it. A
  # three-agent dispatch then blew past 300s too: the wrapper reported a tool
  # timeout and ended the turn, while the agents it had launched carried on in
  # the background and finished normally minutes later — the turn lost its own
  # work and nothing else stopped.
  #
  # A generic wrapper cannot know whether it is timing a 200ms file read or a
  # dispatch that legitimately runs for hours, so every number it picks is
  # wrong for one of them. The tools that need a bound carry their own
  # (shell_execute per-command, provider receive timeouts, bounded_compaction),
  # and an interrupt is always available. Set an integer here to reimpose one.
  tool_timeout_ms: :infinity,

  # When false, the stall detector escalates (graded nudges) but never hard-halts
  # a long read/analysis phase — appropriate for autonomous runs. The "autonomous"
  # preset sets this false; interactive sessions keep the hard halt.
  stall_hard_halt: true,
  temperature: 0.7,
  max_tokens: 4096,

  # Tool output truncation — raised from 10 KB to 50 KB so the agent can read
  # large files and see full build/test output without losing critical lines.
  max_tool_output_bytes: 51_200,

  # Context compaction thresholds (3-tier)
  compaction_warn: 0.80,
  compaction_aggressive: 0.85,
  compaction_emergency: 0.95,

  # Observability — OpenTelemetry GenAI export (primitive #30). Off by default:
  # no OTLP dependency is shipped, so this is an adapter seam. Set
  # `otel_enabled: true` and point `otel_adapter` at a module implementing
  # `OptimalSystemAgent.Observability.OTel` to export GenAI spans/attributes.
  # Structured, correlated per-session events are always on (see
  # `OptimalSystemAgent.Observability`) — only OTLP export is gated here.
  otel_enabled: false,
  otel_adapter: OptimalSystemAgent.Observability.OTel.Noop,

  # Proactive monitor interval (milliseconds)
  proactive_interval: 30 * 60 * 1000,

  # Proactive mode — autonomous greetings, notifications, and work (default: off)
  proactive_mode: false,

  # User config directory
  config_dir: Path.expand("~/.osa"),

  # Skills directory (SKILL.md files)
  skills_dir: Path.expand("~/.osa/skills"),

  # Auto-generate SKILL.md files from recurring SICA patterns. OFF by default:
  # a recurring tool outcome is telemetry, not a reusable skill. Even when true,
  # every candidate must pass Memory.SkillGenerator.skill_worthy?/1.
  auto_skill_generation: false,

  # Episodic memory directory (durable task-attempt episodes, JSON per session)
  episodic_dir: Path.expand("~/.osa/memory/episodic"),

  # MCP servers config
  mcp_config_path: Path.expand("~/.osa/mcp.json"),

  # ---------------------------------------------------------------------------
  # MCP — foreign-config import (OPT-IN)
  # ---------------------------------------------------------------------------
  # OSA can read the MCP servers you configured in OTHER tools (Claude Code,
  # Claude Desktop, Cursor, Codex) and run them itself. That is convenient but
  # it is also an unrequested grant: those entries spawn subprocesses and inject
  # tool definitions OSA's operator never chose, with no way to tell where they
  # came from. It is therefore OFF by default — OSA runs the servers you gave
  # OSA (`~/.osa/mcp.json`, the workspace `.mcp.json`, `.osa/mcp.local.json`)
  # and nothing else.
  #
  # Turn it on with either:
  #   config :optimal_system_agent, mcp_import_foreign: true
  #   ~/.osa/settings.json  →  {"mcp_import_foreign": true}
  mcp_import_foreign: false,

  # Which foreign tools are read when the import above is enabled. Trim this to
  # inherit from some tools but not others, e.g. `[:codex]`.
  mcp_import_sources: [:codex, :claude_code, :claude_desktop, :cursor],

  # Per-server deny list, honoured for EVERY source (OSA's own config, the
  # project `.mcp.json`, and any imported foreign config). Names are matched
  # after the usual `[a-z0-9_]` sanitization, so "task-master-ai" and
  # "task_master_ai" both match. Lets you kill one noisy server without
  # disabling a whole source:
  #   config :optimal_system_agent, mcp_exclude: ["serena"]
  #   ~/.osa/settings.json  →  {"mcp_exclude": ["serena"]}
  mcp_exclude: [],

  # Bootstrap files directory (IDENTITY.md, SOUL.md, USER.md)
  bootstrap_dir: Path.expand("~/.osa"),

  # Data directory
  data_dir: Path.expand("~/.osa/data"),

  # Sessions directory (JSONL files)
  sessions_dir: Path.expand("~/.osa/sessions"),

  # HTTP channel (SDK API surface)
  http_port: 9089,
  require_auth: false,

  # Interactive permission prompts. When true (default), the DEFAULT :ask mode
  # pauses for approval on mutating tools not covered by a saved rule — emitting
  # `permission_required` and parking until the client POSTs to
  # /api/v1/permissions/respond. Set false for unattended/headless use where no
  # responder is attached (the test env sets this off).
  interactive_permissions: true,

  # ---------------------------------------------------------------------------
  # Sandbox — Docker container isolation for skill execution
  # ---------------------------------------------------------------------------
  # Execution backend: :docker (OS-level isolation) or :beam (process-only).
  # Read by Sandbox.Router (sandbox/router.ex:59).
  #
  # The Docker knobs (image, network, memory/cpu caps, timeout, workspace mount,
  # allowed images, capability drop/add, read-only root, no-new-privileges) used
  # to live here as ~12 flat `sandbox_*` keys. `Sandbox.Docker` never read any of
  # them — it reads the nested `:sandbox_docker` map (sandbox/docker.ex:141) and
  # otherwise falls back to its own module attributes. The flat keys were removed
  # rather than left as decorative security settings that configure nothing.
  sandbox_mode: :docker,

  # NOTE: there are deliberately no `budget_*_limit_usd` keys here. `Budget` and
  # `Agent.Budget` read `:daily_budget_usd` / `:monthly_budget_usd` /
  # `:per_call_limit_usd` (budget/budget.ex:153, agent/budget.ex:114). The
  # `budget_*_limit_usd` spelling was a near-miss that read as a configured spend
  # cap while the code used its own defaults.

  # ---------------------------------------------------------------------------
  # Treasury — financial governance with transaction ledger
  # ---------------------------------------------------------------------------
  # `Budget.Treasury` has zero `Application.get_env` calls, so only the
  # enable flag is meaningful here; the limit keys configured nothing.
  treasury_enabled: false,

  # ---------------------------------------------------------------------------
  # Fleet — remote agent fleet registry with sentinel monitoring
  # ---------------------------------------------------------------------------
  fleet_enabled: false,

  # ---------------------------------------------------------------------------
  # Wallet — crypto wallet connectivity
  # ---------------------------------------------------------------------------
  # Only `:wallet_enabled` is read (tools/builtins/wallet_ops.ex:10).
  wallet_enabled: false,

  # ---------------------------------------------------------------------------
  # OTA Updater — secure updates with TUF verification
  # ---------------------------------------------------------------------------
  update_enabled: false,
  update_url: nil,
  update_interval: 86_400_000,

  # ---------------------------------------------------------------------------
  # OpenComputers — connects this OSA to MIOSA's control plane so the host
  # appears in the MIOSA frontend as an orchestrable Computer.
  # Opt-in via OSA_OPEN_COMPUTERS_ENABLED=true. When enabled, reads the
  # TOML at ~/.osa/open_computers.toml (or $OSA_OPEN_COMPUTERS_CONFIG) for
  # control_url + host_key + modes + fingerprint_path.
  # ---------------------------------------------------------------------------
  open_computers_enabled: false,

  # ---------------------------------------------------------------------------
  # Webhook Signature Secrets — set these to enable inbound signature verification
  # ---------------------------------------------------------------------------
  telegram_webhook_secret: nil,
  whatsapp_app_secret: nil,
  dingtalk_secret: nil,
  email_webhook_secret: nil,

  # ---------------------------------------------------------------------------
  # Memory recall + dynamic-context budgeting (Agent.Context / Memory.Store)
  # ---------------------------------------------------------------------------
  # Bounded, query-scored, threshold-gated recall (mirrors Grok's
  # MemorySearchConfig). Below-threshold entries are DROPPED, not truncated.
  memory_recall_max_results: 6,
  memory_recall_min_score: 0.35,
  # Hard token cap for the rendered "## Long-term Memory" block (and per-block
  # cap for any single RECALL-group block).
  memory_context_token_cap: 1_200,
  # Char cap for injected project context files (CLAUDE.md/AGENTS.md/...).
  project_context_char_cap: 8_000,
  # The RECALL block group (memory, episodic, project_context, skills,
  # learned_skills, agent_roles) is capped to this fraction of the REAL
  # effective context window — never the full leftover slack.
  dynamic_recall_budget_frac: 0.20,
  # Floor so a genuinely relevant memory still fits on small (8k) windows.
  dynamic_recall_budget_floor: 512

# Database — SQLite3
config :optimal_system_agent, OptimalSystemAgent.Store.Repo,
  database: Path.expand("~/.osa/osa.db"),
  pool_size: 5,
  journal_mode: :wal,
  # Ensure UTF-8 encoding for full Unicode support (Japanese, emoji, etc.)
  # This PRAGMA is effective only when creating a new database; for existing
  # databases it is a no-op (already locked to the creation-time encoding).
  custom_pragmas: [encoding: "'UTF-8'", busy_timeout: 5000]

config :optimal_system_agent, ecto_repos: [OptimalSystemAgent.Store.Repo]

# Post-edit format + diagnostics loop (gap analysis G1 + G2). After every
# file_edit / multi_file_edit / file_write / file_create, `Verify.PostEdit` runs
# on the touched file: it auto-formats in place (mix format in-process, gofmt,
# rustfmt, prettier, ruff) and runs a fast single-file syntax/parse check whose
# errors are injected back into the tool result the SAME turn — so the model sees
# the mistake it just made instead of editing blind. Wired via the pluggable
# `:diagnostics_provider` seam consumed by Agent.Reminders.collect_diagnostics/2.
# Disable with `post_edit_verify: [enabled: false]`.
config :optimal_system_agent,
  diagnostics_provider: {OptimalSystemAgent.Verify.PostEdit, :run},
  post_edit_verify: [enabled: true, timeout_ms: 8_000]

# Auto-mode safety Guardian. In :auto permission tier, the classifier blocks
# dangerous tool calls and the Guardian pauses unattended execution after
# `pause_after_blocks` blocked actions. `untrusted_host_allowlist` names the
# hosts network tools (curl/wget/ssh/…) may reach without raising a caution.
config :optimal_system_agent, :auto_mode,
  pause_after_blocks: 3,
  # Optional model-based risk classifier (#34). When `enabled: true`, ambiguous
  # tool calls the rules did not flag as dangerous are additionally scored by the
  # LLM (with a pure heuristic fallback), and a dangerous verdict from EITHER the
  # rules OR the model blocks. OFF by default — rule-based behavior is unchanged.
  model_classifier: [
    enabled: false,
    provider: nil,
    model: nil,
    max_tokens: 128
  ],
  # Opt-in auto-permission classifier (P2 #19, grok permission/auto_mode.rs). When
  # `enabled: true`, before OSA surfaces the DEFAULT interactive :ask prompt for a
  # mutating tool call, a fast-path (structured shell parser) + optional cheap LLM
  # verdict may DOWNGRADE that ask to :allow. It can only downgrade the default
  # ask — never overrides a deny/catastrophic/safety-ask/explicit-ask-rule — and
  # fails safe to the prompt on any doubt. OFF by default (behavior unchanged).
  auto_allow: [
    enabled: false,
    use_llm: true,
    provider: nil,
    model: nil,
    max_tokens: 64,
    context_turns: 6
  ],
  untrusted_host_allowlist: [
    "github.com",
    "raw.githubusercontent.com",
    "api.github.com",
    "gitlab.com",
    "pypi.org",
    "files.pythonhosted.org",
    "registry.npmjs.org",
    "npmjs.com",
    "hex.pm",
    "repo.hex.pm",
    "crates.io",
    "static.crates.io",
    "golang.org",
    "proxy.golang.org",
    "sum.golang.org",
    "anthropic.com",
    "api.anthropic.com",
    "openai.com",
    "api.openai.com"
  ]

config :logger,
  level: :warning

import_config "#{config_env()}.exs"
