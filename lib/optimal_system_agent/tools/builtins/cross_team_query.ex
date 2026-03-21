defmodule OptimalSystemAgent.Tools.Builtins.CrossTeamQuery do
  @moduledoc """
  Cross-Team Query Tool — send a read-only question to another team and retrieve
  the response.

  Teams work in parallel and may need to consult each other without taking action
  in each other's domain. This tool provides a lateral, read-only channel:
  one team asks, the other team answers, no assignments are made.

  ## Actions

  - `ask`    — send a question to a target team (async; returns a query_id).
  - `poll`   — check whether a query has been answered yet.
  - `answer` — (for agents on the receiving team) post an answer to a query.
  - `list`   — list all pending queries directed at your team.

  ## Boundary enforcement

  This tool enforces the read-only constraint: asking is a read operation, and
  answering a query does not commit any work on the receiving team. Any follow-on
  action requires the receiving team's orchestrator to create a new task.
  """
  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Peer.Discovery

  @impl true
  def name, do: "cross_team_query"

  @impl true
  def description do
    "Send a read-only question to another team and get a response. " <>
      "Use to consult experts in another team without crossing work boundaries. " <>
      "Does not assign work — information only."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["ask", "poll", "answer", "list"],
          "description" =>
            "ask: send question, poll: check answer, answer: reply to a query, list: see pending queries"
        },
        "target_team" => %{
          "type" => "string",
          "description" => "Team ID to ask (required for 'ask')."
        },
        "question" => %{
          "type" => "string",
          "description" => "Question to send (required for 'ask')."
        },
        "query_id" => %{
          "type" => "string",
          "description" => "Query ID from a prior 'ask' call (required for 'poll'/'answer')."
        },
        "answer" => %{
          "type" => "string",
          "description" => "Answer to the query (required for 'answer')."
        },
        "team_id" => %{
          "type" => "string",
          "description" => "Your team ID (used for 'list')."
        }
      }
    }
  end

  @impl true
  def safety, do: :read_only

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  @impl true
  def execute(%{"action" => "ask", "target_team" => target_team, "question" => question} = args) do
    from_team = Map.get(args, "team_id", Map.get(args, "__session_id__", "unknown"))

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

  def execute(%{"action" => "ask"}) do
    {:error, "Missing required parameters: target_team and question are required for 'ask'."}
  end

  def execute(%{"action" => "poll", "query_id" => query_id}) do
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

  def execute(%{"action" => "answer", "query_id" => query_id, "answer" => answer} = args) do
    agent_id = Map.get(args, "__session_id__", "unknown")

    case Discovery.answer_query(agent_id, query_id, answer) do
      :ok ->
        {:ok, "Answer submitted for query #{query_id}. The requesting team has been notified."}

      {:error, reason} ->
        {:error, "Failed to submit answer: #{reason}"}
    end
  end

  def execute(%{"action" => "answer"}) do
    {:error, "Missing required parameters: query_id and answer are required for 'answer'."}
  end

  def execute(%{"action" => "list"} = args) do
    team_id = Map.get(args, "team_id", Map.get(args, "__session_id__", "unknown"))

    # Scan all queries in ETS — filter to those directed at this team
    queries =
      try do
        :ets.tab2list(:osa_peer_queries)
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

  def execute(_) do
    {:error, "Invalid parameters. Required: action (ask|poll|answer|list)."}
  end
end
