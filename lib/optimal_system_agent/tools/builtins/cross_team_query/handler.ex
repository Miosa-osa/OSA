defmodule OptimalSystemAgent.Tools.Builtins.CrossTeamQuery.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `cross_team_query`.

  Split mirrors the structured-layout pattern:
    * `validate/2`          — type-check input shape
    * `check_permissions/2` — read-only allowed (this tool is read-only)
    * `execute/2`           — dispatch to `OptimalSystemAgent.Peer.Discovery`

  The ETS table `:osa_peer_queries` is referenced via `Constants.peer_queries_table/0`
  to keep the atom in one place.
  """

  alias OptimalSystemAgent.Peer.Discovery
  alias OptimalSystemAgent.Tools.Builtins.CrossTeamQuery.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Validate ─────────────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx)
      when action in ["ask", "poll", "answer", "list"] do
    {:ok, input}
  end

  def validate(%{"action" => other}, _ctx) do
    {:error, "Invalid action '#{other}'. Use: ask, poll, answer, list", -32_602}
  end

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permissions ──────────────────────────────────────────────
  # cross_team_query is read-only from the caller's perspective:
  # asking and polling do not mutate state on the calling side.
  # answering does mutate state on the *receiving* side, but that agent's
  # context will not have read_only_request? set.

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(
        %{"action" => "ask", "target_team" => target_team, "question" => question} = args,
        ctx
      ) do
    from_team =
      Map.get(args, "team_id", ctx.session_id || Map.get(args, "__session_id__", "unknown"))

    case Discovery.query_cross_team(from_team, target_team, question) do
      {:ok, query_id} ->
        {:ok,
         "Query sent to team #{target_team}.\n" <>
           "Query ID: `#{query_id}`\n" <>
           "Use `cross_team_query` with action `poll` and query_id `#{query_id}` to check for a response."}

      {:error, reason} ->
        {:error, "Failed to send query: #{reason}"}
    end
  end

  def execute(%{"action" => "ask"}, _ctx) do
    {:error, "Missing required parameters: target_team and question are required for 'ask'."}
  end

  def execute(%{"action" => "poll", "query_id" => query_id}, _ctx) do
    case Discovery.get_query(query_id) do
      nil ->
        {:ok, "Query #{query_id} not found."}

      %{status: :answered} = query ->
        {:ok,
         "## Query Answered\n\n" <>
           "Question: #{query.question}\n" <>
           "Answered by: #{query.answered_by} (team #{query.to_team})\n" <>
           "At: #{DateTime.to_iso8601(query.answered_at)}\n\n" <>
           "**Answer:**\n#{query.answer}"}

      %{status: :pending} = query ->
        {:ok, "Query #{query_id} is pending. No answer yet from team #{query.to_team}."}
    end
  end

  def execute(%{"action" => "poll"}, _ctx) do
    {:error, "Missing required parameter: query_id is required for 'poll'."}
  end

  def execute(%{"action" => "answer", "query_id" => query_id, "answer" => answer} = args, ctx) do
    agent_id = ctx.session_id || Map.get(args, "__session_id__", "unknown")

    case Discovery.answer_query(agent_id, query_id, answer) do
      :ok ->
        {:ok, "Answer submitted for query #{query_id}. The requesting team has been notified."}

      {:error, reason} ->
        {:error, "Failed to submit answer: #{reason}"}
    end
  end

  def execute(%{"action" => "answer"}, _ctx) do
    {:error, "Missing required parameters: query_id and answer are required for 'answer'."}
  end

  def execute(%{"action" => "list"} = args, ctx) do
    team_id =
      Map.get(args, "team_id", ctx.session_id || Map.get(args, "__session_id__", "unknown"))

    queries =
      try do
        Constants.peer_queries_table()
        |> :ets.tab2list()
        |> Enum.map(fn {_, q} -> q end)
        |> Enum.filter(&(&1.to_team == team_id and &1.status == :pending))
        |> Enum.sort_by(& &1.created_at, DateTime)
      rescue
        _ -> []
      end

    if queries == [] do
      {:ok, "No pending cross-team queries for team #{team_id}."}
    else
      lines =
        Enum.map_join(queries, "\n", fn q ->
          "- `#{q.id}` from team #{q.from_team}: #{String.slice(q.question, 0, 80)}"
        end)

      {:ok, "## Pending queries for team #{team_id} (#{length(queries)})\n\n#{lines}"}
    end
  end
end
