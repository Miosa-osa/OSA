defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.GhaRunner do
  @moduledoc """
  GenServer managing GitHub Actions self-hosted runners on this host.

  One GenServer for the entire OSA session. Routes `gha_runner_setup_request`
  frames from the control plane, manages the runner process lifecycle, and emits
  status frames back upstream.

  ## Per-runner lifecycle

    1. `gha_runner_setup_request` received → spawn setup task
    2. Emit `gha_runner_setup_progress` frames at each phase
    3. On `./config.sh` success: parse `.runner` JSON for gh_runner_id
    4. Start `./run.sh` as a background port/task
    5. Emit `gha_runner_ready`
    6. Every 30s: check if run.sh process is alive, emit `gha_runner_status`
    7. On `gha_runner_stop_request`:
       a. Kill run.sh process
       b. Obtain removal token from MIOSA (sent in stop_request) or skip
       c. Emit `gha_runner_removed`

  ## Download targets (actions/runner v2.320.0)

    * macOS arm64   → actions-runner-osx-arm64-2.320.0.tar.gz
    * macOS x64     → actions-runner-osx-x64-2.320.0.tar.gz
    * Linux x64     → actions-runner-linux-x64-2.320.0.tar.gz
    * Linux arm64   → actions-runner-linux-arm64-2.320.0.tar.gz
    * Windows x64   → actions-runner-win-x64-2.320.0.zip

  ## Process model

  The GenServer holds a map of active runners:
    `%{runner_id => %{pid: pid, status_timer: ref, dir: String.t()}}`

  The `run.sh` process is launched via `Task.async` and its port is stored
  as a Task ref. A `:status_tick` message is sent every 30 seconds per runner.

  ## Feature flag

  `Config.gha_runner_enabled?/0` must return `true` (default) for setup to proceed.
  Toggle via `~/.osa/open_computers.toml`:

      gha_runner_enabled = false
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter
  alias OptimalSystemAgent.OpenComputers.Config

  @runner_version "2.320.0"
  @base_url "https://github.com/actions/runner/releases/download/v#{@runner_version}"
  @download_timeout_ms 5 * 60 * 1_000
  @status_interval_ms 30_000

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @doc "Route an inbound frame to this executor."
  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:inbound, frame})
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{runners: %{}}}
  end

  @impl true
  def handle_cast({:inbound, {:gha_runner_setup_request, payload}}, state) do
    runner_id = payload.runner_id

    unless gha_runner_enabled?() do
      FrameRouter.send_frame(
        {:gha_runner_error, %{runner_id: runner_id, reason: :feature_disabled, phase: :setup}}
      )

      {:noreply, state}
    else
      Logger.info("[GhaRunner] setup runner=#{runner_id} repo=#{payload.repo_url}")

      controller_pid = self()

      task =
        Task.async(fn ->
          result = setup_runner(payload, controller_pid)
          send(controller_pid, {:setup_done, runner_id, result})
          result
        end)

      entry = %{task: task, run_pid: nil, status_timer: nil, dir: runner_dir(runner_id)}
      {:noreply, put_in(state.runners[runner_id], entry)}
    end
  end

  def handle_cast({:inbound, {:gha_runner_stop_request, %{runner_id: runner_id}}}, state) do
    Logger.info("[GhaRunner] stop runner=#{runner_id}")

    case Map.get(state.runners, runner_id) do
      nil ->
        Logger.warning("[GhaRunner] stop for unknown runner #{runner_id}")
        FrameRouter.send_frame({:gha_runner_removed, %{runner_id: runner_id}})

      entry ->
        teardown_runner(runner_id, entry)
    end

    {:noreply, update_in(state.runners, &Map.delete(&1, runner_id))}
  end

  def handle_cast({:inbound, frame}, state) do
    Logger.debug("[GhaRunner] unhandled inbound frame: #{inspect(elem(frame, 0))}")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:setup_done, runner_id, {:ok, run_pid, gh_runner_id, installed_version}},
        state
      ) do
    Logger.info("[GhaRunner] runner=#{runner_id} online gh_runner_id=#{gh_runner_id}")

    entry = Map.get(state.runners, runner_id, %{})
    timer = schedule_status_tick(runner_id)

    updated_entry = Map.merge(entry, %{run_pid: run_pid, status_timer: timer})
    new_state = put_in(state.runners[runner_id], updated_entry)

    FrameRouter.send_frame(
      {:gha_runner_ready,
       %{
         runner_id: runner_id,
         gh_runner_id: gh_runner_id,
         labels: [],
         installed_version: installed_version
       }}
    )

    {:noreply, new_state}
  end

  def handle_info({:setup_done, runner_id, {:error, reason, phase}}, state) do
    Logger.error(
      "[GhaRunner] setup failed runner=#{runner_id} phase=#{phase} reason=#{inspect(reason)}"
    )

    FrameRouter.send_frame(
      {:gha_runner_error, %{runner_id: runner_id, reason: reason, phase: phase}}
    )

    {:noreply, update_in(state.runners, &Map.delete(&1, runner_id))}
  end

  def handle_info({:status_tick, runner_id}, state) do
    case Map.get(state.runners, runner_id) do
      nil ->
        {:noreply, state}

      entry ->
        {status, current_job} = check_runner_alive(entry)

        FrameRouter.send_frame(
          {:gha_runner_status, %{runner_id: runner_id, state: status, current_job: current_job}}
        )

        new_entry =
          if status == :offline do
            Logger.warning("[GhaRunner] runner=#{runner_id} process died")
            %{entry | status_timer: nil}
          else
            %{entry | status_timer: schedule_status_tick(runner_id)}
          end

        {:noreply, put_in(state.runners[runner_id], new_entry)}
    end
  end

  # Task completion messages
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Runner setup ─────────────────────────────────────────────────────────────

  defp setup_runner(payload, controller_pid) do
    runner_id = payload.runner_id
    dir = runner_dir(runner_id)

    emit_progress = fn phase, message ->
      send(
        controller_pid,
        {:relay_frame,
         {:gha_runner_setup_progress, %{runner_id: runner_id, phase: phase, message: message}}}
      )

      FrameRouter.send_frame(
        {:gha_runner_setup_progress, %{runner_id: runner_id, phase: phase, message: message}}
      )
    end

    with :ok <- File.mkdir_p(dir),
         {:ok, asset_url, filename} <- asset_for_platform(),
         _ <- emit_progress.(:downloading, "Downloading #{filename}…"),
         :ok <- download_runner(asset_url, Path.join(dir, filename)),
         _ <- emit_progress.(:extracting, "Extracting archive…"),
         :ok <- extract_runner(dir, filename),
         _ <- emit_progress.(:configuring, "Configuring runner…"),
         :ok <- configure_runner(dir, payload),
         {:ok, gh_runner_id} <- read_runner_id(dir),
         _ <- emit_progress.(:starting, "Starting run.sh…"),
         {:ok, run_pid} <- start_run_sh(dir) do
      {:ok, run_pid, gh_runner_id, @runner_version}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, reason, :setup}

      {:error, reason, phase} ->
        {:error, reason, phase}

      other ->
        Logger.error("[GhaRunner] setup unexpected: #{inspect(other)}")
        {:error, :unexpected_error, :setup}
    end
  end

  defp runner_dir(runner_id) do
    home = System.user_home!()
    Path.join([home, ".miosa", "gha-runners", runner_id])
  end

  defp asset_for_platform do
    os =
      case :os.type() do
        {:unix, :darwin} -> "osx"
        {:unix, _} -> "linux"
        {:win32, _} -> "win"
      end

    arch_str = :erlang.system_info(:system_architecture) |> to_string()

    arch =
      cond do
        String.contains?(arch_str, "arm") -> "arm64"
        String.contains?(arch_str, "aarch64") -> "arm64"
        true -> "x64"
      end

    ext = if os == "win", do: "zip", else: "tar.gz"
    filename = "actions-runner-#{os}-#{arch}-#{@runner_version}.#{ext}"
    url = "#{@base_url}/#{filename}"
    {:ok, url, filename}
  end

  defp download_runner(url, dest_path) do
    Logger.debug("[GhaRunner] downloading #{url}")

    case System.cmd("curl", [
           "-fL",
           "--max-time",
           to_string(div(@download_timeout_ms, 1_000)),
           "-o",
           dest_path,
           url
         ]) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.error("[GhaRunner] download failed exit=#{code} output=#{output}")
        {:error, :download_failed, :downloading}
    end
  end

  defp extract_runner(dir, filename) do
    path = Path.join(dir, filename)

    result =
      cond do
        String.ends_with?(filename, ".tar.gz") ->
          System.cmd("tar", ["xzf", path, "-C", dir])

        String.ends_with?(filename, ".zip") ->
          System.cmd("unzip", ["-q", path, "-d", dir])

        true ->
          {"unsupported format", 1}
      end

    case result do
      {_, 0} ->
        File.rm(path)
        :ok

      {output, code} ->
        Logger.error("[GhaRunner] extract failed exit=#{code} output=#{output}")
        {:error, :extract_failed, :extracting}
    end
  end

  # The runner registration token is a credential. It used to be passed as
  # `--token <token>`, i.e. an argv element — and `/proc/<pid>/cmdline` is
  # world-readable on Linux, so every local user could read it out of `ps` for
  # as long as config.sh ran. actions/runner's `CommandSettings` accepts every
  # argument via an `ACTIONS_RUNNER_INPUT_<NAME>` environment variable
  # (command-line args take precedence; the env var is masked in logs and
  # unset by the runner after it is read), and a process's environment block is
  # owner-readable only. So the token goes through the environment and the
  # non-secret arguments stay on argv.
  defp configure_runner(dir, payload) do
    config_sh = config_sh_path(dir)

    args =
      [
        "--url",
        payload.repo_url,
        "--name",
        payload.runner_name,
        "--labels",
        Enum.join(payload.labels, ","),
        "--unattended"
      ] ++ if(payload.ephemeral, do: ["--ephemeral"], else: [])

    env = [{"ACTIONS_RUNNER_INPUT_TOKEN", payload.registration_token}]

    case System.cmd(config_sh, args, cd: dir, env: env, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.error("[GhaRunner] config.sh failed exit=#{code} output=#{output}")
        {:error, :configure_failed, :configuring}
    end
  end

  defp read_runner_id(dir) do
    runner_file = Path.join(dir, ".runner")

    case File.read(runner_file) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"agentId" => id}} when is_integer(id) -> {:ok, id}
          _ -> {:ok, nil}
        end

      {:error, reason} ->
        Logger.warning("[GhaRunner] could not read .runner file: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  defp start_run_sh(dir) do
    run_sh = run_sh_path(dir)

    # Start run.sh as a detached port so the OS process survives GenServer restarts
    port =
      Port.open(
        {:spawn_executable, run_sh},
        [
          :exit_status,
          {:cd, dir},
          {:env, []},
          :hide
        ]
      )

    {:ok, port}
  rescue
    e ->
      Logger.error("[GhaRunner] failed to start run.sh: #{inspect(e)}")
      {:error, :start_failed, :starting}
  end

  # ── Runner teardown ──────────────────────────────────────────────────────────

  defp teardown_runner(runner_id, entry) do
    # Cancel status timer
    if entry.status_timer do
      Process.cancel_timer(entry.status_timer)
    end

    # Kill Task if still running
    if entry.task do
      Task.shutdown(entry.task, :brutal_kill)
    end

    # Kill run.sh port if alive
    if entry.run_pid && Port.info(entry.run_pid) != nil do
      Port.close(entry.run_pid)
    end

    # Run ./config.sh remove
    dir = entry.dir

    if File.exists?(config_sh_path(dir)) do
      case System.cmd(config_sh_path(dir), ["remove", "--unattended"],
             cd: dir,
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          Logger.info("[GhaRunner] runner=#{runner_id} deregistered from GitHub")

        {output, code} ->
          Logger.warning("[GhaRunner] config.sh remove failed exit=#{code}: #{output}")
      end
    end

    # Remove runner directory
    File.rm_rf(dir)

    FrameRouter.send_frame({:gha_runner_removed, %{runner_id: runner_id}})
  end

  # ── Status check ─────────────────────────────────────────────────────────────

  defp check_runner_alive(%{run_pid: nil}), do: {:offline, nil}

  defp check_runner_alive(%{run_pid: port}) when is_port(port) do
    case Port.info(port) do
      nil -> {:offline, nil}
      _ -> {:idle, nil}
    end
  end

  defp check_runner_alive(%{run_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: {:idle, nil}, else: {:offline, nil}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp config_sh_path(dir) do
    case :os.type() do
      {:win32, _} -> Path.join(dir, "config.cmd")
      _ -> Path.join(dir, "config.sh")
    end
  end

  defp run_sh_path(dir) do
    case :os.type() do
      {:win32, _} -> Path.join(dir, "run.cmd")
      _ -> Path.join(dir, "run.sh")
    end
  end

  defp schedule_status_tick(runner_id) do
    Process.send_after(self(), {:status_tick, runner_id}, @status_interval_ms)
  end

  defp gha_runner_enabled? do
    cfg = Config.get()
    Map.get(cfg, :gha_runner_enabled, true)
  end
end
