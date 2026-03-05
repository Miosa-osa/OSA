defmodule OptimalSystemAgent.Intelligence.ConversationTracker do
  @moduledoc """
  Tracks conversation depth per contact:
  casual → working → deep → strategic

  Adapts agent behavior based on depth — casual gets quick responses,
  strategic gets thorough analysis.

  Signal Theory — depth-adaptive conversation management.
  """
  use GenServer

  require Logger

  @table :osa_conversation_depth

  # Depth levels in order — each step up requires accumulated complexity
  @depths [:casual, :working, :deep, :strategic]

  # Technical keywords that increase complexity score
  @tech_keywords ~w(
    architecture api database schema migration deployment
    performance latency throughput concurrency async redis
    postgresql postgres docker kubernetes ci/cd pipeline
    authentication authorization jwt oauth ssl tls
    refactor function module struct interface class
    algorithm complexity recursion query index transaction
    error exception crash timeout retry circuit breaker
    monitoring metrics logging tracing observability
  )

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Record a new turn for the given session_id. Updates depth based on message content.
  Returns the updated depth atom.
  """
  def record_turn(session_id, message) when is_binary(session_id) and is_binary(message) do
    GenServer.call(__MODULE__, {:record_turn, session_id, message})
  end

  @doc "Returns the current depth level atom for the given session. Defaults to :casual."
  def get_depth(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, state}] -> state.depth
      [] -> :casual
    end
  end

  @doc """
  Returns {depth, turn_count, avg_complexity} for the given session.
  avg_complexity is a float 0.0–1.0.
  """
  def depth_summary(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, state}] ->
        avg =
          if state.turn_count == 0 do
            0.0
          else
            Float.round(state.total_complexity / state.turn_count, 3)
          end

        {state.depth, state.turn_count, avg}

      [] ->
        {:casual, 0, 0.0}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:record_turn, session_id, message}, _from, state) do
    session = load_session(session_id)
    complexity = compute_complexity(message)

    new_turn_count = session.turn_count + 1
    new_total = session.total_complexity + complexity
    new_depth = compute_depth(new_turn_count, new_total / new_turn_count)

    updated = %{
      depth: new_depth,
      turn_count: new_turn_count,
      total_complexity: new_total
    }

    :ets.insert(@table, {session_id, updated})

    {:reply, new_depth, state}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_session(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, s}] -> s
      [] -> %{depth: :casual, turn_count: 0, total_complexity: 0.0}
    end
  end

  # Returns a complexity score in 0.0–1.0 for a single message.
  # Based on word count (normalized) + fraction of technical keywords present.
  defp compute_complexity(message) do
    words =
      message
      |> String.downcase()
      |> String.split(~r/\W+/, trim: true)

    word_count = length(words)

    # Word-count component: saturates at 100 words → 0.5
    word_score = min(word_count / 100.0, 1.0) * 0.5

    # Keyword component: each unique keyword adds weight, saturates at 5 → 0.5
    keyword_hits =
      words
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(@tech_keywords))
      |> MapSet.size()

    keyword_score = min(keyword_hits / 5.0, 1.0) * 0.5

    Float.round(word_score + keyword_score, 3)
  end

  # Depth is determined by average complexity AND turn count together.
  # More turns + higher complexity = deeper engagement.
  defp compute_depth(turn_count, avg_complexity) do
    cond do
      avg_complexity >= 0.6 and turn_count >= 5 -> :strategic
      avg_complexity >= 0.4 and turn_count >= 3 -> :deep
      avg_complexity >= 0.2 or turn_count >= 2 -> :working
      true -> :casual
    end
    |> validate_depth()
  end

  # Clamp to known depth atoms (safety)
  defp validate_depth(depth) when depth in @depths, do: depth
  defp validate_depth(_), do: :casual
end
