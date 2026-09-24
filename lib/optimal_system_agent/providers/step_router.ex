defmodule OptimalSystemAgent.Providers.StepRouter do
  @moduledoc """
  Per-step model routing — sends mechanical steps to a fast/cheap model and
  keeps planning, edits, risky commands and the final answer on the model the
  user actually chose.

  ## Why per step, not per turn

  Most of a long turn is mechanical: reading a file, grepping, summarizing a
  tool result, deciding which file to read next. Sending EVERY one of those
  round-trips through the user's chosen (usually expensive/slow) model spends
  the same budget on "what should I read next?" as it does on "how should I
  fix this bug?". `decide/1` looks at what the model's PREVIOUS step actually
  did — the only evidence available before the next call goes out — and routes
  the *next* call to the cheap pairing when that evidence says the work ahead
  is more of the same read-only exploration.

  ## The decision is deterministic and explainable

  `decide/1` is a pure function: given the same `state`, it always returns the
  same `t:decision/0`, and every branch carries a `:reason` atom plus a short
  `:explain` string a human (or the TUI) can read. Nothing here calls a model
  to decide whether to call a model — that would defeat the point.

  ## What always stays on the strong model (never routed)

    * The first call of a turn (`iteration == 0`) — no prior-step evidence
      exists yet, and this is exactly the call that plans the turn.
    * Any call whose pending history carries unreplayed Anthropic `thinking`
      blocks — Anthropic REQUIRES the signed thinking block that preceded a
      tool call be echoed back to a model that can make sense of it on the
      very next turn. Routing that continuation to a different model (or even
      a different Anthropic model, whose signature scope is unverified) is not
      a cost optimization, it is a broken request.
    * A previous step whose tool mix contains a KNOWN write/execute/risky
      tool (`@risky_tools`) — one of those in the mix means the model is
      mid-decision on something consequential, and the very next call is the
      one that reads the result and decides what to do about it.
    * A provider with no configured fast pairing, or whose fast pairing cannot
      make tool calls (`ModelLimits.tool_call/2`) while this turn needs tools.
    * Anything the (optional) pain-channel hook reports as high-frustration —
      see "Pain and budget signals" below.

  ## Pain and budget signals

  Two hooks feed the decision when the surrounding system provides them; both
  degrade to "no signal" (never crash, never block) when absent so this module
  has zero hard dependency on either:

    * **Pain** — `pain_signal_high?/1` looks for
      `OptimalSystemAgent.Agent.PainChannel.level/1` (a session id -> `:none |
      :low | :high | :critical` contract). No such module today; when one
      lands, routing picks it up automatically with no change here. A high/
      critical reading forces the strong model — a frustrated user is not the
      moment to hand the turn to the cheaper model.
    * **Budget** — `budget_critical?/1` reads the already-shipped
      `OptimalSystemAgent.Agent.Budget.check_budget/0` (guarded — a test suite
      that never starts the GenServer gets "no signal", not a crash). Budget
      pressure can only ever push an AMBIGUOUS step (a tool name on neither
      the mechanical allow-list nor the risky deny-list — something new/
      unclassified) toward the fast model; it never pulls a KNOWN risky,
      thinking-continuity, or turn-start step off the strong model. Safety
      ordering beats cost ordering.

  ## Cache-prefix stability

  `decide/1` never picks a different fast model for the same provider within a
  session — the pairing is resolved once from settings/defaults
  (`fast_model_for/1`) and is the same string every time it fires, so the fast
  model's own prompt cache has a chance to build up instead of thrashing
  between candidates.
  """

  require Logger

  alias OptimalSystemAgent.Providers.ModelLimits
  alias OptimalSystemAgent.Settings

  @type route :: :fast | :strong

  @type decision :: %{
          route: route(),
          provider: atom() | nil,
          model: String.t() | nil,
          reason: atom(),
          explain: String.t()
        }

  # Read-only / low-stakes tools. Deliberately an ALLOW-list, not a deny-list:
  # a brand-new tool nobody has classified yet must default to staying on the
  # strong model, not to being silently downgraded.
  @mechanical_tools ~w(
    file_read file_glob file_grep dir_list code_symbols codebase_explore
    session_search memory_recall semantic_search workspace_map tool_search
    list_agents list_skills web_search web_fetch knowledge budget_status
    task_output monitor bash_output
  )

  # Known write/execute/high-stakes tools — a DENY-list, deliberately
  # separate from the mechanical ALLOW-list above. A tool name in neither set
  # is "ambiguous" (unclassified, not yet known to be either safe or risky)
  # and is handled by the budget signal below, not by either list directly.
  @risky_tools ~w(
    file_edit file_write file_transform multi_file_edit notebook_edit
    structural_edit shell_execute pty repl computer_use browser git
    delegate orchestrate create_agent create_skill save_skill cron
    remote_trigger rollback push_notification send_message send_user_file
    subscribe_pr team_create team_delete team_tasks vault_checkpoint
    vault_context vault_inject vault_remember vault_sleep vault_wake
    wallet_ops security_intel cyber_defense github code_sandbox
    mixture_of_agents peer_claim_region peer_negotiate_task peer_review
    cross_team_query exit_plan_mode enter_plan_mode ask_user download
    config create_goal update_goal task_write task_stop task_resume
    message_agent use_tool use_skill skill_manager
  )

  # Same-provider fast/cheap pairing for the user's chosen model. Same
  # provider on purpose (see moduledoc — cache-prefix stability, and it keeps
  # `cross_provider_opts/1`'s :model-stripping rule irrelevant here).
  @default_fast_models %{
    ollama_cloud: "glm-5.3-flash:cloud",
    anthropic: "claude-haiku-4-5",
    openai: "gpt-5.6-luna"
  }

  @doc """
  Decide which provider/model should serve the NEXT LLM call for this turn.

  Pure — reads only `state`, `Settings`, and (defensively) the optional pain
  and budget hooks. Never raises: any lookup failure falls back to `:strong`.
  """
  @spec decide(map()) :: decision()
  def decide(state) when is_map(state) do
    provider = Map.get(state, :provider)
    model = Map.get(state, :model)
    fast_model = fast_model_for(provider, state)
    tools = previous_tool_names(state)

    cond do
      not enabled?(state) ->
        keep(provider, model, :disabled, "step routing is disabled")

      (Map.get(state, :iteration) || 0) <= 0 ->
        keep(provider, model, :turn_start, "first call of the turn — no prior-step evidence yet")

      carries_thinking_continuation?(state) ->
        keep(
          provider,
          model,
          :thinking_continuity,
          "pending signed thinking block must be replayed to the same model"
        )

      fast_model == nil ->
        keep(
          provider,
          model,
          :no_fast_pairing,
          "no fast model configured for #{inspect(provider)}"
        )

      not tool_capable?(provider, fast_model, state) ->
        keep(
          provider,
          model,
          :fast_model_lacks_tools,
          "#{fast_model} cannot make tool calls and this turn needs tools"
        )

      tools == [] ->
        keep(provider, model, :no_prior_tools, "no prior tool call to classify")

      not risky_free?(tools) ->
        keep(
          provider,
          model,
          :risky_tool_mix,
          "previous step used a known risky tool (#{inspect(risky(tools))})"
        )

      pain_signal_high?(state) ->
        keep(provider, model, :pain_signal, "pain channel reports high frustration/stall")

      all_mechanical?(tools) ->
        route_fast(provider, fast_model, :mechanical_tool_mix, tools)

      budget_critical?(state) ->
        route_fast(provider, fast_model, :budget_pressure, tools)

      true ->
        keep(
          provider,
          model,
          :ambiguous_tool_mix,
          "previous step used an unclassified tool (#{inspect(ambiguous(tools))}) — " <>
            "no budget pressure to justify the risk, staying on the strong model"
        )
    end
  end

  def decide(_), do: keep(nil, nil, :invalid_state, "state was not a map")

  @doc """
  Apply a decision to `state`, returning `{call_state, restore}` where
  `call_state` is `state` with `:provider`/`:model` overridden for the
  DURATION of one LLM call (identical to `state` when the decision kept the
  strong model), and `restore` is a 1-arity function that puts the ORIGINAL
  `:provider`/`:model` back once the call (and its billing) is done.

  The caller (`ReactLoop.do_iteration/1`) is expected to:

      routing = StepRouter.decide(state)
      {call_state, restore} = StepRouter.apply(state, routing)
      # ... build llm_opts, call LLMClient with call_state, run Accounting ...
      state = restore.(state)
  """
  @spec apply(map(), decision()) :: {map(), (map() -> map())}
  def apply(state, %{route: :fast, provider: provider, model: model}) when is_map(state) do
    original_provider = Map.get(state, :provider)
    original_model = Map.get(state, :model)

    call_state = %{state | provider: provider, model: model}

    restore = fn s -> %{s | provider: original_provider, model: original_model} end

    {call_state, restore}
  end

  def apply(state, _decision), do: {state, & &1}

  # ── Settings ─────────────────────────────────────────────────────────────

  @doc "Is per-step routing enabled for this session? Opt-in, defaults off."
  @spec enabled?(map()) :: boolean()
  def enabled?(state) when is_map(state) do
    session_id = Map.get(state, :session_id)

    Settings.get_session_for(
      session_id,
      :step_routing_enabled,
      Application.get_env(:optimal_system_agent, :step_routing_enabled, false)
    ) == true
  end

  def enabled?(_), do: false

  @doc "The configured (or default) fast model for `provider`, or nil."
  @spec fast_model_for(atom(), map()) :: String.t() | nil
  def fast_model_for(provider, state \\ %{}) when is_atom(provider) do
    session_id = Map.get(state, :session_id)

    configured =
      Settings.get_session_for(
        session_id,
        :step_routing_fast_models,
        Application.get_env(:optimal_system_agent, :step_routing_fast_models, %{})
      )

    lookup(configured, provider) || Map.get(@default_fast_models, provider)
  end

  defp lookup(map, provider) when is_map(map) do
    Map.get(map, provider) || Map.get(map, to_string(provider))
  end

  defp lookup(_, _), do: nil

  # ── Classification ───────────────────────────────────────────────────────

  @doc "True when every tool name in `names` is on the mechanical allow-list."
  @spec all_mechanical?([String.t()]) :: boolean()
  def all_mechanical?(names) when is_list(names) and names != [],
    do: Enum.all?(names, &mechanical?/1)

  def all_mechanical?(_), do: false

  @doc "True when none of the tool names are on the known-risky deny-list."
  @spec risky_free?([String.t()]) :: boolean()
  def risky_free?(names) when is_list(names), do: Enum.all?(names, &(not risky?(&1)))

  @doc "True for a tool name on the mechanical (read-only) allow-list."
  @spec mechanical?(String.t()) :: boolean()
  def mechanical?(name) when is_binary(name), do: name in @mechanical_tools
  def mechanical?(_), do: false

  @doc "True for a tool name on the known-risky (write/execute/high-stakes) deny-list."
  @spec risky?(String.t()) :: boolean()
  def risky?(name) when is_binary(name), do: name in @risky_tools
  def risky?(_), do: false

  defp risky(names), do: Enum.filter(names, &risky?/1)
  defp ambiguous(names), do: Enum.reject(names, &(mechanical?(&1) or risky?(&1)))

  # The most recent assistant message's tool call names — the only step
  # evidence available before the NEXT call goes out. Mirrors
  # `Agent.Loop.Telemetry.tools_used_since/2`'s extraction shape but only
  # needs the LAST tool-bearing message, not the whole turn.
  defp previous_tool_names(state) do
    (Map.get(state, :messages) || [])
    |> Enum.reverse()
    |> Enum.find_value([], fn
      %{role: "assistant", tool_calls: tcs} when is_list(tcs) and tcs != [] ->
        Enum.map(tcs, fn tc -> Map.get(tc, :name) || Map.get(tc, "name") end)

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Anthropic requires a signed `thinking` block that preceded a tool_use be
  # echoed back verbatim on the next turn (see `Anthropic.finalize_current_
  # thinking/1` and its interleaved-thinking request assembly). If the most
  # recent assistant message carries one, the continuation MUST go to a model
  # that understands it — never routed.
  defp carries_thinking_continuation?(state) do
    (Map.get(state, :messages) || [])
    |> Enum.reverse()
    |> Enum.find_value(false, fn
      %{role: "assistant", thinking_blocks: blocks} when is_list(blocks) and blocks != [] -> true
      %{role: "assistant"} -> false
      _ -> nil
    end)
  end

  defp tool_capable?(provider, model, state) do
    tools_required? = (Map.get(state, :tools) || []) != []

    if tools_required? do
      ModelLimits.tool_call(provider, model) != false
    else
      true
    end
  rescue
    _ -> true
  end

  defp route_fast(provider, model, reason, tools) do
    %{
      route: :fast,
      provider: provider,
      model: model,
      reason: reason,
      explain: "previous step's tool mix (#{inspect(tools)}) was mechanical — routing to #{model}"
    }
  end

  defp keep(provider, model, reason, explain) do
    %{route: :strong, provider: provider, model: model, reason: reason, explain: explain}
  end

  # ── Optional pain / budget hooks ─────────────────────────────────────────

  # Seam for a future `OptimalSystemAgent.Agent.PainChannel` (or whatever a
  # dedicated user-frustration/stall detector ends up being named). Contract:
  # `level(session_id) :: :none | :low | :high | :critical`. Absent today —
  # this always returns `false` until such a module exists, and picks it up
  # automatically the moment one does (`Code.ensure_loaded?/1` first, per the
  # `function_exported?/3`-on-an-unloaded-module lesson — see
  # `Registry.provider_info/1`'s comment on the same defect).
  @pain_channel_module OptimalSystemAgent.Agent.PainChannel

  defp pain_signal_high?(state) do
    session_id = Map.get(state, :session_id)

    if Code.ensure_loaded?(@pain_channel_module) and
         function_exported?(@pain_channel_module, :level, 1) do
      apply(@pain_channel_module, :level, [session_id]) in [:high, :critical]
    else
      false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Already-shipped budget tracker (`OptimalSystemAgent.Budget`, started by
  # `Supervisors.AgentServices`). Guarded because it is a GenServer: a unit
  # test (or a headless run that never starts the supervision tree) must get
  # "no signal", not a crash.
  defp budget_critical?(_state) do
    alias OptimalSystemAgent.Budget

    if Process.whereis(Budget) do
      case Budget.check_budget() do
        {:over_limit, _} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
