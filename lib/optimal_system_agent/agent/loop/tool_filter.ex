defmodule OptimalSystemAgent.Agent.Loop.ToolFilter do
  @moduledoc """
  Tool list filtering and budget management before LLM calls.

  Applies three layers of filtering:
  1. Signal weight gate — low-weight inputs (< 0.20) skip tools entirely to prevent
     hallucinated tool sequences for messages like "ok" or "lol".
  2. Computer-use focus mode — if the previous iteration used computer_use on a slow
     local provider, trims the tool list to CU-related tools only.
  3. Fast path — clear intents get a smaller first-pass tool set with escape hatches;
     unclear intents keep the full tool surface.
  4. Tool budget — local/slow providers (Ollama, LM Studio, llama.cpp) choke on large
     tool lists. Caps at 10, prioritising file and shell tools.
  """
  require Logger
  alias OptimalSystemAgent.Agent.FastPath
  alias OptimalSystemAgent.Agent.DelegationPolicy

  # Minimum signal weight required to include tools in the LLM call.
  @tool_weight_threshold 0.20

  # Maximum delegation nesting depth. A subagent at this depth has its
  # spawning tools (delegate/create_agent) stripped so it cannot fork more
  # children — a hard ceiling against fork-bomb / runaway-cost behaviour under
  # auto-mode. Configurable via
  #   config :optimal_system_agent, :max_delegation_depth, N
  @default_max_delegation_depth 3

  # Tools that spawn further agents. Names + declared aliases (Delegate.Tool
  # aliases and CreateAgent.Tool aliases) — matched by tool name so a rename in
  # either tool keeps this guard effective as long as the alias list is updated.
  @spawning_tools ~w(delegate agent subagent spawn_agent create_agent define_agent new_agent
    fleet fleet_spawn fleet_workflow spawn_fleet_node fan_out)

  # Priority tools kept when trimming for local providers.
  @priority_tools ~w(file_read file_write file_edit shell_execute ask_user computer_use memory_recall)

  # Local/slow provider atoms that need the tool budget cap.
  @local_providers [:ollama, :lmstudio, :llamacpp]

  # Coordinator mode restricts tools to delegation, messaging, and management.
  @coordinator_tools ~w(delegate send_message tool_search memory_recall memory_save
    task_write list_agents list_skills session_search ask_user)

  @doc """
  Filter the tool list for the current state and signal weight.

  Returns a (possibly reduced) list of tool definitions to pass to the LLM.
  """
  @spec filter(list(), map()) :: list()
  def filter(tools, state) do
    tools
    |> apply_delegation_depth_guard(state)
    |> apply_delegation_policy(state)
    |> apply_weight_gate(state)
    |> apply_computer_use_focus(state)
    |> FastPath.select_tools(state)
    |> apply_local_provider_budget(state)
  end

  @doc "Configured maximum delegation nesting depth."
  @spec max_delegation_depth() :: non_neg_integer()
  def max_delegation_depth do
    Application.get_env(
      :optimal_system_agent,
      :max_delegation_depth,
      @default_max_delegation_depth
    )
  end

  @doc """
  Restrict the tool list to coordinator-mode tools (delegation, messaging, and
  management) when `coordinator?` is true; otherwise return `tools` unchanged.

  Applied once at session start so a coordinator session never surfaces
  execution tools to the LLM.
  """
  @spec filter_for_coordinator(list(), boolean()) :: list()
  def filter_for_coordinator(tools, false), do: tools

  def filter_for_coordinator(tools, true) do
    Enum.filter(tools, fn tool ->
      name = tool[:name] || tool.name
      name in @coordinator_tools
    end)
  end

  # --- Private ---

  # Depth guard — a child at or beyond the max delegation depth loses its
  # ability to spawn grandchildren. This is the hard stop that keeps a runaway
  # orchestrator (especially under auto-mode) from recursively forking agents.
  defp apply_delegation_depth_guard(tools, state) do
    depth = Map.get(state, :delegation_depth, 0)

    if is_integer(depth) and depth >= max_delegation_depth() do
      strip_spawning_tools(
        tools,
        "delegation_depth=#{depth} >= #{max_delegation_depth()}"
      )
    else
      tools
    end
  end

  # Tri-mode delegation policy (primitive #34) — layered on top of the depth
  # guard. `:proactive` leaves the tool list untouched; `:disabled` always
  # strips spawning tools; `:explicit_only` strips them unless the user asked to
  # delegate in the current turn. Enforced again at the delegate handler as
  # defense-in-depth in case the model calls a still-listed tool.
  defp apply_delegation_policy(tools, state) do
    policy = DelegationPolicy.resolve(state)
    messages = Map.get(state, :messages, [])

    if DelegationPolicy.allow?(policy, messages) do
      tools
    else
      strip_spawning_tools(tools, "delegation_policy=#{policy}")
    end
  end

  # Split off @spawning_tools, logging what was removed and why. Shared by the
  # depth guard and the policy gate so both stay in lockstep on the tool list.
  defp strip_spawning_tools(tools, reason) do
    {stripped, kept} = Enum.split_with(tools, fn t -> tool_name(t) in @spawning_tools end)

    if stripped != [] do
      Logger.debug(
        "[loop] #{reason} — stripping spawning tools " <>
          "(#{stripped |> Enum.map(&tool_name/1) |> Enum.join(", ")})"
      )
    end

    kept
  end

  defp tool_name(%{name: name}), do: to_string(name)
  defp tool_name(t) when is_map(t), do: to_string(t[:name] || "")
  defp tool_name(_), do: ""

  defp apply_weight_gate(tools, %{signal_weight: weight}) when is_number(weight) do
    if weight < @tool_weight_threshold do
      Logger.debug(
        "[loop] signal_weight=#{weight} < #{@tool_weight_threshold} — skipping tools for low-weight input"
      )

      []
    else
      tools
    end
  end

  defp apply_weight_gate(tools, _state), do: tools

  defp apply_computer_use_focus([], _state), do: []

  defp apply_computer_use_focus(tools, state) do
    last_used_cu =
      Enum.any?(state.messages, fn msg ->
        msg[:name] == "computer_use" or
          (is_map(msg[:content]) and msg[:name] == "computer_use")
      end)

    if last_used_cu and state.provider in @local_providers do
      Logger.debug("[loop] Computer-use focus mode — trimming to CU-related tools only")
      Enum.filter(tools, fn t -> t.name in ~w(computer_use file_read ask_user) end)
    else
      tools
    end
  end

  defp apply_local_provider_budget(tools, state) do
    if state.provider in @local_providers and length(tools) > 10 do
      Logger.debug("[loop] Trimming tools from #{length(tools)} to 10 for #{state.provider}")
      take_priority_tools(tools, 10)
    else
      tools
    end
  end

  defp take_priority_tools(tools, budget) do
    {priority, rest} = Enum.split_with(tools, fn t -> t.name in @priority_tools end)
    priority = Enum.take(priority, budget)
    remaining = max(budget - length(priority), 0)
    priority ++ Enum.take(rest, remaining)
  end
end
