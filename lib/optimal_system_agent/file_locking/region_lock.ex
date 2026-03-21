defmodule OptimalSystemAgent.FileLocking.RegionLock do
  @moduledoc """
  Region-Level File Locking — multiple agents can edit the same file simultaneously
  by claiming non-overlapping line ranges.

  Each claim is `{agent_id, file_path, start_line, end_line}` keyed by a generated
  `region_id`. Before writing any line range, an agent calls `claim_region/4`; the
  GenServer checks for overlap with existing claims and either grants the claim or
  returns the conflicting holder.

  ## ETS tables

  - `:osa_region_locks` — `{region_id, claim_map}` — all active claims
  - `:osa_region_lock_index` — `{file_path, region_id}` (bag) — fast lookup by file

  Both tables are public for direct ETS reads from tool modules (hot path).
  Writes go through this GenServer to serialize overlap detection.

  ## Lock expiry

  Inactive claims are auto-expired every minute. A claim is considered active if
  its `last_active_at` timestamp is within the last 10 minutes. On each successful
  write to the region, the agent should call `touch_region/2` to reset the timer.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.FileLocking.IntentBroadcaster

  @locks_table :osa_region_locks
  @index_table :osa_region_lock_index
  @expiry_ms 10 * 60 * 1_000
  @sweep_interval_ms 60 * 1_000

  # ---------------------------------------------------------------------------
  # Structs
  # ---------------------------------------------------------------------------

  defstruct [
    :region_id,
    :agent_id,
    :file_path,
    :start_line,
    :end_line,
    :claimed_at,
    :last_active_at
  ]

  @type t :: %__MODULE__{
          region_id: String.t(),
          agent_id: String.t(),
          file_path: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          claimed_at: DateTime.t(),
          last_active_at: DateTime.t()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Claim an exclusive region of a file.

  Returns `:ok` with the `region_id` on success, or `{:conflict, holder_claim}` if
  any existing claim overlaps the requested range.

  ## Parameters

    * `agent_id`    — the requesting agent
    * `file_path`   — absolute path to the file
    * `start_line`  — first line of the region (1-indexed, inclusive)
    * `end_line`    — last line of the region (inclusive)
  """
  @spec claim_region(
          agent_id :: String.t(),
          file_path :: String.t(),
          start_line :: pos_integer(),
          end_line :: pos_integer()
        ) :: {:ok, String.t()} | {:conflict, t()}
  def claim_region(agent_id, file_path, start_line, end_line) do
    GenServer.call(__MODULE__, {:claim, agent_id, file_path, start_line, end_line})
  end

  @doc """
  Release a previously claimed region.

  Silently ignores unknown region IDs (idempotent).
  """
  @spec release_region(
          agent_id :: String.t(),
          file_path :: String.t(),
          region_id :: String.t()
        ) :: :ok
  def release_region(agent_id, file_path, region_id) do
    GenServer.call(__MODULE__, {:release, agent_id, file_path, region_id})
  end

  @doc """
  List all active claims on a file.

  Returns a list of claim structs sorted by `start_line`.
  Reads directly from ETS — no GenServer round-trip.
  """
  @spec list_claims(file_path :: String.t()) :: [t()]
  def list_claims(file_path) do
    region_ids =
      :ets.lookup(@index_table, file_path)
      |> Enum.map(fn {_, region_id} -> region_id end)

    region_ids
    |> Enum.flat_map(fn rid ->
      case :ets.lookup(@locks_table, rid) do
        [{_, claim}] -> [claim]
        [] -> []
      end
    end)
    |> Enum.sort_by(& &1.start_line)
  rescue
    _ -> []
  end

  @doc """
  Reset the inactivity timer for a region.

  Call after each successful write to the region to prevent auto-expiry.
  """
  @spec touch_region(agent_id :: String.t(), region_id :: String.t()) :: :ok
  def touch_region(agent_id, region_id) do
    case :ets.lookup(@locks_table, region_id) do
      [{_, %{agent_id: ^agent_id} = claim}] ->
        :ets.insert(@locks_table, {region_id, %{claim | last_active_at: DateTime.utc_now()}})
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@locks_table, [:named_table, :public, :set])
    :ets.new(@index_table, [:named_table, :public, :bag])

    # Schedule periodic expiry sweep
    schedule_sweep()

    Logger.info("[RegionLock] Started — ETS tables initialised")
    {:ok, %{}}
  rescue
    ArgumentError ->
      # Tables already exist (test restarts etc.)
      schedule_sweep()
      {:ok, %{}}
  end

  @impl true
  def handle_call({:claim, agent_id, file_path, start_line, end_line}, _from, state) do
    case find_conflict(file_path, start_line, end_line) do
      nil ->
        region_id = "region_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        now = DateTime.utc_now()

        claim = %__MODULE__{
          region_id: region_id,
          agent_id: agent_id,
          file_path: file_path,
          start_line: start_line,
          end_line: end_line,
          claimed_at: now,
          last_active_at: now
        }

        :ets.insert(@locks_table, {region_id, claim})
        :ets.insert(@index_table, {file_path, region_id})

        # Broadcast intent to other agents working on this file
        IntentBroadcaster.broadcast_intent(
          agent_id,
          file_path,
          "claimed lines #{start_line}–#{end_line}"
        )

        Logger.debug(
          "[RegionLock] #{agent_id} claimed #{file_path}:#{start_line}–#{end_line} (#{region_id})"
        )

        {:reply, {:ok, region_id}, state}

      conflicting_claim ->
        Logger.debug(
          "[RegionLock] #{agent_id} conflict on #{file_path}:#{start_line}–#{end_line} — " <>
            "held by #{conflicting_claim.agent_id}"
        )

        {:reply, {:conflict, conflicting_claim}, state}
    end
  end

  def handle_call({:release, agent_id, file_path, region_id}, _from, state) do
    case :ets.lookup(@locks_table, region_id) do
      [{_, %{agent_id: ^agent_id}}] ->
        :ets.delete(@locks_table, region_id)
        :ets.match_delete(@index_table, {file_path, region_id})

        IntentBroadcaster.broadcast_intent(
          agent_id,
          file_path,
          "released region #{region_id}"
        )

        Logger.debug("[RegionLock] #{agent_id} released #{region_id}")

      _ ->
        # Not owner or not found — silently ignore
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep_expired, state) do
    now_ms = System.system_time(:millisecond)

    expired =
      :ets.tab2list(@locks_table)
      |> Enum.filter(fn {_, claim} ->
        age_ms = now_ms - DateTime.to_unix(claim.last_active_at, :millisecond)
        age_ms > @expiry_ms
      end)

    Enum.each(expired, fn {region_id, claim} ->
      :ets.delete(@locks_table, region_id)
      :ets.match_delete(@index_table, {claim.file_path, region_id})

      Logger.info(
        "[RegionLock] Auto-expired #{region_id} (#{claim.file_path}:#{claim.start_line}–#{claim.end_line}" <>
          " held by #{claim.agent_id})"
      )
    end)

    schedule_sweep()
    {:noreply, state}
  rescue
    _ ->
      schedule_sweep()
      {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Find any claim on the file that overlaps [start_line, end_line].
  # Two ranges overlap if start1 <= end2 AND start2 <= end1.
  defp find_conflict(file_path, start_line, end_line) do
    file_path
    |> list_claims()
    |> Enum.find(fn claim ->
      claim.start_line <= end_line and start_line <= claim.end_line
    end)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired, @sweep_interval_ms)
  end
end
