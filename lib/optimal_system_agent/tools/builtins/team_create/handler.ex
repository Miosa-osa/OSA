defmodule OptimalSystemAgent.Tools.Builtins.TeamCreate.Handler do
  @moduledoc """
  Validation, permission, and execution for `team_create`.

  Stage 1 — validate/2:
    Confirms `name` is a non-empty string, `members` is a non-empty list of
    binary role names with no duplicates, and each role exists in
    `OptimalSystemAgent.Agents.Registry`. Unknown roles are rejected with a
    descriptive message listing valid alternatives.

  Stage 2 — check_permissions/2:
    Denied when the UseContext permission tier is `:read_only`.

  Stage 3 — execute/2:
    Delegates to `OptimalSystemAgent.Teams.Manager.create_team/1`. If a
    `parent_id` is present the call is routed through
    `OptimalSystemAgent.Teams.Manager.create_sub_team/3` instead.
    On success, each member role is recorded via
    `OptimalSystemAgent.Teams.Manager.spawn_agent/4` with the member role name
    used as both the agent name and role.
  """

  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  alias OptimalSystemAgent.Team
  alias OptimalSystemAgent.Teams.Manager
  alias OptimalSystemAgent.Tools.Builtins.TeamCreate.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"name" => name, "members" => members} = input, _ctx)
      when is_binary(name) and is_list(members) do
    with :ok <- validate_name(name),
         :ok <- validate_members(members) do
      {:ok, input}
    end
  end

  def validate(%{"name" => _name, "members" => _members}, _ctx) do
    {:error, "name must be a string and members must be a list", -32_602}
  end

  def validate(%{"name" => _}, _ctx) do
    {:error, "Missing required parameter: members", -32_602}
  end

  def validate(%{"members" => _}, _ctx) do
    {:error, "Missing required parameter: name", -32_602}
  end

  def validate(_input, _ctx) do
    {:error, "Missing required parameters: name, members", -32_602}
  end

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(_input, %UseContext{permission_tier: :read_only}) do
    {:deny, "team_create is not permitted in read-only mode"}
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(input, ctx) do
    name = Map.fetch!(input, "name")
    members = Map.fetch!(input, "members")
    goal = Map.get(input, "goal")
    budget = Map.get(input, "budget_usd", 1.0)
    parent_id = Map.get(input, "parent_id")

    config =
      %{name: name, budget_usd: budget}
      |> maybe_put(:goal, goal)

    result =
      if parent_id do
        Manager.create_sub_team(parent_id, name, config)
      else
        Manager.create_team(config)
      end

    case result do
      {:ok, meta} ->
        team_id = meta.team_id
        parent_session = ctx && Map.get(ctx, :session_id)
        # Dispatch live members only when there is a concrete goal AND a parent
        # session to route their lifecycle/message events to; otherwise register
        # a data-only roster. Either way the shared task board is populated.
        dispatch? = is_binary(goal) and String.trim(goal) != "" and is_binary(parent_session)
        spawn_members(team_id, members, goal, parent_session, dispatch?)

        goal_note = if goal, do: " Goal: #{goal}.", else: ""
        dispatch_note = if dispatch?, do: " Dispatched #{length(members)} member(s).", else: ""
        member_list = Enum.join(members, ", ")

        {:ok,
         "Team created. team_id=#{team_id} name=#{name} members=[#{member_list}]#{goal_note}#{dispatch_note}"}

      {:error, :team_not_found} ->
        {:error, "Parent team not found: #{parent_id}"}

      {:error, :max_depth_exceeded} ->
        {:error, "Cannot create sub-team: parent is already at maximum nesting depth (3)"}

      {:error, reason} ->
        {:error, "Failed to create team: #{inspect(reason)}"}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp validate_name("") do
    {:error, "name must not be empty", -32_602}
  end

  defp validate_name(name) do
    max = Constants.max_name_length()

    if byte_size(name) > max do
      {:error, "name must be <= #{max} characters", -32_602}
    else
      :ok
    end
  end

  defp validate_members([]) do
    {:error, "members must be a non-empty list", -32_602}
  end

  defp validate_members(members) do
    max = Constants.max_members()

    cond do
      length(members) > max ->
        {:error, "members list exceeds maximum of #{max} roles", -32_602}

      Enum.any?(members, &(not is_binary(&1))) ->
        {:error, "all members must be strings (role names)", -32_602}

      true ->
        validate_roles(members)
    end
  end

  defp validate_roles(members) do
    known = AgentRegistry.role_names()

    unknown = Enum.reject(members, &(&1 in known))

    duplicates =
      members
      |> Enum.frequencies()
      |> Enum.filter(fn {_k, v} -> v > 1 end)
      |> Enum.map(&elem(&1, 0))

    cond do
      unknown != [] and known == [] ->
        # Registry not loaded yet — allow the call through; Manager will
        # record roles as-is. This avoids hard failures in non-interactive
        # or test contexts where the agent registry hasn't been seeded.
        :ok

      unknown != [] ->
        valid_sample = known |> Enum.take(8) |> Enum.join(", ")

        {:error,
         "Unknown role(s): #{Enum.join(unknown, ", ")}. Known roles include: #{valid_sample}",
         -32_602}

      duplicates != [] ->
        {:error, "Duplicate role(s) in members: #{Enum.join(duplicates, ", ")}", -32_602}

      true ->
        :ok
    end
  end

  # Seed the shared task board (one task per member) and spawn each member.
  # `Team.create_task/2` is called here so the board `team_tasks` reads is really
  # populated; when dispatching, the member claims its task.
  defp spawn_members(team_id, members, goal, parent_session, dispatch?) do
    Enum.each(members, fn role ->
      description =
        if dispatch?, do: "As #{role}: #{goal}", else: "#{role} — awaiting assignment"

      task = Team.create_task(team_id, %{description: description, role: role})

      # Only pass a :task (which triggers a live Loop) when dispatching.
      dispatch_task = if dispatch?, do: description, else: nil

      case Manager.spawn_agent(team_id, role, role,
             parent_session_id: parent_session,
             task: dispatch_task,
             task_id: task.id
           ) do
        {:ok, %{agent_id: agent_id}} when dispatch? ->
          Team.claim_task(team_id, task.id, agent_id)

        _ ->
          :ok
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
