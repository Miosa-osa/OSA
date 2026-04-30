defmodule OptimalSystemAgent.Tools.Builtins.Delegate.Handler do
  @moduledoc """
  Validation, permission checking, and execution logic for `delegate`.

  Split mirrors the FileRead.Handler pattern:
    * `validate/2`           — type-check input shape (cheap, no I/O)
    * `check_permissions/2`  — deny obviously invalid delegation requests
    * `execute/2`            — dispatch to Orchestrator

  The tier floor (:utility → :specialist promotion) lives here because it is
  a business rule, not a display concern.
  """

  alias OptimalSystemAgent.Tools.Builtins.Delegate.Constants
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Agent.Tier

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"task" => task} = input, _ctx) when is_binary(task), do: {:ok, input}

  def validate(%{"task" => _}, _ctx),
    do: {:error, "task must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: task", -32_602}

  # ── Stage 2: Permission check ──────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"task" => task} = input, _ctx) do
    if String.trim(task) == "" do
      {:deny, "Access denied: task description must not be blank"}
    else
      {:allow, input}
    end
  end

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"task" => task} = args, ctx) do
    role = Map.get(args, "role")
    tier_str = Map.get(args, "tier")
    parent_id = resolve_parent_id(args, ctx)

    agent_def = if role, do: AgentRegistry.get(role), else: nil

    raw_tier =
      cond do
        tier_str -> parse_tier(tier_str)
        agent_def -> agent_def[:tier] || Constants.min_subagent_tier()
        true -> Constants.min_subagent_tier()
      end

    # Enforce tier floor: utility models can't do tool calling reliably.
    tier = if raw_tier == :utility, do: Constants.min_subagent_tier(), else: raw_tier

    isolation =
      case Map.get(args, "isolation") do
        "worktree" -> :worktree
        _ -> nil
      end

    config = %{
      task: task,
      parent_session_id: parent_id,
      role: role || "agent",
      tier: tier,
      system_prompt: agent_def && agent_def[:system_prompt],
      tools_allowed: agent_def && agent_def[:tools_allowed],
      tools_blocked: (agent_def && agent_def[:tools_blocked]) || [],
      max_iterations: (agent_def && agent_def[:max_iterations]) || Tier.max_iterations(tier),
      isolation: isolation
    }

    config =
      if Map.get(args, "fork") == true do
        Map.put(config, :fork_messages, fetch_parent_messages(parent_id))
      else
        config
      end

    if Map.get(args, "background") == true do
      dispatch_background(parent_id, config)
    else
      dispatch_foreground(config)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp dispatch_foreground(config) do
    case Orchestrator.run_subagent(config) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:ok, "Delegation failed: #{inspect(reason)}"}
    end
  end

  defp dispatch_background(parent_id, config) do
    {:ok, agent_id} = Orchestrator.run_background(parent_id, config)

    {:ok,
     "Agent '#{config.role}' spawned in background (#{agent_id}). " <>
       "You'll be notified when it completes. Continue with other work."}
  end

  defp resolve_parent_id(_args, %UseContext{session_id: sid}) when is_binary(sid), do: sid
  defp resolve_parent_id(args, _ctx), do: Map.get(args, "__session_id__", "unknown")

  defp parse_tier("elite"), do: :elite
  defp parse_tier("specialist"), do: :specialist
  defp parse_tier("utility"), do: :utility
  defp parse_tier(_), do: :specialist

  defp fetch_parent_messages(parent_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, parent_id) do
      [{pid, _}] ->
        try do
          state = :sys.get_state(pid)

          state.messages
          |> Enum.reject(fn msg ->
            role = Map.get(msg, :role) || Map.get(msg, "role")
            role == "system"
          end)
          |> Enum.take(-20)
        rescue
          _ -> []
        end

      _ ->
        []
    end
  end
end
