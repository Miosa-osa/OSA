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
  4. Tool budget — models whose REAL resolved context window is small choke on large
     tool lists. Caps at 10, prioritising file and shell tools. Keyed on the window,
     NOT on the provider atom: a 1M-window model served through the Ollama transport
     is not a small model.
  """
  require Logger
  alias OptimalSystemAgent.Agent.FastPath
  alias OptimalSystemAgent.Agent.DelegationPolicy

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

  # Local/slow provider atoms. Used ONLY by the computer-use focus heuristic's
  # transport check; the tool budget keys on the model's real window instead —
  # see `apply_small_window_budget/2`.
  @local_providers [:ollama, :lmstudio, :llamacpp]

  # How many tools a genuinely small-window model gets.
  @small_window_tool_budget 10

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
    |> apply_computer_use_focus(state)
    |> FastPath.select_tools(state)
    |> apply_small_window_budget(state)
    |> repin_discovered(state)
    |> apply_ask_user_gate(state)
  end

  # LAST, deliberately — after `repin_discovered/2`.
  #
  # `ask_user` is off by default (see `Agent.AskUserMode`) and `Loop.init/1`
  # already leaves it out of `state.tools`. This pass is what makes that hold
  # for the rest of the session: `ToolDiscovery.widen/2` appends whatever a
  # `tool_search` resolved to, and `repin_discovered/2` re-appends the pinned
  # set after every narrowing pass, so a model that searched for "ask" would
  # otherwise get the tool back one iteration later — a gate that silently
  # stops holding is worse than no gate.
  #
  # It reads a value PINNED at session start, so it does not oscillate: the
  # array it produces is the same array on every request of the session, which
  # is what the cached tool prefix requires. Only an explicit `/ask-user`
  # toggle changes it, once.
  defp apply_ask_user_gate(tools, state) do
    OptimalSystemAgent.Agent.AskUserMode.filter_tools(
      tools,
      Map.get(state, :ask_user_enabled, false)
    )
  end

  # Every pass above can only SHRINK the list, which is what made a deferred
  # tool permanently uncallable in the first place. A tool the model discovered
  # mid-session and was told it may now call is the one thing that must survive
  # them: `apply_small_window_budget/2` in particular trims by priority list, so
  # a just-discovered MCP tool is exactly the kind of thing it drops.
  #
  # Re-appended at the END, in the order `state.discovered_tools` records, so
  # the array a widening produced is the array every later turn sends —
  # oscillating between two tool sets would invalidate the cached prefix in both
  # directions, which is strictly worse than either set.
  #
  # Deliberately NOT applied to the spawning-tool guards: those are safety
  # limits (fork-bomb depth, delegation policy), and a `tool_search` for
  # "delegate" must not be a way around them. They run before this and their
  # removals are re-applied here by construction, because a stripped spawning
  # tool is not in `discovered_tools` unless discovery put it there — so filter
  # the pin through the same guard.
  defp repin_discovered(tools, state) do
    pinned = Map.get(state, :discovered_tools, [])

    if pinned == [] do
      tools
    else
      present = MapSet.new(tools, &tool_name/1)

      missing =
        pinned
        |> Enum.reject(fn t -> MapSet.member?(present, tool_name(t)) end)
        |> Enum.reject(fn t -> tool_name(t) in @spawning_tools end)

      tools ++ missing
    end
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
  Restrict the ADVERTISED tool array to what the role could actually execute.

  `state.allowed_tools` used to gate EXECUTION only. An explore/explorer child
  still saw `delegate` in its schema array and tried to spawn another explorer.
  This pass is what makes the role file true at prompt time.

  ## One decision, not one-and-a-half

  The execution gate is `ToolExecutor.subagent_tool_allowed?/2`, and it answers
  with THREE clauses: the always-blocked set (`delegate`, `ask_user`,
  `create_skill`, `create_agent`, `memory_save`), the per-agent denylist
  (`tools_blocked`), and the per-agent allowlist (`tools_allowed`). Advertising
  only the third clause is how a subagent still gets handed `delegate` and is
  then refused at call time — e.g. `Builtins.UseSkill` sets
  `tools_blocked: ["delegate", "use_skill"]` with no allowlist at all, so the
  allowlist clause alone declines to filter anything.

  So this delegates to that same predicate rather than restating a subset of
  it. `@subagent_blocked_tools` applies only at `permission_tier: :subagent`,
  which is the tier under which the execution gate is consulted — a parent
  session keeps `delegate`.

  Accepts the loop state (or any map carrying `:allowed_tools`,
  `:blocked_tools`, `:permission_tier`). The bare-list form is the legacy
  allowlist-only call and is treated as tier `:full`.

  Unrestricted roles (no allowlist, no denylist, not a subagent) return `tools`
  untouched and log nothing.
  """
  @spec filter_for_role_allowlist(list(), map() | [String.t()] | nil) :: list()
  def filter_for_role_allowlist(tools, %{} = role) do
    allowed = Map.get(role, :allowed_tools)
    blocked = Map.get(role, :blocked_tools) || []
    tier = Map.get(role, :permission_tier) || :full

    allowlist? = is_list(allowed) and allowed != []
    denylist? = is_list(blocked) and blocked != []

    if not (allowlist? or denylist? or tier == :subagent) do
      tools
    else
      gate = %{allowed_tools: allowed, blocked_tools: blocked}
      kept = Enum.filter(tools, &role_permits?(tier, tool_name(&1), gate))
      report_role_filter(tools, kept, tier, allowed, blocked)
    end
  end

  def filter_for_role_allowlist(tools, allowed) when is_list(allowed) or is_nil(allowed) do
    filter_for_role_allowlist(tools, %{
      allowed_tools: allowed,
      blocked_tools: [],
      permission_tier: :full
    })
  end

  # At :subagent tier the advertised set is exactly the executable set. At any
  # other tier the always-blocked list does not apply, so only the role's own
  # allow/deny pair does.
  defp role_permits?(:subagent, name, gate),
    do: OptimalSystemAgent.Agent.Loop.ToolExecutor.subagent_tool_allowed?(name, gate)

  defp role_permits?(_tier, name, %{allowed_tools: allowed, blocked_tools: blocked}) do
    cond do
      is_list(blocked) and name in blocked -> false
      is_list(allowed) and allowed != [] -> name in allowed
      true -> true
    end
  end

  # A gate that removes tools must say so. `filter_for_env_allowlist/1` and
  # `strip_spawning_tools/2` both log; this one shipped silent, which is the
  # same defect `Agent.FastPath` records as "the only stage in filter/1 that
  # logged NOTHING".
  defp report_role_filter(tools, kept, tier, allowed, blocked) do
    cond do
      kept == tools ->
        tools

      kept == [] and tools != [] ->
        # A `tools_allowed` typo or a stale tool name intersects to nothing, and
        # a zero-length schema array is not something native-tool providers
        # degrade from gracefully. Drop the unsatisfiable ALLOWLIST, keep the
        # safety clauses, and say loudly that the role file is wrong.
        salvaged =
          Enum.filter(
            tools,
            &role_permits?(tier, tool_name(&1), %{
              allowed_tools: nil,
              blocked_tools: blocked
            })
          )

        Logger.warning(
          "[loop] role allowlist #{inspect(allowed)} matches NO advertised tool " <>
            "(tier #{inspect(tier)}) — ignoring it and advertising " <>
            "#{length(salvaged)} of #{length(tools)} tools. Check tools_allowed " <>
            "in the agent/skill definition for a typo or a renamed tool."
        )

        salvaged

      true ->
        Logger.info(
          "[loop] role tool gate active (tier #{inspect(tier)}) — advertising " <>
            "#{length(kept)} of #{length(tools)} tools " <>
            "(#{kept |> Enum.map(&tool_name/1) |> Enum.join(", ")})"
        )

        kept
    end
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

  @doc """
  Restrict the ADVERTISED tool array to an explicit allowlist read from
  `OSA_TOOL_ALLOWLIST` (comma-separated tool names).

  Inert when the variable is unset or empty, which is every non-experimental
  run. It exists because there was no other way to vary the tool surface:
  Role allowlists now also shrink the advertised set via
  `filter_for_role_allowlist/2`. This env gate is the experimental override. `:lite` is a SYSTEM-PROMPT variant and likewise
  does not remove a tool from the array a native-tool provider receives.

  Applied once at session start, next to the coordinator and ask_user gates,
  so the array is stable for the whole session and the cached tool prefix
  stays valid.
  """
  @spec filter_for_env_allowlist(list()) :: list()
  def filter_for_env_allowlist(tools) do
    case env_allowlist() do
      [] ->
        tools

      names ->
        kept = Enum.filter(tools, fn t -> tool_name(t) in names end)

        Logger.info(
          "[loop] OSA_TOOL_ALLOWLIST active — advertising #{length(kept)} of " <>
            "#{length(tools)} tools (#{kept |> Enum.map(&tool_name/1) |> Enum.join(", ")})"
        )

        kept
    end
  end

  defp env_allowlist do
    "OSA_TOOL_ALLOWLIST"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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

  # REMOVED: the signal-weight gate.
  #
  # It sent the model an EMPTY tool list whenever `state.signal_weight` fell
  # below 0.20, as a conversational fast path. The only thing keeping it from
  # firing was that `signal_weight` is initialised to `nil` in `Agent.Loop` and
  # never written, so the gate quietly did nothing.
  #
  # Wiring it up would have been a disaster, because the weight it gates on is
  # `Signal.MessageClassifier.calculate_weight/1` — literally
  # `min(String.length(message) / 500, 1.0)`. At a 0.20 threshold that is "any
  # message shorter than 100 characters gets no tools at all":
  #
  #     "fix the bug in auth.ex"        22 chars -> 0.04 -> NO TOOLS
  #     "run the tests"                 13 chars -> 0.03 -> NO TOOLS
  #     "deploy to staging"             17 chars -> 0.03 -> NO TOOLS
  #
  # Message length is not a proxy for whether a request needs tools; if
  # anything the correlation runs the other way, since a terse instruction is
  # usually a command and a long one is usually context. Leaving the gate in
  # place meant the next person to populate `signal_weight` — an obvious,
  # innocuous-looking change — would have silently broken every short request.
  #
  # A real conversational fast path has to key on what the message ASKS for,
  # not how long it is, so it is not being re-implemented here on a bad signal.

  defp apply_computer_use_focus([], _state), do: []

  defp apply_computer_use_focus(tools, state) do
    last_used_cu =
      Enum.any?(state.messages, fn msg ->
        msg[:name] == "computer_use" or
          (is_map(msg[:content]) and msg[:name] == "computer_use")
      end)

    # The transport check alone was wrong for the same reason the tool budget's
    # was: an Ollama Cloud tag is not a slow local model. Both must hold.
    if last_used_cu and state.provider in @local_providers and small_window?(state) do
      Logger.debug("[loop] Computer-use focus mode — trimming to CU-related tools only")
      Enum.filter(tools, fn t -> t.name in ~w(computer_use file_read ask_user) end)
    else
      tools
    end
  end

  # Cap the tool list for models whose REAL context window is too small to hold
  # the full tool surface.
  #
  # This used to key on `state.provider in @local_providers`, which cut EVERY
  # model reached through Ollama / LM Studio / llama.cpp to ten tools regardless
  # of its window. Observed live on a 1M-window frontier model served as an
  # Ollama Cloud tag: "Trimming tools from 37 to 10 for ollama". That is a
  # capability regression, and it is also a LATENCY regression: a model that
  # cannot see the tool it needs takes more round-trips to finish, and
  # round-trips are what the wall clock is actually made of.
  #
  # `Context.small_window?/2` is the single source of truth, so the trimmed tool
  # array and the trimmed prompt variant always describe the same regime.
  defp apply_small_window_budget(tools, state) do
    if length(tools) > @small_window_tool_budget and small_window?(state) do
      Logger.debug(
        "[loop] Trimming tools from #{length(tools)} to #{@small_window_tool_budget} " <>
          "for small context window (#{state.provider}/#{Map.get(state, :model) || "default"})"
      )

      take_priority_tools(tools, @small_window_tool_budget)
    else
      tools
    end
  end

  defp small_window?(state) do
    OptimalSystemAgent.Agent.Context.small_window?(
      Map.get(state, :model),
      Map.get(state, :provider)
    )
  end

  defp take_priority_tools(tools, budget) do
    {priority, rest} = Enum.split_with(tools, fn t -> t.name in @priority_tools end)
    priority = Enum.take(priority, budget)
    remaining = max(budget - length(priority), 0)
    priority ++ Enum.take(rest, remaining)
  end
end
