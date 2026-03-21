defmodule OptimalSystemAgent.Speculative.Executor do
  @moduledoc """
  Speculative Execution GenServer.

  Agents work ahead on likely next steps before being formally assigned. If the
  predictions hold, the work is promoted — zero re-work. If predictions break,
  all speculative artifacts are discarded cleanly with no side effects.

  ## Lifecycle

      start_speculative/3
        → {:ok, speculative_id}
        → status: :running

      check_assumptions/2       ← call any time to validate
        → {:ok, confirmed}      → status remains :running
        → {:invalidated, fails} → status: :invalidated, work product discarded

      promote/1                 ← call when actual task arrives and matches
        → {:ok, work_product}   → status: :promoted
        → {:error, reason}      → status: :failed

      discard/1                 ← explicit discard (e.g. different task arrived)
        → :ok                   → status: :discarded

  ## State per speculative execution

      %{
        id:            String.t(),           # speculative_id
        agent_id:      String.t(),
        predicted_task: map(),               # what we're working on
        assumptions:   [Assumption.t()],     # must hold for promotion
        work_product:  WorkProduct.t(),      # isolated artifacts
        status:        :running | :promoted | :invalidated | :discarded | :failed,
        started_at:    DateTime.t(),
        resolved_at:   DateTime.t() | nil
      }

  Multiple concurrent speculative executions per agent are supported, each
  tracked under its own `speculative_id` in the GenServer's ETS table.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Speculative.Assumption
  alias OptimalSystemAgent.Speculative.WorkProduct
  alias OptimalSystemAgent.Events.Bus

  @table :osa_speculative_executions

  # ── Child Spec ─────────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # ── Client API ────────────────────────────────────────────────────────────

  @doc """
  Start a speculative execution for an agent.

  ## Parameters
  - `agent_id`        — the agent doing the work
  - `predicted_task`  — map describing the expected upcoming task
  - `assumptions`     — list of assumption description strings that must hold

  Returns `{:ok, speculative_id}` or `{:error, reason}`.
  """
  @spec start_speculative(String.t(), map(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def start_speculative(agent_id, predicted_task, assumptions) when is_list(assumptions) do
    GenServer.call(__MODULE__, {:start, agent_id, predicted_task, assumptions})
  end

  @doc """
  Check assumptions for a speculative execution against `current_context`.

  `check_fn` is `(assumption, context) -> :ok | {:invalid, reason}`.
  If omitted, a default pass-through function is used (all assumptions confirmed).

  Returns `{:ok, speculative_record}` if all hold, or
  `{:invalidated, speculative_record}` if any broke — work product is discarded
  automatically on invalidation.
  """
  @spec check_assumptions(String.t(), map(), function() | nil) ::
          {:ok, map()} | {:invalidated, map()} | {:error, :not_found}
  def check_assumptions(speculative_id, current_context \\ %{}, check_fn \\ nil) do
    GenServer.call(__MODULE__, {:check_assumptions, speculative_id, current_context, check_fn})
  end

  @doc """
  Promote speculative work to real state.

  Should be called when the actual assigned task matches the prediction and
  all assumptions are confirmed. Copies staged files to their real paths and
  returns the work product for message dispatching.

  Returns `{:ok, work_product}` or `{:error, reason}`.
  """
  @spec promote(String.t()) :: {:ok, WorkProduct.t()} | {:error, term()}
  def promote(speculative_id) do
    GenServer.call(__MODULE__, {:promote, speculative_id})
  end

  @doc """
  Discard a speculative execution.

  Cleans up all artifacts. Use when a different task arrives than predicted.
  Always returns `:ok`.
  """
  @spec discard(String.t()) :: :ok
  def discard(speculative_id) do
    GenServer.call(__MODULE__, {:discard, speculative_id})
  end

  @doc "Get the record for a speculative execution."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(speculative_id) do
    case :ets.lookup(@table, speculative_id) do
      [{_, record}] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc "List all speculative executions for an agent."
  @spec list_for_agent(String.t()) :: [map()]
  def list_for_agent(agent_id) do
    :ets.match_object(@table, {:_, %{agent_id: agent_id}})
    |> Enum.map(fn {_, record} -> record end)
    |> Enum.sort_by(& &1.started_at)
  rescue
    _ -> []
  end

  @doc "List all active (running) speculative executions."
  @spec list_active() :: [map()]
  def list_active do
    :ets.match_object(@table, {:_, %{status: :running}})
    |> Enum.map(fn {_, record} -> record end)
  rescue
    _ -> []
  end

  @doc "Add a work product artifact after start (e.g. from inside the agent)."
  @spec update_work_product(String.t(), (WorkProduct.t() -> WorkProduct.t())) ::
          :ok | {:error, term()}
  def update_work_product(speculative_id, update_fn) when is_function(update_fn, 1) do
    GenServer.call(__MODULE__, {:update_work_product, speculative_id, update_fn})
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set])
    Logger.info("[Speculative.Executor] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start, agent_id, predicted_task, assumption_strings}, _from, state) do
    spec_id = generate_id()
    now = DateTime.utc_now()
    work_product = WorkProduct.new(spec_id)
    assumptions = Assumption.from_descriptions(assumption_strings)

    record = %{
      id: spec_id,
      agent_id: agent_id,
      predicted_task: predicted_task,
      assumptions: assumptions,
      work_product: work_product,
      status: :running,
      started_at: now,
      resolved_at: nil
    }

    :ets.insert(@table, {spec_id, record})

    Bus.emit(:system_event, %{
      event: :speculative_started,
      speculative_id: spec_id,
      agent_id: agent_id,
      predicted_task: predicted_task,
      assumption_count: length(assumptions)
    })

    Logger.info("[Speculative.Executor] #{spec_id} started for agent #{agent_id} — #{length(assumptions)} assumption(s)")
    {:reply, {:ok, spec_id}, state}
  end

  def handle_call({:check_assumptions, spec_id, context, check_fn}, _from, state) do
    case :ets.lookup(@table, spec_id) do
      [{_, %{status: :running} = record}] ->
        effective_check = check_fn || fn _a, _ctx -> :ok end

        case Assumption.check_assumptions(record.assumptions, context, effective_check) do
          {:ok, confirmed_assumptions} ->
            updated = %{record | assumptions: confirmed_assumptions}
            :ets.insert(@table, {spec_id, updated})
            {:reply, {:ok, updated}, state}

          {:invalidated, failed} ->
            WorkProduct.discard(record.work_product)
            now = DateTime.utc_now()

            updated = %{
              record
              | status: :invalidated,
                assumptions: failed,
                work_product: %{record.work_product | status: :discarded},
                resolved_at: now
            }

            :ets.insert(@table, {spec_id, updated})

            Bus.emit(:system_event, %{
              event: :speculative_invalidated,
              speculative_id: spec_id,
              agent_id: record.agent_id,
              failed_assumptions: Enum.map(failed, &Assumption.to_map/1)
            })

            Logger.info("[Speculative.Executor] #{spec_id} invalidated — #{length(failed)} assumption(s) broke")
            {:reply, {:invalidated, updated}, state}
        end

      [{_, %{status: status}}] ->
        {:reply, {:error, "Cannot check assumptions — status is #{status}"}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:promote, spec_id}, _from, state) do
    case :ets.lookup(@table, spec_id) do
      [{_, %{status: :running} = record}] ->
        case WorkProduct.promote(record.work_product) do
          {:ok, promoted_wp} ->
            now = DateTime.utc_now()

            updated = %{
              record
              | status: :promoted,
                work_product: promoted_wp,
                resolved_at: now
            }

            :ets.insert(@table, {spec_id, updated})

            Bus.emit(:system_event, %{
              event: :speculative_promoted,
              speculative_id: spec_id,
              agent_id: record.agent_id,
              work_product_summary: WorkProduct.summary(promoted_wp)
            })

            Logger.info("[Speculative.Executor] #{spec_id} promoted — work applied to real state")
            {:reply, {:ok, promoted_wp}, state}

          {:error, reason} ->
            now = DateTime.utc_now()
            updated = %{record | status: :failed, resolved_at: now}
            :ets.insert(@table, {spec_id, updated})
            Logger.warning("[Speculative.Executor] #{spec_id} promotion failed: #{reason}")
            {:reply, {:error, reason}, state}
        end

      [{_, %{status: status}}] ->
        {:reply, {:error, "Cannot promote — status is #{status}"}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:discard, spec_id}, _from, state) do
    case :ets.lookup(@table, spec_id) do
      [{_, record}] when record.status in [:running, :invalidated] ->
        WorkProduct.discard(record.work_product)
        now = DateTime.utc_now()
        updated = %{record | status: :discarded, resolved_at: now}
        :ets.insert(@table, {spec_id, updated})

        Bus.emit(:system_event, %{
          event: :speculative_discarded,
          speculative_id: spec_id,
          agent_id: record.agent_id
        })

        Logger.info("[Speculative.Executor] #{spec_id} discarded")
        {:reply, :ok, state}

      [{_, %{status: status}}] ->
        Logger.debug("[Speculative.Executor] discard called on #{spec_id} with status #{status} — no-op")
        {:reply, :ok, state}

      [] ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:update_work_product, spec_id, update_fn}, _from, state) do
    case :ets.lookup(@table, spec_id) do
      [{_, %{status: :running} = record}] ->
        updated_wp = update_fn.(record.work_product)
        :ets.insert(@table, {spec_id, %{record | work_product: updated_wp}})
        {:reply, :ok, state}

      [{_, %{status: status}}] ->
        {:reply, {:error, "Cannot update work product — status is #{status}"}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp generate_id do
    "spec_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
