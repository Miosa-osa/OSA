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

    * `maybe_compact/3`  — inspect and possibly compact a message list.
    * `estimate_tokens/1` — token estimate for a string or message list.
    * `utilization/1`    — context-window utilization percentage (0.0–1.0).

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
  3. Call sites invoke `ContextEngine.Router.maybe_compact/3` etc. which
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
  (0 if unknown). `session_id` identifies the session for logging/metrics.

  Returns the (possibly unchanged) message list. Never crashes — on any
  error the original messages are returned unmodified.
  """
  @callback maybe_compact(
              messages :: messages(),
              known_tokens :: token_count(),
              session_id :: String.t() | nil
            ) :: compact_result()

  @doc """
  Estimate the token count for a binary string or a list of messages.

  Used by the loop, telemetry, and proactive-compaction modules to decide
  when to trigger compaction. Must be fast (no LLM calls) and deterministic.
  """
  @callback estimate_tokens(input :: String.t() | messages() | nil) :: token_count()

  @doc """
  Context-window utilization as a PERCENTAGE (0.0 to 100.0+).

  Values > 100.0 mean the message list already exceeds the configured window.
  Note this is a percentage, not a 0.0–1.0 fraction: `Telemetry` and the TUI
  status bar render the returned number directly followed by a `%` sign, and
  `ProactiveCompaction` compares it against percentage thresholds. An engine
  that returns a fraction here will read as ~1% full and never compact.
  """
  @callback utilization(messages :: messages()) :: float()

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
                      stats: 0,
                      start_link: 1
end
