defmodule OptimalSystemAgent.Swarm.Mailbox do
  @moduledoc """
  Shared communication channel for swarm agents.

  Agents post messages to the mailbox. Other agents can read messages
  from specific agents or all messages. This enables collaboration
  without tight coupling between workers.

  Implementation uses ETS for fast concurrent reads with minimal serialisation.
  The GenServer only coordinates table creation and deletion; all reads go
  directly to ETS without passing through the GenServer process.

  Message schema:
    {swarm_id, seq, from_agent_id, message, posted_at_ms}

  The `seq` field is a monotonically-increasing integer per swarm so that
  messages can be read in insertion order.
  """
  use GenServer
  require Logger

  @table :osa_swarm_mailbox

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Create a new mailbox partition for a swarm.
  Called by the Orchestrator immediately after a swarm is spawned.
  """
  def create(swarm_id) do
    GenServer.call(__MODULE__, {:create, swarm_id})
  end

  @doc """
  Post a message from an agent to the swarm mailbox.
  Assigns a monotonically-increasing sequence number for ordered reads.
  """
  def post(swarm_id, from_agent_id, message) do
    seq = :ets.update_counter(@table, {:seq, swarm_id}, {2, 1}, {{:seq, swarm_id}, 0})

    record = {swarm_id, seq, from_agent_id, message, System.monotonic_time(:millisecond)}
    :ets.insert(@table, record)
    :ok
  rescue
    e ->
      Logger.warning("Mailbox.post failed for swarm #{swarm_id}: #{inspect(e)}")
      :ok
  end

  @doc """
  Read all messages in a swarm, sorted by insertion order.
  Returns a list of maps: %{seq, from, message, posted_at_ms}
  """
  def read_all(swarm_id) do
    # Match pattern: {swarm_id, seq, from, message, posted_at_ms}
    # Skip the sequence counter record (key is a tuple {:seq, swarm_id})
    :ets.match_object(@table, {swarm_id, :_, :_, :_, :_})
    |> Enum.sort_by(fn {_, seq, _, _, _} -> seq end)
    |> Enum.map(fn {_, seq, from, message, posted_at_ms} ->
      %{seq: seq, from: from, message: message, posted_at_ms: posted_at_ms}
    end)
  rescue
    _ -> []
  end

  @doc """
  Read messages from a specific agent within a swarm, sorted by insertion order.
  """
  def read_from(swarm_id, agent_id) do
    :ets.match_object(@table, {swarm_id, :_, agent_id, :_, :_})
    |> Enum.sort_by(fn {_, seq, _, _, _} -> seq end)
    |> Enum.map(fn {_, seq, from, message, posted_at_ms} ->
      %{seq: seq, from: from, message: message, posted_at_ms: posted_at_ms}
    end)
  rescue
    _ -> []
  end

  @doc """
  Clear the mailbox for a completed or cancelled swarm.
  Deletes all messages and the sequence counter for that swarm.
  """
  def clear(swarm_id) do
    :ets.match_delete(@table, {swarm_id, :_, :_, :_, :_})
    :ets.delete(@table, {:seq, swarm_id})
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Build a human-readable context string of all messages in a swarm.
  Used by workers to include peer context in their LLM prompt.
  """
  def build_context(swarm_id) do
    messages = read_all(swarm_id)

    if messages == [] do
      nil
    else
      lines =
        Enum.map(messages, fn %{from: from, message: msg} ->
          "[#{from}]: #{msg}"
        end)

      "## Swarm Mailbox (peer messages)\n" <> Enum.join(lines, "\n")
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :public, :bag, {:read_concurrency, true}])
    Logger.info("Swarm mailbox ETS table created: #{inspect(table)}")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:create, swarm_id}, _from, state) do
    # Insert the sequence counter record with initial value 0
    :ets.insert_new(@table, {{:seq, swarm_id}, 0})
    Logger.debug("Mailbox created for swarm #{swarm_id}")
    {:reply, :ok, state}
  end
end
