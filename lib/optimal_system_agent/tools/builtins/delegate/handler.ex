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
    role = Map.get(args, "role") || Map.get(args, "subagent_type")
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
      case Map.get(args, "isolation") || (agent_def && agent_def[:isolation]) do
        "worktree" -> :worktree
        :worktree -> :worktree
        _ -> nil
      end

    background =
      case Map.fetch(args, "background") do
        {:ok, value} -> value == true
        :error -> (agent_def && agent_def[:background]) || false
      end

    config = %{
      task: task,
      parent_session_id: parent_id,
      role: role || "agent",
      tier: tier,
      model: Map.get(args, "model") || (agent_def && agent_def[:model]),
      provider: Map.get(args, "provider") || (agent_def && agent_def[:provider]),
      permission_tier:
        parse_permission_tier(
          Map.get(args, "permissionMode") ||
            Map.get(args, "permission_mode") ||
            (agent_def && agent_def[:permission_tier])
        ),
      system_prompt: agent_def && agent_def[:system_prompt],
      tools_allowed: agent_def && agent_def[:tools_allowed],
      tools_blocked: (agent_def && agent_def[:tools_blocked]) || [],
      max_iterations:
        parse_max_iterations(
          Map.get(args, "maxTurns") ||
            Map.get(args, "max_turns") ||
            Map.get(args, "max_iterations") ||
            (agent_def && agent_def[:max_iterations])
        ) || Tier.max_iterations(tier),
      isolation: isolation,
      merge_worktree: Map.get(args, "merge_worktree") == true,
      discard_worktree: Map.get(args, "discard_worktree") == true,
      working_dir: Map.get(args, "cwd") || Map.get(args, "working_dir")
    }

    config =
      if Map.get(args, "fork") == true do
        Map.put(config, :fork_messages, fetch_parent_messages(parent_id))
      else
        config
      end

    if background do
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
  defp parse_tier(tier) when is_atom(tier), do: tier
  defp parse_tier(_), do: :specialist

  defp parse_permission_tier(nil), do: :subagent
  defp parse_permission_tier("default"), do: :subagent
  defp parse_permission_tier("acceptEdits"), do: :workspace
  defp parse_permission_tier("bypassPermissions"), do: :full
  defp parse_permission_tier("plan"), do: :read_only
  defp parse_permission_tier("read_only"), do: :read_only
  defp parse_permission_tier("read-only"), do: :read_only
  defp parse_permission_tier("workspace"), do: :workspace
  defp parse_permission_tier("subagent"), do: :subagent
  defp parse_permission_tier("full"), do: :full

  defp parse_permission_tier(tier) when tier in [:read_only, :workspace, :subagent, :full],
    do: tier

  defp parse_permission_tier(_), do: :subagent

  defp parse_max_iterations(value) when is_integer(value), do: value

  defp parse_max_iterations(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_max_iterations(_), do: nil

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
