defmodule OptimalSystemAgent.Observability do
  @moduledoc """
  Structured observability for the agent loop (primitive #30).

  Two responsibilities, both additive and side-effect-light:

    1. **Correlated structured events.** Key turn-lifecycle points (turn
       start/end, model request/response, tool call start/end, compaction,
       errors) emit through `OptimalSystemAgent.Events.Bus` with the session id
       and a per-turn correlation id (`turn_id`, a `prompt.id`-style field)
       threaded into the CloudEvent *envelope* (opts) rather than only the
       payload. Because `Events.Bus` appends any event that carries a
       `session_id` to the durable per-session `Events.Stream`, this makes the
       lifecycle a replayable, correlated log — the thing session replay needs.

    2. **OpenTelemetry GenAI spans.** The same call sites forward GenAI
       semantic-convention attributes to `OptimalSystemAgent.Observability.OTel`,
       which is a no-op unless an OTLP adapter is configured.

  The correlation id is minted once per turn by `new_turn_id/0` and stored on
  the loop state (`state.turn_id`). `annotate/2` produces the envelope keyword
  used by callers that emit through `Bus.emit/3` directly (e.g. the tool
  executor), keeping the correlation logic in one place.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Observability.OTel

  @doc """
  Mint a per-turn correlation id (a `prompt.id`-style field).

  Format: `"prompt_<microsecond-ts>_<random>"`.
  """
  @spec new_turn_id() :: String.t()
  def new_turn_id do
    ts = System.system_time(:microsecond)
    rand = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "prompt_#{ts}_#{rand}"
  end

  @doc """
  Build the CloudEvent envelope (opts) for a lifecycle event from loop state.

  Threads `session_id` + `correlation_id` (the per-turn `turn_id`) so the event
  lands in the durable per-session `Events.Stream`. Extra opts win over the
  defaults and may override `:source`.
  """
  @spec annotate(map(), keyword()) :: keyword()
  def annotate(state, extra \\ []) when is_map(state) do
    Keyword.merge(
      [
        session_id: Map.get(state, :session_id),
        correlation_id: Map.get(state, :turn_id),
        source: "agent.loop"
      ],
      extra
    )
  end

  @doc """
  Emit a structured lifecycle event correlated to the current turn.

  Best-effort — never raises. `type` must be one of `Events.Bus` known types
  (turn lifecycle uses `:system_event` with an `event:` discriminator, matching
  the budget/compaction convention).
  """
  @spec emit(atom(), map(), map(), keyword()) :: :ok
  def emit(type, payload, state, extra \\ []) when is_map(payload) and is_map(state) do
    Bus.emit(type, payload, annotate(state, extra))
    :ok
  rescue
    e ->
      Logger.debug("[observability] emit failed: #{inspect(e)}")
      :ok
  end

  @doc """
  Emit a `:turn_start` lifecycle event + open a GenAI turn span.

  Carries the **effort level in force** (`:fast | :medium | :high | :xhigh |
  :ultra`). Reasoning effort moves the same model under a fixed harness by more
  than the harness itself does — Anthropic measured 10.3 points on Opus 4.6
  (55.1 low → 65.4 max) against a 7.2-point harness delta — so a number
  produced without a recorded effort setting is not reproducible and cannot be
  set beside any published figure. Every published leaderboard row names it;
  so must every OSA run.
  """
  @spec turn_start(map()) :: :ok
  def turn_start(state) do
    effort = current_effort()

    emit(
      :system_event,
      %{
        event: :turn_start,
        turn_id: Map.get(state, :turn_id),
        turn_count: Map.get(state, :turn_count),
        model: Map.get(state, :model),
        effort: effort,
        reasoning: current_reasoning(state),
        unobserved_background: unobserved_background_count(state)
      },
      state,
      source: "agent.turn"
    )

    OTel.emit(
      :turn,
      OTel.gen_ai_attributes(
        operation: "turn",
        model: Map.get(state, :model),
        effort: effort,
        conversation_id: Map.get(state, :session_id)
      )
    )

    :ok
  end

  @doc """
  The effort level in force, as a string, or `nil` when it cannot be resolved.

  `nil` is meaningful and is recorded as-is: it means the run was **unpinned**,
  which is exactly the condition that makes a benchmark number unquotable.
  Never substitute a plausible-looking default here.
  """
  @spec current_effort() :: String.t() | nil
  def current_effort do
    OptimalSystemAgent.Agent.Effort.current() |> to_string()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc "Emit a `:turn_end` lifecycle event with response size + running spend."
  @spec turn_end(map(), term()) :: :ok
  def turn_end(state, response) do
    emit(
      :system_event,
      %{
        event: :turn_end,
        turn_id: Map.get(state, :turn_id),
        iterations: Map.get(state, :iteration),
        response_bytes: response_bytes(response),
        session_cost_usd: Map.get(state, :session_cost_usd),
        # Recorded on BOTH ends of the turn: `/effort` can be changed mid-run,
        # so a turn that started at one tier can finish at another. A single
        # start-only reading would attribute the whole turn to the wrong level.
        effort: current_effort(),
        reasoning: current_reasoning(state),
        unobserved_background: unobserved_background_count(state)
      },
      state,
      source: "agent.turn"
    )
  end

  @doc """
  How many background commands this session started are still running.

  Recorded on both ends of every turn, next to `effort` and `reasoning`, and
  for the same reason: it is the condition a turn ran under. A turn that ENDS
  with this above zero and no tool calls is the shape `VerificationGate`
  clause 0 refuses — measured at 9 of 19 model failures and 0 of 34 solves on
  `bench/terminalbench/runs/osa-tb20-full89-f6981b61`. Every defect found in
  that arm had been silent; this one is on the wire from the first turn.

  Never raises and never blocks: any failure reads as `0`.
  """
  @spec unobserved_background_count(map()) :: non_neg_integer()
  def unobserved_background_count(state) do
    state
    |> Map.get(:session_id)
    |> OptimalSystemAgent.Agent.Loop.VerificationGate.unobserved_background()
    |> length()
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  @doc """
  Whether model reasoning is enabled for this turn, and why — or `nil` when the
  provider/model has no such setting.

  Same rationale as `current_effort/0`: reasoning moves a model's score more
  than the harness does (cline measured 68.5% vs 57.3% on Terminal-Bench 2.0 for
  `glm-5.2` with and without it), so a run that does not record the condition is
  not reproducible and cannot be set beside a published figure.

  Rendered as `"on:cloud_default"` / `"off:local_stall_guard"` / `"on:config"` —
  the value AND the rule that produced it, so a benchmark row states not just
  what was in force but whether the operator chose it or inherited a default.
  """
  @spec current_reasoning(map()) :: String.t() | nil
  def current_reasoning(state) do
    model = Map.get(state, :model)

    case normalize_provider(Map.get(state, :provider)) do
      :ollama when is_binary(model) ->
        case OptimalSystemAgent.Providers.Ollama.reasoning_decision(model, []) do
          {nil, _} -> nil
          {true, source} -> "on:#{source}"
          {false, source} -> "off:#{source}"
        end

      # Anthropic-native. `thinking_decision/1` is the same request-scoped
      # decision the request path makes, so what is recorded here is what was
      # sent — not a re-derivation that could disagree with it.
      :anthropic ->
        case OptimalSystemAgent.Agent.Loop.LLMClient.thinking_decision(state) do
          {nil, source} -> "off:#{source}"
          {_config, source} -> "on:#{source}"
        end

      :bedrock when is_binary(model) ->
        case OptimalSystemAgent.Providers.Bedrock.reasoning_decision(model, []) do
          {nil, source} -> "off:#{source}"
          {budget, source} -> "on:#{source}:#{budget}"
        end

      :google when is_binary(model) ->
        case OptimalSystemAgent.Providers.Google.build_thinking_config(model, []) do
          %{thinkingLevel: level} -> "on:level:#{level}"
          %{thinkingConfig: %{thinkingBudget: n}} -> "on:budget:#{n}"
          _ -> "off:model_has_none"
        end

      # Everything routed through `OpenAICompat` — openrouter, groq, together,
      # fireworks, deepseek, perplexity, mistral, cerebras, sambanova,
      # hyperbolic, qwen, moonshot, zhipu, volcengine, baichuan, miosa,
      # lmstudio and every user-defined base_url, plus :openai itself.
      #
      # This clause is the point of the exercise. `reasoning` was `nil` here —
      # and `nil` on this field is DOCUMENTED above as meaning "the
      # provider/model has no such setting". It was recorded for the ~19
      # providers that have one, so the single instrument built to stop
      # reasoning being silent was itself silent on the majority of the fleet:
      # a benchmark row from an OpenRouter run stated `effort=ultra` beside
      # `reasoning=` blank, and both the effort ladder being inert
      # (`OpenAICompat.reasoning_decision/2` documents that defect) and the
      # ladder working produce exactly that same row.
      provider when is_atom(provider) and not is_nil(provider) and is_binary(model) ->
        # Membership comes from `Registry.compat_routed?/1`, which is derived
        # from `@providers` at compile time. Asking a hand-written list here
        # would be the same drift that put six compat providers on the wrong
        # billing convention in `Loop.Accounting`; asking every provider would
        # report a decision `:claude_cli` / `:openai_codex` / `:cohere` never
        # make.
        if OptimalSystemAgent.Providers.Registry.compat_routed?(provider) do
          case OptimalSystemAgent.Providers.OpenAICompat.reasoning_decision(model, []) do
            {nil, source} -> "off:#{source}"
            {value, source} -> "on:#{source}:#{value}"
          end
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp normalize_provider(p) when is_atom(p) and not is_nil(p), do: p
  defp normalize_provider(p) when is_binary(p), do: String.to_existing_atom(p)
  defp normalize_provider(_), do: nil

  @doc "Emit a structured `:compaction` event correlated to the current turn."
  @spec compaction(map(), map()) :: :ok
  def compaction(state, metrics) when is_map(metrics) do
    emit(:system_event, Map.put(metrics, :event, :compaction), state, source: "agent.compaction")
  end

  @doc "Forward a GenAI `chat` request span (pre-call, no usage yet)."
  @spec otel_model_request(map()) :: :ok
  def otel_model_request(state) do
    OTel.emit(
      :chat,
      OTel.gen_ai_attributes(
        operation: "chat",
        model: Map.get(state, :model),
        effort: current_effort(),
        conversation_id: Map.get(state, :session_id)
      )
    )
  end

  @doc "Forward a GenAI `chat` response span carrying real token usage."
  @spec otel_model_response(map(), map() | nil) :: :ok
  def otel_model_response(state, usage) do
    OTel.emit(
      :chat,
      OTel.gen_ai_attributes(
        operation: "chat",
        model: Map.get(state, :model),
        conversation_id: Map.get(state, :session_id),
        usage: usage
      )
    )
  end

  @doc "Forward a GenAI `execute_tool` span."
  @spec otel_tool(map(), String.t()) :: :ok
  def otel_tool(state, tool_name) do
    OTel.emit(
      :execute_tool,
      OTel.gen_ai_attributes(
        operation: "execute_tool",
        tool_name: tool_name,
        model: Map.get(state, :model),
        conversation_id: Map.get(state, :session_id)
      )
    )
  end

  # --- Private ---

  defp response_bytes(bin) when is_binary(bin), do: byte_size(bin)
  defp response_bytes(_), do: 0
end
