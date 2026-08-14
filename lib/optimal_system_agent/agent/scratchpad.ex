defmodule OptimalSystemAgent.Agent.Scratchpad do
  @moduledoc """
  Provider-agnostic thinking/scratchpad support.

  For Anthropic: uses native extended thinking (no-op here).
  For all other providers: injects a `<think>` prompt instruction into the
  system message and parses `<think>...</think>` blocks out of responses.

  Extracted thinking is:
    - Removed from the displayed response text
    - Emitted as `:thinking_captured` bus events for the learning engine
    - Emitted as `:thinking_delta` system events for TUI display
  """

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Trajectory

  @think_instruction """
  ## Private Reasoning

  Before responding or taking actions, reason step-by-step inside \
  <think>...</think> tags. Use this space to:
  - Analyze the request and break it into sub-problems
  - Consider edge cases, risks, and alternative approaches
  - Plan your tool calls before executing them
  - Reflect on previous results before deciding next steps

  Content inside <think> tags is captured for learning but NOT shown to the user. \
  Your visible response should contain only the final answer or action — never the \
  reasoning process.
  """

  # Regex to match <think>...</think> blocks (including multiline).
  # Captures the inner content. Uses dotall via the `s` flag.
  @think_pattern ~r/<think>(.*?)<\/think>/s

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Should this request carry the `<think>` scaffold?

  The scaffold exists to give a turn a reasoning space when the wire protocol
  does not provide one. So the question it must answer is **"does THIS request
  carry native thinking?"** — and for a long time it answered a different one:

      enabled and provider != :anthropic

  `provider != :anthropic` was standing in for "has no native thinking", and it
  is wrong in both directions.

    * **Anthropic with thinking off got neither.** `:fast` effort,
      `thinking_enabled: false`, or a model whose `AnthropicModels.thinking_mode/1`
      is `:none` all produce `{nil, _}` from `LLMClient.thinking_decision/1` — no
      `thinking` field on the wire — while the provider atom is still
      `:anthropic`, so the scaffold stayed suppressed. That turn reasoned in
      neither channel, silently.
    * **Providers with native reasoning ON got it twice.** An Ollama *cloud*
      model defaults to `think: true` (`{true, :cloud_default}`), and a Bedrock
      Claude gets a `reasoningConfig` budget — both are `provider != :anthropic`,
      so both were told to also hand-roll `<think>` tags around a response the
      provider was already splitting into a reasoning channel.

  It now asks the real question, through the `{value, source}` seams that exist
  for it: `LLMClient.thinking_decision/1`, `Ollama.reasoning_decision/2`,
  `Bedrock.reasoning_decision/2`. No parallel mechanism, no second copy of the
  model tables.

  ## OpenRouter-hosted `anthropic/*`

  Worth stating because it is the intuitive-but-wrong case: `anthropic/claude-*`
  served through OpenRouter is `provider == :openrouter`, and it is **not**
  getting native thinking today. `OpenAICompat.maybe_add_provider_thinking/4`
  only fires for a DeepSeek endpoint and `maybe_add_reasoning/3` is gated by
  `reasoning_model?/1`, which excludes Anthropic ids — so OSA sends that route no
  `thinking` and no `reasoning_effort` at all. It is scratchpad-only, and asking
  the real question keeps it that way. Suppressing the scaffold there on the
  grounds that "it's a Claude" would remove the turn's only reasoning space,
  which is the first defect above wearing a different hat.

  ## Prefix stability

  The answer feeds a cached system-prompt block, so it must be constant for a
  fixed model + config within a session. It is: every input is either the model
  id, an `Application.get_env` value, or the effort level. Effort is runtime
  mutable (`/effort`), and flipping it to/from `fast` on Anthropic will flip this
  block and cost one cache miss — but `/effort` already rewrites the `thinking`
  field of every subsequent request, so it is a deliberate reconfiguration and
  not a per-turn wobble.

  Accepts the loop state (preferred — it carries the model) or a bare provider
  atom (legacy callers; the model then resolves from config).
  """
  @spec inject?(atom() | map()) :: boolean()
  def inject?(provider_or_state) do
    {value, source} = decision(provider_or_state)

    emit_decision(value, source)

    value
  end

  @doc """
  `inject?/1` with its reason attached — the `{value, source}` shape the
  provider capability seams use, so a caller (or a test, or `Observability`) can
  ask *why* a turn has or has not got a scaffold without re-deriving it.

  Sources:

    * `:disabled_by_config` — `:scratchpad_enabled` is false. Deliberate.
    * `:native_thinking` — the provider is carrying reasoning itself; a scaffold
      would be a second, redundant channel.
    * `:no_native_thinking` — nothing native on this request, so the scaffold is
      the turn's only reasoning space.
  """
  @spec decision(atom() | map()) :: {boolean(), atom()}
  def decision(provider_or_state) do
    if Application.get_env(:optimal_system_agent, :scratchpad_enabled, true) do
      if native_thinking?(provider_or_state),
        do: {false, :native_thinking},
        else: {true, :no_native_thinking}
    else
      {false, :disabled_by_config}
    end
  end

  # "Is a reasoning channel already on the wire for this request?"
  #
  # Each provider is asked through ITS OWN decision seam rather than through a
  # table kept here, so a change to (say) Ollama's cloud default cannot leave
  # this module disagreeing with the request that actually goes out.
  defp native_thinking?(state) when is_map(state) do
    provider = normalize_provider(Map.get(state, :provider) || default_provider())

    # Whether a request carries native thinking is a MODEL fact, so a nil model
    # has to be resolved the same way the request itself resolves it — otherwise
    # a legacy `inject?(:ollama)` caller and the actual round-trip could disagree
    # about the very same turn. `resolved_default_model/1` is the config lookup
    # `Loop.init/1` uses.
    model = Map.get(state, :model) || default_model(provider)

    case provider do
      :anthropic ->
        # `thinking_decision/1` wants provider + model; a bare atom caller has
        # no model, and its Anthropic branch already falls back to the
        # configured default in that case.
        {config, _source} =
          OptimalSystemAgent.Agent.Loop.LLMClient.thinking_decision(%{
            provider: :anthropic,
            model: model
          })

        not is_nil(config)

      :ollama ->
        # `nil` here means "send no `think` field" — i.e. no native reasoning.
        match?({true, _}, OptimalSystemAgent.Providers.Ollama.reasoning_decision(model))

      :bedrock ->
        {budget, _source} = OptimalSystemAgent.Providers.Bedrock.reasoning_decision(model)
        not is_nil(budget)

      _ ->
        false
    end
  end

  defp native_thinking?(provider), do: native_thinking?(%{provider: provider, model: nil})

  defp normalize_provider({:compat, p}), do: normalize_provider(p)
  defp normalize_provider(p) when is_atom(p), do: p
  # `to_existing_atom` and not `to_atom`: an unrecognised provider name off the
  # wire must not grow the atom table, and "I don't know it" is already the
  # right answer here — an unknown provider has no native thinking we can name.
  defp normalize_provider(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> nil
  end

  defp normalize_provider(_), do: nil

  defp default_provider,
    do: Application.get_env(:optimal_system_agent, :default_provider, :ollama)

  defp default_model(provider) when is_atom(provider) and not is_nil(provider) do
    OptimalSystemAgent.Providers.Registry.resolved_default_model(provider)
  rescue
    _ -> nil
  end

  defp default_model(_), do: nil

  # A capability decision that turns something off has to be findable. Telemetry
  # rather than a log line because this is asked several times per turn and a
  # per-call log at info would be noise, which is its own way of being invisible.
  defp emit_decision(value, source) do
    :telemetry.execute(
      [:osa, :scratchpad, :decision],
      %{injected: if(value, do: 1, else: 0)},
      %{source: source}
    )
  rescue
    _ -> :ok
  end

  @doc """
  Returns the scratchpad system instruction to inject into the prompt.
  Only call this when `inject?/1` returns true.
  """
  @spec instruction() :: String.t()
  def instruction, do: @think_instruction

  @doc """
  Extracts `<think>...</think>` blocks from response text.

  Returns `{clean_text, thinking_parts}` where:
    - `clean_text` is the response with all `<think>` blocks removed
    - `thinking_parts` is a list of extracted thinking strings
  """
  @spec extract(String.t() | nil) :: {String.t(), [String.t()]}
  def extract(nil), do: {"", []}
  def extract(""), do: {"", []}

  def extract(text) when is_binary(text) do
    thinking_parts =
      @think_pattern
      |> Regex.scan(text)
      |> Enum.flat_map(fn
        [_full, inner] when is_binary(inner) -> [String.trim(inner)]
        _ -> []
      end)
      |> Enum.reject(&(&1 == ""))

    clean_text =
      text
      |> String.replace(@think_pattern, "")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    {clean_text, thinking_parts}
  end

  @doc """
  Processes an LLM response: extracts thinking, emits events, returns clean text.

  This is the main entry point called from the agent loop after receiving
  a response from a non-Anthropic provider.
  """
  @spec process_response(String.t() | nil, String.t()) :: String.t()
  def process_response(text, session_id) do
    {clean_text, thinking_parts} = extract(text)

    if thinking_parts != [] do
      # Same rule as the streaming `:thinking_delta` path in Loop.LLMClient:
      # reasoning quotes file contents verbatim, and both events below end up
      # on screen or on disk. Redact before either emission.
      combined_thinking =
        thinking_parts |> Enum.join("\n\n---\n\n") |> Trajectory.redact()

      # Emit thinking delta for TUI display
      Bus.emit(:system_event, %{
        event: :thinking_delta,
        session_id: session_id,
        text: combined_thinking
      })

      # Emit thinking_captured for learning engine
      Bus.emit(:system_event, %{
        event: :thinking_captured,
        session_id: session_id,
        text: combined_thinking
      })
    end

    clean_text
  end
end
