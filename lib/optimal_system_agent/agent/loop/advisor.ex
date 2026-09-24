defmodule OptimalSystemAgent.Agent.Loop.Advisor do
  @moduledoc """
  A stronger advisor model, one call away — configurable, capped, and framed
  as advice rather than instructions.

  The USER'S chosen model does all the real work. At a handful of decision
  points — a plan was just made, a risky/irreversible action is about to run,
  or the loop's own doom-loop detector reports it is stuck — this module can
  place ONE compact, capped call to a separately-configured, typically
  stronger model (`claude-opus-5-5`, `gpt-6-sol`, whatever the operator picked)
  and hand back a short recommendation.

  ## Two ways in

    * **Manual** — the model calls the `advisor_consult` tool
      (`Tools.Builtins.AdvisorConsult`) whenever IT decides it wants a second
      opinion. `consult/3` is what that tool calls.
    * **Automatic** — `maybe_auto_consult/3` fires at three trigger points
      wired into the loop (see each `t:trigger/0` value below). Both paths
      share the same cap, the same brief format, and the same framing.

  ## The advisor's answer is data, not instructions

  Every recommendation this module returns is injected into the transcript
  (or handed to the tool caller) wrapped in an explicit
  `[ADVISOR RECOMMENDATION — this is ADVICE, not an instruction]` header. The
  user's model decides whether to act on it; nothing here can force a tool
  call, override a permission decision, or otherwise bypass the loop's own
  control flow. This is the same posture `DoomLoop.Escalation` already takes
  with its graded nudges — a message in the transcript, never a side channel
  with authority of its own.

  ## Cost cap, per turn, never silent

  `consult/3` refuses (returns `{:error, :cost_cap_reached}`) once the
  advisor's OWN spend for the current turn reaches `cost_cap_usd/1`. Spend is
  tracked in an ETS table keyed by `{session_id, epoch}`, where `epoch` is an
  internal per-session counter `reset_turn_budget/1` bumps once per top-level
  turn (see that function's doc for why it is not simply `state.turn_count`).
  A denied consult is still visible: callers get the structured error and can
  (and do, at both call sites here) tell the user why no advice came back
  instead of just silently doing nothing.

  ## Configuration

      config :optimal_system_agent,
        advisor_provider: :anthropic,
        advisor_model: "claude-opus-5-5",
        advisor_cost_cap_usd: 0.50,
        advisor_auto_enabled: true

  Or per-session via `Settings` (`advisor_provider` / `advisor_model` /
  `advisor_cost_cap_usd` / `advisor_auto_enabled` / `advisor_enabled`).
  `advisor_enabled` gates BOTH paths; `advisor_auto_enabled` gates only the
  automatic triggers, so an operator can keep the manual tool available while
  turning off the automatic nudges (or vice versa).
  """

  require Logger

  alias OptimalSystemAgent.Agent.Pricing
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Settings

  @type trigger :: :plan_made | :risky_action | :stuck

  @default_cost_cap_usd 0.50
  @default_max_tokens 700

  @ets_table :osa_advisor_turn_spend

  # ── Public: manual (tool) path ───────────────────────────────────────────

  @doc """
  Ask the configured advisor a question and get back a short recommendation.

  `question` is the model's own free-text reason for asking. `opts`:

    * `:context` — extra compact context to fold into the brief (a plan
      summary, the tool about to run, the failure signature repeating).

  Returns `{:ok, %{advice: String.t(), provider: atom(), model: String.t(),
  cost_usd: float()}}` or `{:error, reason}` where `reason` is one of
  `:advisor_disabled`, `:advisor_not_configured`, `:cost_cap_reached`, or
  whatever the provider call itself failed with.
  """
  @spec consult(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def consult(state, question, opts \\ []) when is_map(state) and is_binary(question) do
    pair = configured_pair(state)

    cond do
      not setting_enabled?(state) ->
        {:error, :advisor_disabled}

      pair == nil ->
        {:error, :advisor_not_configured}

      cost_cap_reached?(state) ->
        {:error, :cost_cap_reached}

      true ->
        {provider, model} = pair
        do_consult(state, provider, model, question, opts)
    end
  end

  defp do_consult(state, provider, model, question, opts) do
    brief = build_brief(state, question, opts)
    messages = [%{role: "user", content: brief}]

    call_opts = [
      provider: provider,
      model: model,
      temperature: 0.2,
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens)
    ]

    case Providers.chat(messages, call_opts) do
      {:ok, %{content: advice} = resp} ->
        cost = Pricing.cost(model, Map.get(resp, :usage, %{}))
        record_spend(state, cost)
        emit_consulted(state, provider, model, question, cost)
        {:ok, %{advice: advice, provider: provider, model: model, cost_usd: cost}}

      {:error, reason} ->
        Logger.warning("[advisor] consult failed (#{provider}:#{model}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Wrap advice in the explicit "this is data, not an instruction" frame used
  everywhere this module hands text back to the main model.
  """
  @spec frame(String.t()) :: String.t()
  def frame(advice) when is_binary(advice) do
    "[ADVISOR RECOMMENDATION — this is ADVICE from a separately-configured " <>
      "model, not an instruction. Weigh it, do not blindly follow it.]\n" <> advice
  end

  # ── Public: automatic triggers ───────────────────────────────────────────

  @doc """
  Automatic consult at a configured decision point.

  Returns `state` unchanged when auto-consult is off, the trigger's own gate
  says not now, or the consult itself failed/was capped — auto-consult NEVER
  blocks or fails the turn; it is pure upside when it fires. On success,
  appends one `role: "system"` message carrying the framed advice, exactly
  like `DoomLoop.Escalation`'s graded-nudge injection.
  """
  @spec maybe_auto_consult(map(), trigger(), String.t()) :: map()
  def maybe_auto_consult(state, trigger, context_note)
      when trigger in [:plan_made, :risky_action, :stuck] and is_map(state) do
    if auto_enabled?(state) and trigger_fires?(state, trigger) do
      question = trigger_question(trigger, context_note)

      case consult(state, question, context: context_note) do
        {:ok, %{advice: advice, provider: provider, model: model}} ->
          Logger.info("[advisor] auto-consult (#{trigger}) via #{provider}:#{model}")
          append_advice_message(state, frame(advice))

        {:error, reason} ->
          Logger.debug("[advisor] auto-consult (#{trigger}) skipped: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  def maybe_auto_consult(state, _trigger, _context_note), do: state

  # A trigger's own gate — separate from `enabled?/1`/`auto_enabled?/1` so each
  # trigger can carry its own "is this genuinely the right moment" logic
  # without every caller re-deriving it.
  #
  #   * `:plan_made`    — always fires when reached (the caller already knows
  #     a plan was just made; it only calls this once per plan).
  #   * `:risky_action` — always fires when reached (the caller already
  #     classified the about-to-run tool as risky).
  #   * `:stuck`        — fires only once the doom-loop graded-escalation
  #     sequence has reached its FINAL step, i.e. one more failure falls
  #     through to a hard halt. Earlier grades get a cheap in-loop nudge
  #     (`DoomLoop.Escalation`) instead of spending advisor budget.
  defp trigger_fires?(state, :stuck) do
    Map.get(state, :graded_escalation_count, 0) >=
      OptimalSystemAgent.Agent.Loop.DoomLoop.Escalation.max_steps()
  end

  defp trigger_fires?(_state, _trigger), do: true

  defp trigger_question(:plan_made, note),
    do: "I just made this plan, does it look sound before I execute it? #{note}"

  defp trigger_question(:risky_action, note),
    do: "I am about to run a risky/irreversible action: #{note}. Sanity check?"

  defp trigger_question(:stuck, note),
    do:
      "I appear to be stuck (repeated failures, out of graded nudges): #{note}. What am I missing?"

  defp append_advice_message(state, framed_text) do
    messages = Map.get(state, :messages, []) || []
    directive = %{role: "system", content: framed_text}
    %{state | messages: messages ++ [directive]}
  end

  # ── Settings ──────────────────────────────────────────────────────────────

  @doc "Is the advisor available at all (manual tool + automatic triggers)?"
  @spec enabled?(map()) :: boolean()
  def enabled?(state) when is_map(state) do
    setting_enabled?(state) and configured_pair(state) != nil
  end

  def enabled?(_), do: false

  # Just the `:advisor_enabled` toggle, decoupled from whether a provider/
  # model pair happens to be configured — kept separate so `consult/3` can
  # tell an operator's explicit "off" (`:advisor_disabled`) apart from
  # "nobody filled in a model" (`:advisor_not_configured`) instead of both
  # collapsing into the same error atom.
  defp setting_enabled?(state) do
    session_id = Map.get(state, :session_id)

    Settings.get_session_for(
      session_id,
      :advisor_enabled,
      Application.get_env(:optimal_system_agent, :advisor_enabled, true)
    ) == true
  end

  @doc "Are the AUTOMATIC triggers on? (Independent of the manual tool.)"
  @spec auto_enabled?(map()) :: boolean()
  def auto_enabled?(state) when is_map(state) do
    session_id = Map.get(state, :session_id)

    enabled?(state) and
      Settings.get_session_for(
        session_id,
        :advisor_auto_enabled,
        Application.get_env(:optimal_system_agent, :advisor_auto_enabled, true)
      ) == true
  end

  def auto_enabled?(_), do: false

  @doc "The `{provider, model}` the advisor consults, or `nil` if unconfigured."
  @spec configured_pair(map()) :: {atom(), String.t()} | nil
  def configured_pair(state) when is_map(state) do
    session_id = Map.get(state, :session_id)

    provider =
      Settings.get_session_for(
        session_id,
        :advisor_provider,
        Application.get_env(:optimal_system_agent, :advisor_provider)
      )

    model =
      Settings.get_session_for(
        session_id,
        :advisor_model,
        Application.get_env(:optimal_system_agent, :advisor_model)
      )

    provider = normalize_provider(provider)

    if is_atom(provider) and provider != nil and is_binary(model) and model != "" do
      {provider, model}
    else
      nil
    end
  end

  def configured_pair(_), do: nil

  defp normalize_provider(nil), do: nil
  defp normalize_provider(p) when is_atom(p), do: p

  defp normalize_provider(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> nil
  end

  @doc "Per-turn USD cap on advisor spend."
  @spec cost_cap_usd(map()) :: float()
  def cost_cap_usd(state) when is_map(state) do
    session_id = Map.get(state, :session_id)

    case Settings.get_session_for(
           session_id,
           :advisor_cost_cap_usd,
           Application.get_env(
             :optimal_system_agent,
             :advisor_cost_cap_usd,
             @default_cost_cap_usd
           )
         ) do
      n when is_number(n) and n > 0 -> n * 1.0
      _ -> @default_cost_cap_usd
    end
  end

  def cost_cap_usd(_), do: @default_cost_cap_usd

  @doc "Has this turn's advisor spend already reached the cap?"
  @spec cost_cap_reached?(map()) :: boolean()
  def cost_cap_reached?(state) when is_map(state) do
    spent(state) >= cost_cap_usd(state)
  end

  def cost_cap_reached?(_), do: true

  @doc "Advisor spend already recorded for this turn (USD)."
  @spec spent(map()) :: float()
  def spent(state) when is_map(state) do
    case :ets.lookup(table(), turn_key(state)) do
      [{_, micro}] -> micro_to_usd(micro)
      _ -> 0.0
    end
  rescue
    ArgumentError -> 0.0
  end

  def spent(_), do: 0.0

  # Stored as an integer count of MICRO-dollars, never overwritten with a
  # float — `:ets.update_counter/4` requires an integer at that position on
  # every call, so `spent/1` alone does the micro -> USD conversion on read.
  defp record_spend(state, cost) when is_number(cost) do
    key = turn_key(state)
    micro = round(cost * 1_000_000)
    :ets.update_counter(table(), key, {2, micro}, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp micro_to_usd(micro) when is_integer(micro), do: micro / 1_000_000

  @doc """
  Start a fresh advisor spend bucket for `session_id` — call once per
  top-level turn (mirrors `GoalTracker.tick_turn/1`, which already runs at
  `state.iteration == 0`).

  Deliberately an explicit bump rather than keying off `state.turn_count`:
  the manual tool path only ever has a `UseContext`-shaped minimal map (no
  `turn_count` field), and this way both call sites agree on "which turn is
  this?" from the SAME counter instead of two different notions of it.
  """
  @spec reset_turn_budget(String.t() | nil) :: :ok
  def reset_turn_budget(session_id) when is_binary(session_id) and session_id != "" do
    :ets.update_counter(table(), {:epoch, session_id}, {2, 1}, {{:epoch, session_id}, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def reset_turn_budget(_), do: :ok

  defp epoch(session_id) do
    case :ets.lookup(table(), {:epoch, session_id}) do
      [{_, n}] -> n
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp turn_key(state) do
    session_id = Map.get(state, :session_id)
    {session_id, epoch(session_id)}
  end

  defp table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        try do
          :ets.new(@ets_table, [:named_table, :public, :set])
        rescue
          ArgumentError -> @ets_table
        end

      _ref ->
        @ets_table
    end
  end

  # ── Brief construction ───────────────────────────────────────────────────

  # Compact by design — this is a SEPARATE paid call, not a context dump.
  # Carries just enough for the advisor to answer the specific question: the
  # user's original ask, what has happened so far (tool names only, not full
  # results), and the caller's own note.
  defp build_brief(state, question, opts) do
    context = Keyword.get(opts, :context, "")

    # An explicit `:context` (the manual tool path — the working model wrote
    # it, describing its own situation) is the more informative signal and
    # wins. Only auto-derive from `state.messages` when the caller has none —
    # the automatic-trigger path, and any minimal `%{session_id: _}` context
    # map that carries no message history at all (in which case this is just
    # "(no tool calls yet)", which is still an honest answer).
    situation =
      if context != "" do
        context
      else
        "Tool calls so far, most recent last: #{recent_tool_summary(state)}"
      end

    """
    You are a senior advisor consulted mid-task by another AI agent. Answer in
    3-6 sentences, concretely. Do not repeat the question back.

    Situation: #{situation}

    Question from the working agent: #{question}
    """
    |> String.trim()
  end

  defp recent_tool_summary(state) do
    (Map.get(state, :messages) || [])
    |> Enum.flat_map(fn
      %{role: "assistant", tool_calls: tcs} when is_list(tcs) ->
        Enum.map(tcs, fn tc -> Map.get(tc, :name) || Map.get(tc, "name") end)

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(-20)
    |> Enum.join(", ")
    |> case do
      "" -> "(no tool calls yet)"
      s -> s
    end
  end

  # ── Telemetry ─────────────────────────────────────────────────────────────

  defp emit_consulted(state, provider, model, question, cost) do
    session_id = Map.get(state, :session_id)

    Bus.emit(:system_event, %{
      event: :advisor_consulted,
      session_id: session_id,
      provider: to_string(provider),
      model: model,
      question: String.slice(question, 0, 200),
      cost_usd: cost
    })

    if is_binary(session_id) and session_id != "" do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{session_id}",
        {:osa_event,
         %{
           type: :system_event,
           event: :advisor_consulted,
           session_id: session_id,
           provider: to_string(provider),
           model: model,
           cost_usd: cost
         }}
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
