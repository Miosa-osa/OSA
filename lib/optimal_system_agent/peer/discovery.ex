defmodule OptimalSystemAgent.Peer.Discovery do
  @moduledoc """
  Cross-Team Discovery — find agents across team boundaries and send lateral queries.

  Discovery is intentionally read-only at the protocol level. An agent may look
  up peers in other teams and ask them questions, but cannot assign work to them
  directly. Any cross-team action requires an explicit Handoff (`Peer.Protocol`)
  or a new task dispatched by the receiving team's orchestrator.

  ## Guarantees

    * Discovery never modifies another team's state.
    * Queries are delivered via PubSub; responses are async.
    * Team boundaries are respected: `query_cross_team/3` marks messages as
      cross-team so receiving agents know the provenance.

  ## ETS storage

  Agent registry at `:osa_peer_agents` — one row per registered agent:
  `{agent_id, agent_info_map}`.

  Pending cross-team queries at `:osa_peer_queries` — keyed by `query_id`.
  """

  require Logger

  @agents_table :osa_peer_agents
  @queries_table :osa_peer_queries

  # ---------------------------------------------------------------------------
  # ETS bootstrap
  # ---------------------------------------------------------------------------

  @doc "Create ETS tables for discovery. Called at application start."
  def init_tables do
    :ets.new(@agents_table, [:named_table, :public, :set])
    :ets.new(@queries_table, [:named_table, :public, :set])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Register an agent for discovery.

  `agent_info` should include at minimum:
    - `:team_id`     — which team this agent belongs to
    - `:role`        — agent role string (e.g. \"backend_elixir\", \"frontend_svelte\")
    - `:capabilities`— list of capability strings
    - `:available`   — boolean, whether this agent is currently accepting work
  """
  @spec register_agent(agent_id :: String.t(), agent_info :: map()) :: :ok
  def register_agent(agent_id, agent_info) do
    record =
      Map.merge(agent_info, %{
        agent_id: agent_id,
        registered_at: DateTime.utc_now()
      })

    :ets.insert(@agents_table, {agent_id, record})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Deregister an agent (e.g., when a session ends)."
  @spec deregister_agent(agent_id :: String.t()) :: :ok
  def deregister_agent(agent_id) do
    :ets.delete(@agents_table, agent_id)
    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  @doc """
  Discover agents matching query criteria.

  `query` is a map with optional filter keys:
    - `:team_id`      — filter to a specific team
    - `:role`         — exact role match
    - `:capability`   — agent must have this string in its capabilities list
    - `:available`    — if `true`, only return agents with `available: true`
    - `:exclude_team` — exclude agents from this team (e.g., your own team)

  `opts` currently unused, reserved for pagination/limit.

  Returns a list of agent info maps.
  """
  @spec discover_agents(query :: map(), opts :: keyword()) :: [map()]
  def discover_agents(query \\ %{}, _opts \\ []) do
    :ets.tab2list(@agents_table)
    |> Enum.map(fn {_, info} -> info end)
    |> apply_filters(query)
  rescue
    _ -> []
  end

  @doc """
  Send a lateral query to another team and receive an async response.

  The question is published on `\"osa:peer:query:<to_team>\"`. An agent on the
  receiving team must be subscribed and will reply via `answer_query/3`.

  Returns `{:ok, query_id}`. The caller should subscribe to
  `\"osa:peer:query_response:<query_id>\"` to receive the response.

  Note: this is a read-only operation. The receiving team decides whether and how
  to answer. It imposes no obligation on the receiving team.
  """
  @spec query_cross_team(
          from_team :: String.t(),
          to_team :: String.t(),
          question :: String.t()
        ) :: {:ok, String.t()} | {:error, String.t()}
  def query_cross_team(from_team, to_team, question) do
    query_id = "query_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    record = %{
      id: query_id,
      from_team: from_team,
      to_team: to_team,
      question: question,
      status: :pending,
      created_at: DateTime.utc_now(),
      answer: nil,
      answered_at: nil,
      answered_by: nil
    }

    :ets.insert(@queries_table, {query_id, record})

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:peer:query:#{to_team}",
      {:cross_team_query, record}
    )

    Logger.info(
      "[Peer.Discovery] Team #{from_team} → team #{to_team}: \"#{String.slice(question, 0, 80)}\""
    )

    {:ok, query_id}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Answer a cross-team query.

  `agent_id` is the answering agent. `query_id` identifies the original question.
  `answer` is the response string.

  Publishes the answer on `\"osa:peer:query_response:<query_id>\"` so the
  originating team can consume it.
  """
  @spec answer_query(
          agent_id :: String.t(),
          query_id :: String.t(),
          answer :: String.t()
        ) :: :ok | {:error, String.t()}
  def answer_query(agent_id, query_id, answer) do
    case :ets.lookup(@queries_table, query_id) do
      [] ->
        {:error, "Query #{query_id} not found"}

      [{_, record}] ->
        updated = %{
          record
          | status: :answered,
            answer: answer,
            answered_at: DateTime.utc_now(),
            answered_by: agent_id
        }

        :ets.insert(@queries_table, {query_id, updated})

        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:peer:query_response:#{query_id}",
          {:query_answered, updated}
        )

        Logger.info("[Peer.Discovery] #{agent_id} answered query #{query_id}")
        :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Retrieve a pending or answered query by ID."
  @spec get_query(String.t()) :: map() | nil
  def get_query(query_id) do
    case :ets.lookup(@queries_table, query_id) do
      [{_, record}] -> record
      [] -> nil
    end
  rescue
    _ -> nil
  end

  @doc "List all agents on a given team."
  @spec agents_on_team(team_id :: String.t()) :: [map()]
  def agents_on_team(team_id) do
    discover_agents(%{team_id: team_id})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp apply_filters(agents, query) do
    agents
    |> filter_by(:team_id, Map.get(query, :team_id))
    |> filter_by(:role, Map.get(query, :role))
    |> filter_by_capability(Map.get(query, :capability))
    |> filter_by_availability(Map.get(query, :available))
    |> exclude_team(Map.get(query, :exclude_team))
  end

  defp filter_by(agents, _key, nil), do: agents
  defp filter_by(agents, key, value), do: Enum.filter(agents, &(Map.get(&1, key) == value))

  defp filter_by_capability(agents, nil), do: agents

  defp filter_by_capability(agents, cap) do
    Enum.filter(agents, fn agent ->
      caps = Map.get(agent, :capabilities, [])
      cap in caps
    end)
  end

  defp filter_by_availability(agents, nil), do: agents

  defp filter_by_availability(agents, true) do
    Enum.filter(agents, &(Map.get(&1, :available, false) == true))
  end

  defp filter_by_availability(agents, false) do
    Enum.filter(agents, &(Map.get(&1, :available, true) == false))
  end

  defp exclude_team(agents, nil), do: agents

  defp exclude_team(agents, team_id) do
    Enum.reject(agents, &(Map.get(&1, :team_id) == team_id))
  end
end
