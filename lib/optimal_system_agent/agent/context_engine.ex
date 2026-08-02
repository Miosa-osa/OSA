defmodule OptimalSystemAgent.Agent.ContextEngine do
  @moduledoc """
  Behaviour for pluggable context-compaction engines.

  The default implementation is `OptimalSystemAgent.Agent.Compactor`, which
  provides sliding-window zone-based compaction with importance-weighted
  retention. Third-party engines can replace it by implementing this
  behaviour and registering via config:

      # ~/.osa/config.toml
      [context]
      engine = "my_engine"

      # config/config.exs
      config :optimal_system_agent, :context_engine, :my_engine

  Or by setting the module directly:

      config :optimal_system_agent, :context_engine_module, MyApp.ContextEngine

  The active engine is resolved by `ContextEngine.Router.active/0` and all
  call sites should go through the Router rather than calling a specific
  implementation module directly.

  ## Required callbacks

    * `maybe_compact/4`  — inspect and possibly compact a message list.
    * `estimate_tokens/1` — token estimate for a string or message list.
    * `utilization_percent/2` — context-window utilization, 0.0–100.0 PERCENT
      or `:unknown`.

  ## Optional callbacks

    * `micro_compact/1`       — P5 token-protected prune tier (standalone).
    * `format_for_summary/1`  — media-strip + tool-output-cap text formatter.
    * `stats/0`               — compaction metrics from the engine.
    * `start_link/1`          — GenServer lifecycle (if the engine is stateful).

  Engines that don't need a GenServer can skip `start_link/1` — the Router
  will simply not start one. `stats/0` can return an empty map for stateless
  engines.

  ## Lifecycle

  1. The engine module is resolved at boot by `ContextEngine.Router`.
  2. If the module exports `start_link/1`, it is placed under the AgentServices
     supervisor.
  3. Call sites invoke `ContextEngine.Router.maybe_compact/4` etc. which
     delegate to the active engine.
  4. On config change (settings watcher), the Router re-resolves the module.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type messages :: list(message())
  @type compact_result :: messages()
  @type token_count :: non_neg_integer()

  @doc """
  Inspect `messages` and return a possibly-compacted list.

  `known_tokens` is the last reported input-token count from the provider
  (0 or nil if unknown). `session_id` identifies the session for logging and
  metrics.

  `opts` carries the decision inputs an engine MUST honour:

    * `:context_window` — the real per-model window for this session. An engine
      must not substitute a constant when this is absent: a fabricated
      denominator is what made the built-in compactor fire at ~11% of a 1M
      window. Defer instead, and let the overflow path below force the issue.
    * `:force` — the provider has already returned a context-length error. This
      is the real overflow signal; compact even when the window is unresolvable.

  Returns the (possibly unchanged) message list. Never crashes — on any
  error the original messages are returned unmodified.
  """
  @callback maybe_compact(
              messages :: messages(),
              known_tokens :: token_count() | nil,
              session_id :: String.t() | nil,
              opts :: keyword()
            ) :: compact_result()

  @doc """
  Estimate the token count for a binary string or a list of messages.

  Used by the loop, telemetry, and proactive-compaction modules to decide
  when to trigger compaction. Must be fast (no LLM calls) and deterministic.
  """
  @callback estimate_tokens(input :: String.t() | messages() | nil) :: token_count()

  @doc """
  Context-window utilization as a PERCENT in 0.0..100.0 — not a 0.0..1.0
  fraction. The unit is in the name for a reason: the TUI status bar renders
  this number directly followed by a `%`, and threshold comparisons are against
  percentages, so an engine returning a fraction reads as ~1% full and never
  compacts.

  `context_window` takes the same shapes as `maybe_compact/4`'s
  `:context_window` option. Return `:unknown` — never a number — when the
  window cannot be resolved. A percentage of a fabricated denominator is worse
  than no percentage at all; that substitution is what made the built-in
  compactor summarize a 1M-token session at ~11% occupancy.

  Optional: no call site in the tree requires it today. It is declared so a
  third-party engine implements the same unit and the same `:unknown` contract
  as the built-in, rather than reinventing both.
  """
  @callback utilization_percent(
              messages :: messages(),
              context_window :: term()
            ) :: float() | :unknown

  @doc """
  P5 token-protected prune: strip redundant tool-call details from recent
  messages without touching the hot zone. Standalone — does not trigger
  the full compression pipeline.

  Optional: engines that don't implement this should return messages
  unchanged.
  """
  @callback micro_compact(messages :: messages()) :: compact_result()

  @doc """
  Strip media (images, base64) and cap tool-output text for summarization
  prompts. Returns a single flattened text blob suitable for embedding in an
  LLM summarization prompt — NOT a message list. Both built-in engines
  (`Compactor`, `Noop`) return a `String.t()` here.

  Optional: engines that don't implement this get the Router's fallback.
  """
  @callback format_for_summary(messages :: messages()) :: String.t()

  @doc """
  Return compaction metrics (compactions performed, tokens saved, etc.).

  Optional: stateless engines return `%{}`.
  """
  @callback stats() :: map()

  @doc """
  GenServer lifecycle. If the engine is stateful, it starts a process to
  hold metrics/state. If stateless, this can be omitted.

  Optional: omit for stateless engines.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @optional_callbacks micro_compact: 1,
                      format_for_summary: 1,
                      utilization_percent: 2,
                      stats: 0,
                      start_link: 1
end
