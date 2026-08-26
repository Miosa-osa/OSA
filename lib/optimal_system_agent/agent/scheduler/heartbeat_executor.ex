defmodule OptimalSystemAgent.Agent.Scheduler.HeartbeatExecutor do
  @moduledoc """
  Paperclip-style heartbeat execution engine for scheduled tasks.

  Flow: create run → acquire lock → budget check → execute → capture → persist → emit
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Scheduler.JobExecutor
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Store.Repo

  @default_timeout_ms 300_000
  @max_timeout_ms 1_800_000

  defstruct locks: %{}, runs: %{}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def execute(scheduled_task, trigger_type \\ :schedule) do
    GenServer.call(__MODULE__, {:execute, scheduled_task, trigger_type}, 35_000)
  end

  def get_run(run_id) do
    GenServer.call(__MODULE__, {:get_run, run_id})
  end

  def list_runs(task_id, opts \\ []) do
    GenServer.call(__MODULE__, {:list_runs, task_id, opts})
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:execute, task, trigger_type}, _from, state) do
    agent_name = task["agent_name"] || task["name"] || "unknown"

    if Map.has_key?(state.locks, agent_name) do
      {:reply, {:error, :locked}, state}
    else
      state = %{state | locks: Map.put(state.locks, agent_name, true)}
      {result, run, state} = do_execute(task, trigger_type, state)
      state = %{state | locks: Map.delete(state.locks, agent_name)}
      {:reply, execute_reply(result, run), state}
    end
  end

  @impl true
  def handle_call({:get_run, run_id}, _from, state) do
    {:reply, Map.get(state.runs, run_id), state}
  end

  @impl true
  def handle_call({:list_runs, task_id, opts}, _from, state) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    runs =
      state.runs
      |> Map.values()
      |> Enum.filter(&(&1.scheduled_task_id == task_id))
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.drop((page - 1) * per_page)
      |> Enum.take(per_page)

    {:reply, runs, state}
  end

  defp do_execute(task, trigger_type, state) do
    run_id = generate_run_id()
    task_id = task["id"]
    agent_name = task["agent_name"] || task["name"] || "unknown"
    timeout_ms = min(task["timeout_ms"] || @default_timeout_ms, @max_timeout_ms)
    now = DateTime.utc_now()

    run = %{
      id: run_id,
      scheduled_task_id: task_id,
      agent_name: agent_name,
      status: "running",
      trigger_type: to_string(trigger_type),
      started_at: now,
      completed_at: nil,
      duration_ms: nil,
      exit_code: nil,
      stdout: nil,
      stderr: nil,
      token_usage: %{},
      session_state: %{},
      error_message: nil,
      metadata: %{}
    }

    emit_event(:system_event, %{
      event: :task_run_started,
      task_id: task_id,
      run_id: run_id,
      agent_name: agent_name,
      trigger_type: trigger_type
    })

    case check_budget() do
      :ok ->
        {result, run} = execute_with_timeout(task, run, timeout_ms)
        state = %{state | runs: Map.put(state.runs, run_id, run)}
        persist_run(run)
        {result, run, state}

      {:error, :budget_exceeded} ->
        run = %{
          run
          | status: "failed",
            completed_at: DateTime.utc_now(),
            duration_ms: 0,
            error_message: "Budget exceeded"
        }

        state = %{state | runs: Map.put(state.runs, run_id, run)}
        persist_run(run)
        emit_run_failed(run)
        {{:error, :budget_exceeded}, run, state}
    end
  end

  defp execute_reply({:error, reason}, _run), do: {:error, reason}
  defp execute_reply(other, run), do: {other, run}

  defp execute_with_timeout(task, run, timeout_ms) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        result = JobExecutor.execute_cron_job(task)
        send(parent, {ref, result})
      end)

    receive do
      {^ref, {:ok, output}} ->
        now = DateTime.utc_now()
        duration = DateTime.diff(now, run.started_at, :millisecond)

        run = %{
          run
          | status: "succeeded",
            completed_at: now,
            duration_ms: duration,
            stdout: truncate_output(output),
            exit_code: 0
        }

        emit_event(:system_event, %{
          event: :task_run_completed,
          run_id: run.id,
          status: "succeeded",
          duration_ms: duration,
          token_usage: run.token_usage
        })

        {:ok, run}

      {^ref, {:error, reason}} ->
        now = DateTime.utc_now()
        duration = DateTime.diff(now, run.started_at, :millisecond)

        run = %{
          run
          | status: "failed",
            completed_at: now,
            duration_ms: duration,
            error_message: to_string(reason),
            exit_code: 1
        }

        emit_run_failed(run)
        {:error, run}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        now = DateTime.utc_now()
        duration = DateTime.diff(now, run.started_at, :millisecond)

        run = %{
          run
          | status: "timed_out",
            completed_at: now,
            duration_ms: duration,
            error_message: "Timed out after #{timeout_ms}ms"
        }

        emit_run_failed(run)
        {:error, run}
    end
  end

  defp check_budget do
    mod = OptimalSystemAgent.Agent.Treasury

    if Code.ensure_loaded?(mod) and function_exported?(mod, :get_balance, 0) do
      case apply(mod, :get_balance, []) do
        {:ok, %{available: available}} when available > 0 -> :ok
        {:ok, _} -> {:error, :budget_exceeded}
        _ -> :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp persist_run(run) do
    try do
      Repo.insert_all("scheduled_runs", [
        %{
          scheduled_task_id: run.scheduled_task_id,
          agent_name: run.agent_name,
          status: run.status,
          trigger_type: run.trigger_type,
          started_at: run.started_at,
          completed_at: run.completed_at,
          duration_ms: run.duration_ms,
          exit_code: run.exit_code,
          stdout: run.stdout,
          stderr: run.stderr,
          token_usage: Jason.encode!(run.token_usage),
          session_state: Jason.encode!(run.session_state),
          error_message: run.error_message,
          metadata: Jason.encode!(run.metadata),
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ])
    rescue
      e -> Logger.warning("[HeartbeatExecutor] Failed to persist run: #{Exception.message(e)}")
    end
  end

  defp emit_run_failed(run) do
    emit_event(:system_event, %{
      event: :task_run_failed,
      run_id: run.id,
      error_message: run.error_message
    })
  end

  defp emit_event(type, payload) do
    try do
      Bus.emit(type, payload)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp truncate_output(nil), do: nil

  defp truncate_output(output) when byte_size(output) > 10_240 do
    :zlib.gzip(output) |> Base.encode64()
  end

  defp truncate_output(output), do: output

  defp generate_run_id do
    "run_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
