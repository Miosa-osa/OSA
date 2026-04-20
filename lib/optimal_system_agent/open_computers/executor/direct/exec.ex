defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Exec do
  @moduledoc """
  Executes shell commands on behalf of exec_request frames from the control plane.

  ## Design

  One `GenServer` per OSA session tracks in-flight jobs. When an `:exec_request`
  arrives it spawns a linked `Task` per job. Each task opens a `Port` to the OS
  process, streams `{:data, binary}` chunks back to the session as `:exec_chunk`
  frames, and terminates with an `:exec_result` or `:exec_error` frame.

  Cancel is handled by sending `{:exec_cancel, %{job_id: job_id}}` to this
  GenServer, which kills the task + port for that job.

  ## Security

  Before spawning, `Executor.Config.command_allowed?/1` is consulted. If the
  command is not allowed, `:exec_error` with reason `:command_not_allowed` is
  sent immediately without touching the OS.

  ## v1 limitation

  stderr is merged into stdout (`stderr_to_stdout: true`) and tagged `:stdout`.
  True separation requires two ports or an `:erlexec`/`:porcelain` dependency —
  deferred to v2.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor.Config

  # ── API ───────────────────────────────────────────────────────────────────

  @doc "Start a per-session exec manager. `session_pid` is sent result frames."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start an exec job. `payload` is the `:exec_request` map from the control plane.
  `session_pid` receives `{:exec_chunk, ...}`, `{:exec_result, ...}`, `{:exec_error, ...}`.
  """
  @spec start_job(pid(), map()) :: :ok | {:error, atom()}
  def start_job(pid, payload) when is_pid(pid) and is_map(payload) do
    GenServer.call(pid, {:start_job, payload}, 5_000)
  catch
    :exit, _ -> {:error, :exec_manager_down}
  end

  @doc "Cancel an in-flight job by `job_id`."
  @spec cancel_job(pid(), binary()) :: :ok
  def cancel_job(pid, job_id) when is_pid(pid) and is_binary(job_id) do
    GenServer.cast(pid, {:cancel_job, job_id})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    session_pid = Keyword.fetch!(opts, :session_pid)
    # %{job_id => %{task: task, started_at: monotonic_ms}}
    {:ok, %{session_pid: session_pid, jobs: %{}}}
  end

  @impl true
  def handle_call({:start_job, payload}, _from, state) do
    job_id = payload[:job_id] || payload["job_id"]
    cmd = payload[:cmd] || payload["cmd"]
    args = payload[:args] || payload["args"] || []
    env = payload[:env] || payload["env"] || []
    cwd = payload[:cwd] || payload["cwd"] || Path.expand("~")
    timeout_ms = min(
      payload[:timeout_ms] || payload["timeout_ms"] || 30_000,
      Config.max_timeout_ms()
    )

    if not Config.command_allowed?(cmd) do
      send(state.session_pid, {:exec_error, %{job_id: job_id, reason: :command_not_allowed}})
      {:reply, {:error, :command_not_allowed}, state}
    else
      parent = self()

      task =
        Task.async(fn ->
          run_job(parent, state.session_pid, job_id, cmd, args, env, cwd, timeout_ms)
        end)

      new_jobs = Map.put(state.jobs, job_id, %{task: task, started_at: System.monotonic_time(:millisecond)})
      {:reply, :ok, %{state | jobs: new_jobs}}
    end
  end

  @impl true
  def handle_cast({:cancel_job, job_id}, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {:noreply, state}

      %{task: task} ->
        Task.shutdown(task, :brutal_kill)
        send(state.session_pid, {:exec_error, %{job_id: job_id, reason: :canceled}})
        {:noreply, %{state | jobs: Map.delete(state.jobs, job_id)}}
    end
  end

  # Task completion — clean up the job entry
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:job_done, job_id}, state) do
    {:noreply, %{state | jobs: Map.delete(state.jobs, job_id)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ───────────────────────────────────────────────────────────────

  defp run_job(manager_pid, session_pid, job_id, cmd, args, env, cwd, timeout_ms) do
    t0 = System.monotonic_time(:millisecond)
    resolved_cmd = System.find_executable(cmd) || cmd

    # Prepare env as charlist tuples for Port
    port_env =
      Enum.map(env, fn
        {k, v} -> {to_charlist(k), to_charlist(v)}
        %{"key" => k, "value" => v} -> {to_charlist(k), to_charlist(v)}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    port_args =
      if args == [] do
        [resolved_cmd]
      else
        [resolved_cmd | args]
      end

    cwd_charlist = to_charlist(Path.expand(cwd))

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, cwd_charlist},
        {:args, Enum.drop(port_args, 1)}
      ] ++ if port_env == [], do: [], else: [{:env, port_env}]

    port =
      try do
        Port.open({:spawn_executable, to_charlist(resolved_cmd)}, port_opts)
      rescue
        e ->
          send(session_pid, {:exec_error, %{job_id: job_id, reason: :spawn_error, message: Exception.message(e)}})
          send(manager_pid, {:job_done, job_id})
          throw(:spawn_failed)
      end

    drain_port(port, session_pid, job_id, t0, timeout_ms)
    send(manager_pid, {:job_done, job_id})
  catch
    :throw, :spawn_failed -> :ok
  end

  defp drain_port(port, session_pid, job_id, t0, timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        send(session_pid, {:exec_chunk, %{job_id: job_id, stream: :stdout, data: data}})
        drain_port(port, session_pid, job_id, t0, timeout_ms)

      {^port, {:exit_status, code}} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        send(session_pid, {:exec_result, %{job_id: job_id, exit_code: code, elapsed_ms: elapsed}})

      other ->
        Logger.debug("[OC.Exec] unexpected port message: #{inspect(other)}")
        drain_port(port, session_pid, job_id, t0, timeout_ms)
    after
      timeout_ms ->
        Port.close(port)
        elapsed = System.monotonic_time(:millisecond) - t0
        send(session_pid, {:exec_error, %{job_id: job_id, reason: :timeout, elapsed_ms: elapsed}})
    end
  end
end
